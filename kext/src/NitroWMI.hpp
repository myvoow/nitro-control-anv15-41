#pragma once

#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/acpi/IOACPIPlatformExpert.h>
#include <IOKit/pci/IOPCIDevice.h>

#include "NitroWMIShared.h"

// Matches the ACPI WMI device (PNP0C14) whose _WDG carries the AcerGamingFunction GUID
// and exposes it to user space. Owns the fan failsafe: automatic fans are restored when
// the last privileged client goes away, when the watchdog is not fed, and on unload.
class NitroWMI : public IOService {
    OSDeclareDefaultStructors(NitroWMI)

public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

    IOReturn wmiCall(uint32_t method, uint64_t input, uint64_t *output);
    IOReturn ecDump(uint8_t *buf, uint32_t len);
    IOReturn cpuStats(NitroCPUStats *out);
    uint32_t copyWDG(void *buf, uint32_t cap);
    IOReturn copyACPITable(uint32_t signature, uint32_t instance, uint32_t offset,
                           void *buf, uint32_t *chunkLen, uint64_t *totalLen);
    void fillInfo(NitroInfo *info, bool privileged);
    void kick();
    void clientOpened(bool privileged);
    void clientClosed(bool privileged);

private:
    static bool findGamingBlock(IOACPIPlatformDevice *dev, char objectId[2]);
    IOReturn evalWMI(uint32_t method, uint64_t input, bool wide, uint64_t *output);
    void restoreAuto(const char *why);
    void timerFired(IOTimerEventSource *sender);
    void findRootComplex();
    bool readSMN(uint32_t addr, uint32_t *val);

    IOACPIPlatformDevice *fWMI = nullptr;
    IOACPIPlatformDevice *fEC = nullptr;
    IOPCIDevice *fRoot = nullptr;
    IOLock *fLock = nullptr;
    IOWorkLoop *fWorkLoop = nullptr;
    IOTimerEventSource *fTimer = nullptr;
    char fMethod[5] = {};
    char fUID[8] = {};
    uint8_t fFanMode[16] = {};   // last mode set per fan bit (1 = auto)
    bool fArmed = false;
    bool fHasAPERF = false;
    bool fHasRAPL = false;
    uint32_t fNumCPUs = 0;
    uint32_t fPrivClients = 0;
    uint32_t fFailsafeCount = 0;
};

class NitroWMIUserClient : public IOUserClient {
    OSDeclareDefaultStructors(NitroWMIUserClient)

public:
    bool initWithTask(task_t owningTask, void *securityToken, UInt32 type, OSDictionary *properties) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn clientClose() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                            IOExternalMethodDispatch *dispatch, OSObject *target, void *reference) override;

private:
    void release_owner();

    NitroWMI *fOwner = nullptr;
    bool fPrivileged = false;
    bool fCounted = false;
};
