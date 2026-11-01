import Foundation

public enum FanMode: Int, Codable, CaseIterable, Identifiable {
    case auto = 1
    case max = 2
    case custom = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .max: "Max"
        case .custom: "Personnalisé"
        }
    }

    public var symbol: String {
        switch self {
        case .auto: "fanblades"
        case .max: "wind"
        case .custom: "slider.horizontal.3"
        }
    }
}

/// Values are the firmware's operating-mode ids (SetGamingMiscSetting index 0x0B).
public enum PerformanceProfile: Int, Codable, CaseIterable, Identifiable {
    case quiet = 0
    case balanced = 1
    case performance = 4
    case turbo = 5
    case eco = 6

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .quiet: "Silencieux"
        case .balanced: "Normal"
        case .performance: "Performance"
        case .turbo: "Turbo"
        case .eco: "Éco"
        }
    }

    public var subtitle: String {
        switch self {
        case .quiet: "Ventilation discrète, puissance limitée"
        case .balanced: "Équilibre entre bruit et performances"
        case .performance: "Limites de puissance CPU/GPU relevées"
        case .turbo: "Puissance maximale, ventilation agressive"
        case .eco: "Autonomie avant tout"
        }
    }

    public var symbol: String {
        switch self {
        case .quiet: "moon.fill"
        case .balanced: "gauge.with.dots.needle.33percent"
        case .performance: "gauge.with.dots.needle.67percent"
        case .turbo: "bolt.fill"
        case .eco: "leaf.fill"
        }
    }
}

public struct Snapshot: Codable, Equatable {
    public var time = Date()
    public var daemonVersion = NitroXPC.version

    public var kextLoaded = false
    public var kextVersion: String?
    public var wmiMethod: String?
    public var wmiUID: String?
    public var watchdogArmed = false
    public var failsafeCount = 0

    public var cpuTemp: Double?
    public var gpuTemp: Double?
    public var systemTemp: Double?
    public var tctl: Double?
    public var cpuFanRPM: Int?
    public var gpuFanRPM: Int?

    public var cpuFreqMHz: Double?
    public var cpuMaxFreqMHz: Double?
    public var cpuLoad: Double?
    public var packagePowerW: Double?
    public var onACPower: Bool?

    public var profile: PerformanceProfile?
    public var supportedProfiles: [PerformanceProfile] = []

    public var fanMode: FanMode = .auto
    public var cpuFanPercent = 50
    public var gpuFanPercent = 50
    public var coolBoost = false
    public var appliedFanMode: FanMode = .auto
    public var appliedCPUPercent: Int?
    public var appliedGPUPercent: Int?
    public var thermalGuardActive = false
    public var writesEnabled = false

    public var lastError: String?

    public init() {}

    public var highestTemp: Double? {
        [cpuTemp, gpuTemp, systemTemp].compactMap { $0 }.max()
    }
}

extension Snapshot {
    /// Plausibility gate before write commands are allowed.
    public var readsLookValid: Bool {
        let temps = [cpuTemp, gpuTemp].allSatisfy { $0.map { (15...110).contains($0) } ?? false }
        let fans = [cpuFanRPM, gpuFanRPM].allSatisfy { $0.map { (0...9000).contains($0) } ?? false }
        return kextLoaded && temps && fans && profile != nil
    }
}
