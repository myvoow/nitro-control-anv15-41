#include "NitroWMI.hpp"

#include <libkern/libkern.h>

extern "C" {
void mp_rendezvous_no_intrs(void (*action_func)(void *), void *arg);
int cpu_number(void);
}

// AcerGamingFunction: 7A4DDFE7-5B5D-40B4-8595-4408E0CC7F56 in _WDG byte order.
static const uint8_t kGamingGuid[16] = {
    0xE7, 0xDF, 0x4D, 0x7A, 0x5D, 0x5B, 0xB4, 0x40,
    0x85, 0x95, 0x44, 0x08, 0xE0, 0xCC, 0x7F, 0x56,
};

static constexpr uint32_t kWDGBlockSize = 20;
static constexpr uint8_t kWDGFlagMethod = 0x02;
static constexpr uint32_t kSMNIndex = 0x60;
static constexpr uint32_t kSMNData = 0x64;
static constexpr uint32_t kSMNThmCurTmp = 0x00059800;

static inline uint64_t nwRdmsr(uint32_t msr) {
    uint32_t lo, hi;
    __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
    return ((uint64_t)hi << 32) | lo;
}

static inline uint64_t nwRdtsc() {
    uint32_t lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}

static inline void nwCpuid(uint32_t leaf, uint32_t r[4]) {
    __asm__ volatile("cpuid" : "=a"(r[0]), "=b"(r[1]), "=c"(r[2]), "=d"(r[3]) : "a"(leaf), "c"(0));
}

// getACPITableData() is protected; reach it through a member pointer named in a subclass
// (never instantiated).
class NitroACPITables : public IOACPIPlatformExpert {
public:
    // IOACPIFamily does not export IOACPIPlatformExpert's metaclass to aux-KC kexts, so no OSDynamicCast.
    static IOACPIPlatformExpert *platform() {
        IOPlatformExpert *pe = IOService::getPlatform();
        return pe && pe->metaCast("IOACPIPlatformExpert") ? static_cast<IOACPIPlatformExpert *>(pe) : nullptr;
    }

    static const OSData *copy(IOACPIPlatformExpert *pe, const char *name, UInt32 instance) {
        return (pe->*(&NitroACPITables::getACPITableData))(name, instance);
    }
};

namespace {
struct Rendezvous {
    NitroCPUStats *stats;
    bool aperf;
    bool rapl;
    volatile uint8_t seen[NITRO_MAX_CPUS];
};

void sampleCPU(void *arg) {
    auto *r = static_cast<Rendezvous *>(arg);
    int n = cpu_number();
    if (n < 0 || n >= NITRO_MAX_CPUS)
        return;
    if (r->aperf) {
        r->stats->mperf[n] = nwRdmsr(0xE7);
        r->stats->aperf[n] = nwRdmsr(0xE8);
    }
    if (n == 0) {
        r->stats->tsc = nwRdtsc();
        if (r->rapl) {
            r->stats->raplUnit = nwRdmsr(0xC0010299);
            r->stats->pkgEnergy = nwRdmsr(0xC001029B);
        }
    }
    r->seen[n] = 1;
}
} // namespace

OSDefineMetaClassAndStructors(NitroWMI, IOService)

bool NitroWMI::findGamingBlock(IOACPIPlatformDevice *dev, char objectId[2]) {
    OSObject *obj = nullptr;
    if (dev->evaluateObject("_WDG", &obj) != kIOReturnSuccess || !obj)
        return false;
    bool found = false;
    if (OSData *data = OSDynamicCast(OSData, obj)) {
        auto *p = static_cast<const uint8_t *>(data->getBytesNoCopy());
        for (uint32_t i = 0; i + kWDGBlockSize <= data->getLength(); i += kWDGBlockSize) {
            if (memcmp(p + i, kGamingGuid, sizeof kGamingGuid) == 0 && (p[i + 19] & kWDGFlagMethod)) {
                objectId[0] = (char)p[i + 16];
                objectId[1] = (char)p[i + 17];
                found = true;
                break;
            }
        }
    }
    obj->release();
    return found;
}

IOService *NitroWMI::probe(IOService *provider, SInt32 *score) {
    if (!IOService::probe(provider, score))
        return nullptr;
    auto *dev = OSDynamicCast(IOACPIPlatformDevice, provider);
    char id[2];
    return dev && findGamingBlock(dev, id) ? this : nullptr;
}

bool NitroWMI::start(IOService *provider) {
    if (!IOService::start(provider))
        return false;

    char id[2];
    fWMI = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!fWMI || !findGamingBlock(fWMI, id)) {
        fWMI = nullptr;
        return false;
    }
    fWMI->retain();
    fMethod[0] = 'W';
    fMethod[1] = 'M';
    fMethod[2] = id[0];
    fMethod[3] = id[1];
    if (auto *uid = OSDynamicCast(OSString, fWMI->getProperty("_UID")))
        strlcpy(fUID, uid->getCStringNoCopy(), sizeof fUID);
    for (auto &mode : fFanMode)
        mode = 1;

    fLock = IOLockAlloc();
    fWorkLoop = IOWorkLoop::workLoop();
    if (fWorkLoop)
        fTimer = IOTimerEventSource::timerEventSource(
            this, OSMemberFunctionCast(IOTimerEventSource::Action, this, &NitroWMI::timerFired));
    if (!fLock || !fTimer || fWorkLoop->addEventSource(fTimer) != kIOReturnSuccess) {
        IOLog("NitroWMI: could not set up the watchdog, not starting\n");
        OSSafeReleaseNULL(fTimer);
        OSSafeReleaseNULL(fWorkLoop);
        OSSafeReleaseNULL(fWMI);
        return false;
    }

    if (OSDictionary *m = IOService::nameMatching("PNP0C09")) {
        IOService *s = IOService::waitForMatchingService(m, 2000000000ULL);
        m->release();
        fEC = OSDynamicCast(IOACPIPlatformDevice, s);
        if (!fEC && s)
            s->release();
    }

    uint32_t r[4];
    nwCpuid(0, r);
    bool amd = r[1] == 0x68747541 && r[3] == 0x69746e65 && r[2] == 0x444d4163; // "AuthenticAMD"
    nwCpuid(6, r);
    fHasAPERF = r[2] & 1;
    nwCpuid(0x80000000, r);
    if (amd && r[0] >= 0x80000007) {
        nwCpuid(0x80000007, r);
        fHasRAPL = (r[3] >> 14) & 1;
    }
    if (amd)
        findRootComplex();

    setProperty("WMIMethod", fMethod);
    setProperty("WMIUID", fUID);
    setProperty("EC", fEC != nullptr);
    setProperty("SMN", fRoot != nullptr);
    setProperty("APERF", fHasAPERF);
    setProperty("RAPL", fHasRAPL);
    registerService();
    IOLog("NitroWMI: AcerGamingFunction via %s (_UID %s), EC %s, SMN %s, APERF %d, RAPL %d\n", fMethod, fUID,
          fEC ? "yes" : "no", fRoot ? "yes" : "no", fHasAPERF, fHasRAPL);
    return true;
}

void NitroWMI::stop(IOService *provider) {
    if (fTimer)
        fTimer->cancelTimeout();
    restoreAuto("unload");
    if (fTimer && fWorkLoop)
        fWorkLoop->removeEventSource(fTimer);
    OSSafeReleaseNULL(fTimer);
    OSSafeReleaseNULL(fWorkLoop);
    OSSafeReleaseNULL(fEC);
    OSSafeReleaseNULL(fRoot);
    OSSafeReleaseNULL(fWMI);
    IOService::stop(provider);
}

void NitroWMI::free() {
    if (fLock) {
        IOLockFree(fLock);
        fLock = nullptr;
    }
    IOService::free();
}

void NitroWMI::findRootComplex() {
    OSDictionary *m = IOService::serviceMatching("IOPCIDevice");
    if (!m)
        return;
    if (OSIterator *it = IOService::getMatchingServices(m)) {
        while (OSObject *o = it->getNextObject()) {
            auto *d = OSDynamicCast(IOPCIDevice, o);
            if (d && d->getBusNumber() == 0 && d->getDeviceNumber() == 0 && d->getFunctionNumber() == 0 &&
                d->configRead16(kIOPCIConfigVendorID) == 0x1022) {
                fRoot = d;
                fRoot->retain();
                break;
            }
        }
        it->release();
    }
    m->release();
}

bool NitroWMI::readSMN(uint32_t addr, uint32_t *val) {
    if (!fRoot)
        return false;
    fRoot->configWrite32(kSMNIndex, addr);
    *val = fRoot->configRead32(kSMNData);
    return true;
}

// WMxx(Arg0 instance, Arg1 method id, Arg2 buffer). Get methods take a u32, Set methods a u64,
// as logged by AcerHardwareService ("input: 0x%I32X" / "0x%I64X"). Caller holds fLock.
IOReturn NitroWMI::evalWMI(uint32_t method, uint64_t input, bool wide, uint64_t *output) {
    OSNumber *instance = OSNumber::withNumber(0ULL, 32);
    OSNumber *methodId = OSNumber::withNumber((unsigned long long)method, 32);
    OSData *buffer = OSData::withBytes(&input, wide ? 8 : 4);
    OSObject *params[3] = {instance, methodId, buffer};
    OSObject *result = nullptr;
    IOReturn ret = kIOReturnNoMemory;
    if (instance && methodId && buffer)
        ret = fWMI->evaluateObject(fMethod, &result, params, 3);
    OSSafeReleaseNULL(instance);
    OSSafeReleaseNULL(methodId);
    OSSafeReleaseNULL(buffer);

    uint64_t value = 0;
    if (ret == kIOReturnSuccess && result) {
        if (auto *n = OSDynamicCast(OSNumber, result)) {
            value = n->unsigned64BitValue();
        } else if (auto *d = OSDynamicCast(OSData, result)) {
            uint32_t len = d->getLength() < 8 ? d->getLength() : 8;
            memcpy(&value, d->getBytesNoCopy(), len);
        }
    }
    OSSafeReleaseNULL(result);
    *output = value;
    return ret;
}

IOReturn NitroWMI::wmiCall(uint32_t method, uint64_t input, uint64_t *output) {
    IOLockLock(fLock);
    IOReturn ret = evalWMI(method, input, nitroMethodIsWrite(method), output);
    if (method == kAcerSetGamingFanBehavior) {
        for (unsigned bit = 0; bit < 16; bit++)
            if ((input >> bit) & 1)
                fFanMode[bit] = (input >> (16 + 2 * bit)) & 3;
        bool manual = false;
        for (auto mode : fFanMode)
            manual |= mode != 1;
        fArmed = manual;
        if (manual)
            fTimer->setTimeoutMS(NITRO_WATCHDOG_MS);
        else
            fTimer->cancelTimeout();
    }
    IOLockUnlock(fLock);
    return ret;
}

void NitroWMI::restoreAuto(const char *why) {
    if (!fLock || !fWMI)
        return;
    IOLockLock(fLock);
    if (fArmed) {
        uint64_t out = 0;
        IOReturn ret = evalWMI(kAcerSetGamingFanBehavior, NITRO_FAN_ALL_AUTO, true, &out);
        for (auto &mode : fFanMode)
            mode = 1;
        fArmed = false;
        fFailsafeCount++;
        IOLog("NitroWMI: failsafe (%s): fans back to automatic (ret 0x%x, out 0x%llx)\n", why, ret, out);
    }
    IOLockUnlock(fLock);
}

void NitroWMI::timerFired(IOTimerEventSource *) {
    restoreAuto("watchdog not fed");
}

void NitroWMI::kick() {
    IOLockLock(fLock);
    if (fArmed)
        fTimer->setTimeoutMS(NITRO_WATCHDOG_MS);
    IOLockUnlock(fLock);
}

void NitroWMI::clientOpened(bool privileged) {
    if (!privileged)
        return;
    IOLockLock(fLock);
    fPrivClients++;
    IOLockUnlock(fLock);
}

void NitroWMI::clientClosed(bool privileged) {
    if (!privileged)
        return;
    IOLockLock(fLock);
    if (fPrivClients)
        fPrivClients--;
    bool last = fPrivClients == 0;
    IOLockUnlock(fLock);
    if (last)
        restoreAuto("last privileged client closed");
}

IOReturn NitroWMI::ecDump(uint8_t *buf, uint32_t len) {
    if (!fEC)
        return kIOReturnNoDevice;
    IOReturn ret = kIOReturnSuccess;
    IOLockLock(fLock);
    for (uint32_t i = 0; i < len && ret == kIOReturnSuccess; i++) {
        UInt64 v = 0;
        IOACPIAddress addr;
        addr.addr64 = i;
        ret = fEC->readAddressSpace(&v, kIOACPIAddressSpaceIDEmbeddedController, addr, 8, 0, 0);
        buf[i] = (uint8_t)v;
    }
    IOLockUnlock(fLock);
    return ret;
}

IOReturn NitroWMI::cpuStats(NitroCPUStats *out) {
    bzero(out, sizeof *out);
    Rendezvous r = {out, fHasAPERF, fHasRAPL, {}};
    if (fHasAPERF || fHasRAPL)
        mp_rendezvous_no_intrs(sampleCPU, &r);
    for (uint32_t i = 0; i < NITRO_MAX_CPUS; i++)
        if (r.seen[i])
            out->ncpu = i + 1;
    out->flags = (fHasAPERF ? NITRO_CPU_APERF : 0) | (fHasRAPL ? NITRO_CPU_RAPL : 0);
    uint32_t tctl = 0;
    IOLockLock(fLock);
    bool ok = readSMN(kSMNThmCurTmp, &tctl);
    IOLockUnlock(fLock);
    if (ok) {
        out->tctlRaw = tctl;
        out->flags |= NITRO_CPU_TCTL;
    }
    if (out->ncpu)
        fNumCPUs = out->ncpu;
    return kIOReturnSuccess;
}

uint32_t NitroWMI::copyWDG(void *buf, uint32_t cap) {
    OSObject *obj = nullptr;
    uint32_t n = 0;
    if (fWMI->evaluateObject("_WDG", &obj) == kIOReturnSuccess && obj) {
        if (OSData *d = OSDynamicCast(OSData, obj)) {
            n = d->getLength() < cap ? d->getLength() : cap;
            memcpy(buf, d->getBytesNoCopy(), n);
        }
    }
    OSSafeReleaseNULL(obj);
    return n;
}

IOReturn NitroWMI::copyACPITable(uint32_t signature, uint32_t instance, uint32_t offset, void *buf,
                                 uint32_t *chunkLen, uint64_t *totalLen) {
    auto *pe = NitroACPITables::platform();
    if (!pe)
        return kIOReturnUnsupported;
    char name[5] = {(char)(signature & 0xFF), (char)((signature >> 8) & 0xFF), (char)((signature >> 16) & 0xFF),
                    (char)((signature >> 24) & 0xFF), 0};
    // The platform expert keeps ownership of the table data.
    const OSData *table = NitroACPITables::copy(pe, name, instance);
    if (!table)
        return kIOReturnNotFound;
    uint32_t len = table->getLength();
    uint32_t n = 0;
    if (offset < len) {
        n = len - offset < *chunkLen ? len - offset : *chunkLen;
        memcpy(buf, static_cast<const uint8_t *>(table->getBytesNoCopy()) + offset, n);
    }
    *totalLen = len;
    *chunkLen = n;
    return kIOReturnSuccess;
}

void NitroWMI::fillInfo(NitroInfo *info, bool privileged) {
    bzero(info, sizeof *info);
    info->version = NITRO_WMI_VERSION;
    memcpy(info->wmiMethod, fMethod, sizeof fMethod);
    strlcpy(info->wmiUID, fUID, sizeof info->wmiUID);
    IOLockLock(fLock);
    info->flags = NITRO_INFO_WMI | (fEC ? NITRO_INFO_EC : 0) | (fRoot ? NITRO_INFO_SMN : 0) |
                  (privileged ? NITRO_INFO_PRIVILEGED : 0) | (fArmed ? NITRO_INFO_ARMED : 0) |
                  (fHasAPERF ? NITRO_INFO_APERF : 0) | (fHasRAPL ? NITRO_INFO_RAPL : 0) |
                  (NitroACPITables::platform() ? NITRO_INFO_ACPI_PE : 0);
    info->ncpu = fNumCPUs;
    info->watchdogMs = NITRO_WATCHDOG_MS;
    info->failsafeCount = fFailsafeCount;
    info->privClients = fPrivClients;
    IOLockUnlock(fLock);
}

// MARK: - User client

OSDefineMetaClassAndStructors(NitroWMIUserClient, IOUserClient)

bool NitroWMIUserClient::initWithTask(task_t owningTask, void *securityToken, UInt32 type, OSDictionary *properties) {
    if (!IOUserClient::initWithTask(owningTask, securityToken, type, properties))
        return false;
    fPrivileged = clientHasPrivilege(securityToken, kIOClientPrivilegeAdministrator) == kIOReturnSuccess;
    return true;
}

bool NitroWMIUserClient::start(IOService *provider) {
    fOwner = OSDynamicCast(NitroWMI, provider);
    if (!fOwner || !IOUserClient::start(provider))
        return false;
    fOwner->clientOpened(fPrivileged);
    fCounted = true;
    return true;
}

void NitroWMIUserClient::release_owner() {
    if (fCounted && fOwner) {
        fCounted = false;
        fOwner->clientClosed(fPrivileged);
    }
}

IOReturn NitroWMIUserClient::clientClose() {
    release_owner();
    terminate();
    return kIOReturnSuccess;
}

void NitroWMIUserClient::stop(IOService *provider) {
    release_owner();
    IOUserClient::stop(provider);
}

IOReturn NitroWMIUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *a,
                                            IOExternalMethodDispatch *, OSObject *, void *) {
    if (!fOwner)
        return kIOReturnNotAttached;

    switch (selector) {
    case kNitroSelGetInfo: {
        if (!a->structureOutput || a->structureOutputSize < sizeof(NitroInfo))
            return kIOReturnBadArgument;
        fOwner->fillInfo(static_cast<NitroInfo *>(a->structureOutput), fPrivileged);
        a->structureOutputSize = sizeof(NitroInfo);
        return kIOReturnSuccess;
    }
    case kNitroSelWMICall: {
        if (a->scalarInputCount != 2 || a->scalarOutputCount < 1)
            return kIOReturnBadArgument;
        uint32_t method = (uint32_t)a->scalarInput[0];
        if (nitroMethodIsWrite(method) ? !fPrivileged : !nitroMethodIsRead(method))
            return kIOReturnNotPrivileged;
        uint64_t out = 0;
        IOReturn ret = fOwner->wmiCall(method, a->scalarInput[1], &out);
        a->scalarOutput[0] = out;
        a->scalarOutputCount = 1;
        return ret;
    }
    case kNitroSelECDump: {
        if (!a->structureOutput || a->structureOutputSize < NITRO_EC_SIZE)
            return kIOReturnBadArgument;
        a->structureOutputSize = NITRO_EC_SIZE;
        return fOwner->ecDump(static_cast<uint8_t *>(a->structureOutput), NITRO_EC_SIZE);
    }
    case kNitroSelCPUStats: {
        if (!a->structureOutput || a->structureOutputSize < sizeof(NitroCPUStats))
            return kIOReturnBadArgument;
        a->structureOutputSize = sizeof(NitroCPUStats);
        return fOwner->cpuStats(static_cast<NitroCPUStats *>(a->structureOutput));
    }
    case kNitroSelWDG: {
        if (!a->structureOutput)
            return kIOReturnBadArgument;
        a->structureOutputSize = fOwner->copyWDG(a->structureOutput, a->structureOutputSize);
        return kIOReturnSuccess;
    }
    case kNitroSelKick: {
        if (!fPrivileged)
            return kIOReturnNotPrivileged;
        fOwner->kick();
        return kIOReturnSuccess;
    }
    case kNitroSelACPITable: {
        if (a->scalarInputCount != 3 || a->scalarOutputCount < 1 || !a->structureOutput)
            return kIOReturnBadArgument;
        uint32_t chunk = a->structureOutputSize;
        uint64_t total = 0;
        IOReturn ret = fOwner->copyACPITable((uint32_t)a->scalarInput[0], (uint32_t)a->scalarInput[1],
                                             (uint32_t)a->scalarInput[2], a->structureOutput, &chunk, &total);
        a->structureOutputSize = chunk;
        a->scalarOutput[0] = total;
        a->scalarOutputCount = 1;
        return ret;
    }
    default:
        return kIOReturnUnsupported;
    }
}
