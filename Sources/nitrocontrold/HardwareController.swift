import Foundation
import IOKit.ps
import NitroKit
import os
import SystemConfiguration

private let logger = Logger(subsystem: "com.myvo.nitrocontrold", category: "hw")

func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8))
}

private struct DaemonConfig: Codable {
    var writesEnabled = false
    // Last fan setting, survives reboots; applied whenever a client (the app, started at login) is live.
    var fanMode = FanMode.auto
    var cpuFanPercent = 50
    var gpuFanPercent = 50
    var coolBoost = false
}

/// Owns the kext connection and every hardware decision. All state lives on `queue`.
///
/// Failsafe layers, outermost first:
///  - no live client (app quit/crashed, or silent for `clientTimeout`) → fans back to Auto here,
///    the saved setting comes back when a client reconnects;
///  - this daemon dies → the kext sees its last root client close and restores Auto;
///  - this daemon hangs → the kext watchdog (10 s, fed every tick) restores Auto;
///  - custom speeds and CPU ≥ 95 °C / GPU ≥ 87 °C → forced Max until temps drop.
final class HardwareController {
    private let queue = DispatchQueue(label: "com.myvo.nitrocontrold.hw")
    private var timer: DispatchSourceTimer?
    private var kext: KextClient?
    private let meter = CPUMeter()
    private var snap = Snapshot()
    private var config: DaemonConfig
    private var clients: [UUID: Date] = [:]
    private var tick = 0
    private var lastKextAttempt = Date.distantPast
    private var applied: (mode: FanMode, cpu: Int?, gpu: Int?)?
    private var curve: (cpu: Int, gpu: Int)?

    private let clientTimeout: TimeInterval = 15
    private let guardOn = (cpu: 95.0, gpu: 87.0)
    private let guardOff = (cpu: 85.0, gpu: 78.0)
    private static let configURL = URL(fileURLWithPath: "/Library/Application Support/NitroControl/daemon.json")

    init() {
        config = (try? JSONDecoder().decode(DaemonConfig.self, from: Data(contentsOf: Self.configURL))) ?? DaemonConfig()
        snap.writesEnabled = config.writesEnabled
        snap.fanMode = config.fanMode
        snap.cpuFanPercent = config.cpuFanPercent
        snap.gpuFanPercent = config.gpuFanPercent
        snap.coolBoost = config.coolBoost
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.step() }
        t.resume()
        timer = t
        log("nitrocontrold \(NitroXPC.version) started, writes \(config.writesEnabled ? "enabled" : "disabled")")
    }

    func shutdown() {
        queue.sync {
            if config.writesEnabled, applied?.mode != .auto { setBehavior(.auto, reason: "daemon stopping") }
        }
    }

    // MARK: Clients

    func isAllowed(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        var console: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &console, nil) != nil else { return false }
        return uid == console
    }

    func touch(_ id: UUID) {
        queue.async { self.clients[id] = Date() }
    }

    func clientGone(_ id: UUID) {
        queue.async {
            self.clients[id] = nil
            self.enforceLiveness()
            self.applyFans()
        }
    }

    // MARK: Commands (reply on the caller's XPC queue)

    func status(from id: UUID) -> Data {
        queue.sync {
            clients[id] = Date()
            return (try? JSONEncoder().encode(snap)) ?? Data()
        }
    }

    func setFanMode(_ mode: FanMode, cpu: Int, gpu: Int, from id: UUID) -> String? {
        queue.sync {
            clients[id] = Date()
            guard config.writesEnabled else { return "Commandes d'écriture désactivées (validez d'abord la lecture des capteurs)" }
            snap.fanMode = mode
            snap.cpuFanPercent = clampPercent(cpu)
            snap.gpuFanPercent = clampPercent(gpu)
            log("fan mode \(mode.title) cpu \(snap.cpuFanPercent)% gpu \(snap.gpuFanPercent)%")
            saveFans()
            return applyFans()
        }
    }

    func setCoolBoost(_ on: Bool, from id: UUID) -> String? {
        queue.sync {
            clients[id] = Date()
            guard config.writesEnabled else { return "Commandes d'écriture désactivées" }
            snap.coolBoost = on
            curve = nil
            log("CoolBoost \(on ? "on" : "off")")
            saveFans()
            return applyFans()
        }
    }

    func setProfile(_ value: Int, from id: UUID) -> String? {
        queue.sync {
            clients[id] = Date()
            guard config.writesEnabled else { return "Commandes d'écriture désactivées" }
            guard let profile = PerformanceProfile(rawValue: value) else { return "Profil inconnu" }
            if !snap.supportedProfiles.isEmpty, !snap.supportedProfiles.contains(profile) {
                return "\(profile.title) n'est pas pris en charge par ce modèle"
            }
            guard let k = kext else { return NitroError.kextNotLoaded.description }
            do {
                let raw = try k.wmi(AcerWMI.setMisc, AcerWMI.setProfile(profile))
                guard AcerWMI.status(raw) == 0 else {
                    throw NitroError.firmware("Changement de mode", AcerWMI.status(raw))
                }
                log("profile -> \(profile.title)")
                readProfile(k)
                return nil
            } catch {
                return "\(error)"
            }
        }
    }

    func setWritesEnabled(_ on: Bool, from id: UUID) -> String? {
        queue.sync {
            clients[id] = Date()
            if on, !snap.readsLookValid {
                return "Les lectures de capteurs ne sont pas encore plausibles : écriture refusée"
            }
            if !on {
                snap.fanMode = .auto
                snap.coolBoost = false
                applyFans()
            }
            config.writesEnabled = on
            snap.writesEnabled = on
            saveFans()
            log("writes \(on ? "enabled" : "disabled")")
            if on { applyFans() }
            return nil
        }
    }


    // MARK: Periodic work

    private func step() {
        tick += 1
        connectKextIfNeeded()
        if let k = kext {
            do {
                try readSensors(k)
                snap.lastError = nil
            } catch {
                snap.lastError = "\(error)"
                log("kext read failed: \(error); reconnecting")
                kext = nil
                applied = nil
                snap.kextLoaded = false
            }
        }
        snap.onACPower = Self.onAC()
        snap.time = Date()
        enforceLiveness()
        updateThermalGuard()
        applyFans()
        if let k = kext, applied.map({ $0.mode != .auto }) == true {
            try? k.kickWatchdog()
        }
    }

    private func connectKextIfNeeded() {
        guard kext == nil, Date().timeIntervalSince(lastKextAttempt) > 5 else { return }
        lastKextAttempt = Date()
        do {
            let k = try KextClient()
            let info = try k.info()
            kext = k
            snap.kextLoaded = true
            snap.kextVersion = info.version
            snap.wmiMethod = info.wmiMethod
            snap.wmiUID = info.wmiUID
            if let bitmapRaw = try? k.wmi(AcerWMI.getMisc, AcerWMI.miscSupportedProfiles) {
                if let bitmap = AcerWMI.miscValue(bitmapRaw) {
                    snap.supportedProfiles = AcerWMI.profiles(fromBitmap: bitmap)
                }
            }
            readProfile(k)
            log("connected to NitroWMI \(info.version) via \(info.wmiMethod) (_UID \(info.wmiUID)), profiles: \(snap.supportedProfiles.map(\.title))")
            // Start from a known state: the EC's own automatic curve.
            if config.writesEnabled { setBehavior(.auto, reason: "startup") }
        } catch {
            if snap.kextLoaded || tick == 1 { log("NitroWMI unavailable: \(error)") }
            snap.kextLoaded = false
        }
    }

    private func readSensors(_ k: KextClient) throws {
        func sensor(_ s: AcerWMI.Sensor) throws -> Int? {
            let r = try k.sensor(s)
            return r.value
        }
        snap.cpuTemp = try sensor(.cpuTemp).map(Double.init)
        snap.gpuTemp = try sensor(.gpuTemp).map(Double.init)
        snap.systemTemp = try sensor(.systemTemp).map(Double.init)
        snap.cpuFanRPM = try sensor(.cpuFan)
        snap.gpuFanRPM = try sensor(.gpuFan)

        let reading = meter.update(try k.cpuStats())
        snap.cpuFreqMHz = reading.avgMHz
        snap.cpuMaxFreqMHz = reading.maxMHz
        snap.cpuLoad = reading.load
        snap.packagePowerW = reading.packageW
        snap.tctl = reading.tctl

        if tick % 5 == 0 {
            readProfile(k)
            let info = try k.info()
            snap.watchdogArmed = info.armed
            snap.failsafeCount = info.failsafeCount
        }
    }

    private func readProfile(_ k: KextClient) {
        guard let raw = try? k.wmi(AcerWMI.getMisc, AcerWMI.miscProfile) else { return }
        snap.profile = AcerWMI.miscValue(raw).flatMap { PerformanceProfile(rawValue: Int($0)) }
    }

    private func enforceLiveness() {
        let now = Date()
        clients = clients.filter { now.timeIntervalSince($0.value) < clientTimeout }
    }

    private var customLike: Bool {
        !clients.isEmpty && (snap.fanMode == .custom || (snap.fanMode == .auto && snap.coolBoost))
    }

    private func updateThermalGuard() {
        let cpu = snap.cpuTemp ?? 0, gpu = snap.gpuTemp ?? 0
        if !snap.thermalGuardActive, customLike, cpu >= guardOn.cpu || gpu >= guardOn.gpu {
            snap.thermalGuardActive = true
            log("thermal guard: CPU \(cpu) °C GPU \(gpu) °C, forcing Max")
        } else if snap.thermalGuardActive, !customLike || (cpu < guardOff.cpu && gpu < guardOff.gpu) {
            snap.thermalGuardActive = false
            log("thermal guard released")
        }
    }

    // MARK: Fan output

    /// CoolBoost: a steeper software curve than the EC's automatic one.
    private static func boostCurve(_ t: Double) -> Int {
        let points: [(Double, Double)] = [(40, 30), (50, 40), (60, 55), (70, 72), (78, 88), (84, 100)]
        guard t > points[0].0 else { return Int(points[0].1) }
        for (a, b) in zip(points, points.dropFirst()) where t <= b.0 {
            return Int(a.1 + (b.1 - a.1) * (t - a.0) / (b.0 - a.0))
        }
        return 100
    }

    private func target() -> (mode: FanMode, cpu: Int?, gpu: Int?) {
        // Failsafe: nobody watching → the EC's own curve; the saved setting stays for the next client.
        if clients.isEmpty {
            curve = nil
            return (.auto, nil, nil)
        }
        if snap.thermalGuardActive { return (.max, nil, nil) }
        switch snap.fanMode {
        case .max:
            return (.max, nil, nil)
        case .custom:
            return (.custom, snap.cpuFanPercent, snap.gpuFanPercent)
        case .auto:
            guard snap.coolBoost, let cpuT = snap.cpuTemp else { return (.auto, nil, nil) }
            let wanted = (cpu: Self.boostCurve(cpuT), gpu: Self.boostCurve(snap.gpuTemp ?? cpuT))
            // Hysteresis: follow rises at once, drops only beyond 5 points.
            if let c = curve {
                curve = (wanted.cpu >= c.cpu || c.cpu - wanted.cpu > 5 ? wanted.cpu : c.cpu,
                         wanted.gpu >= c.gpu || c.gpu - wanted.gpu > 5 ? wanted.gpu : c.gpu)
            } else {
                curve = wanted
            }
            return (.custom, curve!.cpu, curve!.gpu)
        }
    }

    @discardableResult
    private func applyFans() -> String? {
        guard config.writesEnabled, let k = kext else { return nil }
        let t = target()
        do {
            if applied?.mode != t.mode {
                try writeBehavior(k, t.mode)
                applied = (t.mode, nil, nil)
                log("fans -> \(t.mode.title)\(clients.isEmpty ? " (no live client)" : "")")
            }
            if t.mode == .custom, let cpu = t.cpu, let gpu = t.gpu {
                if applied?.cpu != cpu {
                    try writeSpeed(k, bit: AcerWMI.cpuFanBit, cpu)
                    applied?.cpu = cpu
                }
                if applied?.gpu != gpu {
                    try writeSpeed(k, bit: AcerWMI.gpuFanBit, gpu)
                    applied?.gpu = gpu
                }
            }
            snap.appliedFanMode = t.mode
            snap.appliedCPUPercent = applied?.cpu
            snap.appliedGPUPercent = applied?.gpu
            return nil
        } catch {
            snap.lastError = "\(error)"
            log("fan write failed: \(error)")
            applied = nil
            return "\(error)"
        }
    }

    private func setBehavior(_ mode: FanMode, reason: String) {
        guard let k = kext else { return }
        do {
            try writeBehavior(k, mode)
            applied = (mode, nil, nil)
            snap.appliedFanMode = mode
            log("fans -> \(mode.title) (\(reason))")
        } catch {
            log("fans -> \(mode.title) failed: \(error)")
        }
    }

    private func writeBehavior(_ k: KextClient, _ mode: FanMode) throws {
        let input = AcerWMI.fanBehavior(cpu: mode, gpu: mode)
        let raw = try k.wmi(AcerWMI.setFanBehavior, input)
        guard AcerWMI.status(raw) == 0 else { throw NitroError.firmware("Mode ventilateur", AcerWMI.status(raw)) }
    }

    private func writeSpeed(_ k: KextClient, bit: UInt64, _ percent: Int) throws {
        let input = AcerWMI.fanSpeed(bit: bit, percent: percent)
        let raw = try k.wmi(AcerWMI.setFanSpeed, input)
        guard AcerWMI.status(raw) == 0 else { throw NitroError.firmware("Vitesse ventilateur", AcerWMI.status(raw)) }
    }

    // MARK: Helpers

    private func clampPercent(_ p: Int) -> Int { max(20, min(100, p)) }


    private func saveFans() {
        config.fanMode = snap.fanMode
        config.cpuFanPercent = snap.cpuFanPercent
        config.gpuFanPercent = snap.gpuFanPercent
        config.coolBoost = snap.coolBoost
        saveConfig()
    }

    private func saveConfig() {
        try? FileManager.default.createDirectory(at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(config).write(to: Self.configURL, options: .atomic)
    }

    private static func onAC() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        return type == kIOPSACPowerValue
    }
}
