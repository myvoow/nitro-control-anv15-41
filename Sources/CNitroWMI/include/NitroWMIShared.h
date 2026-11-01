/*
 * NitroWMIShared.h - interface between NitroWMI.kext and user space.
 * Included by the kext (C++) and by the Swift package (CNitroWMI module).
 *
 * Hardware interface reverse-engineered from Acer NitroSense 5.2.84
 * (AcerHardwareService.exe / AcerAgentService.exe): the WMI class
 * ROOT\WMI:AcerGamingFunction, GUID 7A4DDFE7-5B5D-40B4-8595-4408E0CC7F56,
 * exposed by the ACPI device WMID (_UID "APGe") on the Nitro V 15 ANV15-41.
 */
#ifndef NITRO_WMI_SHARED_H
#define NITRO_WMI_SHARED_H

#include <stdint.h>

#define NITRO_WMI_VERSION   0x00010001u   /* 1.0.1 */
#define NITRO_MAX_CPUS      64
#define NITRO_EC_SIZE       256
#define NITRO_WDG_MAX       1024
#define NITRO_TABLE_CHUNK   4096
#define NITRO_WATCHDOG_MS   10000

/* User client selectors */
enum {
    kNitroSelGetInfo    = 0, /* struct out: NitroInfo */
    kNitroSelWMICall    = 1, /* scalar in: method, input; scalar out: raw result */
    kNitroSelECDump     = 2, /* struct out: NITRO_EC_SIZE bytes (read only) */
    kNitroSelCPUStats   = 3, /* struct out: NitroCPUStats */
    kNitroSelWDG        = 4, /* struct out: raw _WDG of the gaming WMI device */
    kNitroSelKick       = 5, /* privileged: feed the fan watchdog */
    kNitroSelACPITable  = 6, /* scalar in: signature, instance, offset; scalar out: total length; struct out: chunk */
};

/* AcerGamingFunction method IDs (WMxx Arg1) */
enum {
    kAcerGetGamingLED         = 4,
    kAcerGetGamingSysInfo     = 5,
    kAcerSetGamingFanBehavior = 14,
    kAcerGetGamingFanBehavior = 15,
    kAcerSetGamingFanSpeed    = 16,
    kAcerGetGamingFanSpeed    = 17,
    kAcerSetGamingMiscSetting = 22,
    kAcerGetGamingMiscSetting = 23,
};

/* SetGamingFanBehavior: bits 0-15 fan bitmap (CPU bit 0, GPU bit 3),
 * 2 mode bits per fan at 16 + 2*bit (1 auto, 2 max, 3 custom). */
#define NITRO_FAN_ALL_AUTO  0x410009ull

/* NitroInfo.flags */
#define NITRO_INFO_WMI        (1u << 0)
#define NITRO_INFO_EC         (1u << 1)
#define NITRO_INFO_SMN        (1u << 2)
#define NITRO_INFO_PRIVILEGED (1u << 3)
#define NITRO_INFO_ARMED      (1u << 4)
#define NITRO_INFO_APERF      (1u << 5)
#define NITRO_INFO_RAPL       (1u << 6)
#define NITRO_INFO_ACPI_PE    (1u << 7)

typedef struct {
    uint32_t version;
    char     wmiMethod[8];   /* "WMBH"-style method name found through _WDG */
    char     wmiUID[8];      /* _UID of the WMI device ("APGe") */
    uint32_t flags;
    uint32_t ncpu;
    uint32_t watchdogMs;
    uint32_t failsafeCount;  /* times the kext restored automatic fans */
    uint32_t privClients;
    uint32_t reserved[6];
} NitroInfo;

/* NitroCPUStats.flags */
#define NITRO_CPU_APERF (1u << 0)
#define NITRO_CPU_RAPL  (1u << 1)
#define NITRO_CPU_TCTL  (1u << 2)

typedef struct {
    uint32_t ncpu;
    uint32_t flags;
    uint32_t tctlRaw;        /* SMN 0x00059800 THM_TCON_CUR_TMP */
    uint32_t reserved;
    uint64_t tsc;            /* TSC on CPU 0 at sample time */
    uint64_t pkgEnergy;      /* MSR C001_029B */
    uint64_t raplUnit;       /* MSR C001_0299 */
    uint64_t aperf[NITRO_MAX_CPUS];
    uint64_t mperf[NITRO_MAX_CPUS];
} NitroCPUStats;

static inline int nitroMethodIsWrite(uint32_t m) {
    return m == kAcerSetGamingFanBehavior || m == kAcerSetGamingFanSpeed || m == kAcerSetGamingMiscSetting;
}

static inline int nitroMethodIsRead(uint32_t m) {
    return m == kAcerGetGamingLED || m == kAcerGetGamingSysInfo || m == kAcerGetGamingFanBehavior ||
           m == kAcerGetGamingFanSpeed || m == kAcerGetGamingMiscSetting;
}

#endif
