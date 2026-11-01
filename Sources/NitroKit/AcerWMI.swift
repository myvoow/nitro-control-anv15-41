import CNitroWMI

/// Encoders/decoders for the AcerGamingFunction WMI methods, as used by NitroSense 5.2.84
/// (AcerAgentService.exe → AcerHardwareService.exe → WMI).
public enum AcerWMI {
    public static let getSysInfo = UInt32(kAcerGetGamingSysInfo)
    public static let setFanBehavior = UInt32(kAcerSetGamingFanBehavior)
    public static let getFanBehavior = UInt32(kAcerGetGamingFanBehavior)
    public static let setFanSpeed = UInt32(kAcerSetGamingFanSpeed)
    public static let getFanSpeed = UInt32(kAcerGetGamingFanSpeed)
    public static let setMisc = UInt32(kAcerSetGamingMiscSetting)
    public static let getMisc = UInt32(kAcerGetGamingMiscSetting)

    /// GetGamingSysInfo sensor ids: input = (id << 8) | 1, value = bits 8-23, status = bits 0-7.
    public enum Sensor: UInt64, CaseIterable {
        case cpuTemp = 0x01
        case cpuFan = 0x02
        case systemTemp = 0x03
        case gpuFan = 0x06
        case gpuTemp = 0x0A

        public var label: String {
            switch self {
            case .cpuTemp: "Température CPU"
            case .cpuFan: "Ventilateur CPU"
            case .systemTemp: "Température système"
            case .gpuFan: "Ventilateur GPU"
            case .gpuTemp: "Température GPU"
            }
        }

        public var isTemperature: Bool { [.cpuTemp, .systemTemp, .gpuTemp].contains(self) }
        public var input: UInt64 { (rawValue << 8) | 0x01 }
    }

    /// GetGamingMiscSetting / SetGamingMiscSetting indices.
    public static let miscSupportedProfiles: UInt64 = 0x0A
    public static let miscProfile: UInt64 = 0x0B

    /// Fan bits in the behavior bitmap; speed index is bit + 1 (CPU 1, GPU 4).
    public static let cpuFanBit: UInt64 = 0
    public static let gpuFanBit: UInt64 = 3

    public static func status(_ raw: UInt64) -> UInt8 { UInt8(raw & 0xFF) }

    public static func sensorValue(_ raw: UInt64) -> Int? {
        status(raw) == 0 ? Int((raw >> 8) & 0xFFFF) : nil
    }

    public static func miscValue(_ raw: UInt64) -> UInt8? {
        status(raw) == 0 ? UInt8((raw >> 8) & 0xFF) : nil
    }

    public static func fanBehavior(cpu: FanMode, gpu: FanMode) -> UInt64 {
        let bitmap: UInt64 = (1 << cpuFanBit) | (1 << gpuFanBit)
        let modes = (UInt64(cpu.rawValue) << (16 + 2 * cpuFanBit)) | (UInt64(gpu.rawValue) << (16 + 2 * gpuFanBit))
        return modes | bitmap
    }

    public static func fanSpeed(bit: UInt64, percent: Int) -> UInt64 {
        (UInt64(max(0, min(100, percent))) << 8) | (bit + 1)
    }

    public static func setProfile(_ p: PerformanceProfile) -> UInt64 {
        (UInt64(p.rawValue) << 8) | miscProfile
    }

    public static func profiles(fromBitmap bitmap: UInt8) -> [PerformanceProfile] {
        PerformanceProfile.allCases.filter { bitmap & (1 << UInt8($0.rawValue)) != 0 }
    }
}
