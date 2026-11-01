import Foundation
import NitroKit

let usage = """
nitroctl - Nitro Control (Acer Nitro V 15 ANV15-41)

Lecture seule, directement via NitroWMI.kext (aucun droit root nécessaire) :
  nitroctl selftest            vérifie les encodages WMI (aucun accès matériel)
  nitroctl sensors [--watch]   test de lecture des capteurs (températures, ventilateurs, mode, CPU)
  nitroctl info                kext, méthode WMI, blocs _WDG
  nitroctl ec                  dump des 256 registres de l'Embedded Controller
  nitroctl acpi <SIG> [n] <fichier>   copie une table ACPI (DSDT, SSDT n…)

Via le service nitrocontrold :
  nitroctl status
  nitroctl writes on|off       active/désactive les commandes d'écriture (après validation)
  nitroctl profile quiet|balanced|performance|turbo|eco
  nitroctl fan auto|max        (garde la connexion ouverte : Ctrl-C rend la main au mode Auto)
  nitroctl fan custom <cpu%> <gpu%>
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("nitroctl: \(message)\n".utf8))
    exit(1)
}

func openKext() -> KextClient {
    do { return try KextClient() } catch { fail("\(error) — lancez « make install » puis redémarrez") }
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

// MARK: Read-only test

func sensorsReport(_ k: KextClient, meter: CPUMeter) -> String {
    var lines: [String] = []
    var allOK = true
    func row(_ label: String, _ value: String, _ raw: String, _ ok: Bool?) {
        let mark = ok == nil ? "·" : (ok! ? "✓" : "✗")
        if ok == false { allOK = false }
        lines.append("  \(mark) \(pad(label, 24)) \(pad(value, 16)) \(raw)")
    }
    for s in AcerWMI.Sensor.allCases {
        do {
            let r = try k.sensor(s)
            let raw = String(format: "GetGamingSysInfo(0x%04llX) → 0x%llX", s.input, r.raw)
            if let v = r.value {
                let ok = s.isTemperature ? (15...110).contains(v) : (0...9000).contains(v)
                row(s.label, s.isTemperature ? "\(v) °C" : "\(v) tr/min", raw, ok)
            } else {
                row(s.label, "non dispo", raw + String(format: " (statut 0x%02X)", AcerWMI.status(r.raw)), nil)
            }
        } catch {
            row(s.label, "erreur", "\(error)", false)
        }
    }
    if let raw = try? k.wmi(AcerWMI.getMisc, AcerWMI.miscProfile) {
        let p = AcerWMI.miscValue(raw).flatMap { PerformanceProfile(rawValue: Int($0)) }
        row("Mode de fonctionnement", p?.title ?? "inconnu", String(format: "GetGamingMiscSetting(0x0B) → 0x%llX", raw), p != nil)
    }
    if let raw = try? k.wmi(AcerWMI.getMisc, AcerWMI.miscSupportedProfiles) {
        let list = AcerWMI.miscValue(raw).map { AcerWMI.profiles(fromBitmap: $0).map(\.title).joined(separator: ", ") } ?? "?"
        row("Modes supportés", list, String(format: "GetGamingMiscSetting(0x0A) → 0x%llX", raw), nil)
    }
    if let raw = try? k.wmi(AcerWMI.getFanBehavior, 0x09) {
        row("Comportement ventilos", "brut", String(format: "GetGamingFanBehavior(0x09) → 0x%llX", raw), nil)
    }
    if let stats = try? k.cpuStats() {
        let r = meter.update(stats)
        let parts = [
            r.avgMHz.map { String(format: "moy %.2f GHz", $0 / 1000) },
            r.maxMHz.map { String(format: "max %.2f GHz", $0 / 1000) },
            r.load.map { String(format: "charge %.0f %%", $0 * 100) },
            r.packageW.map { String(format: "%.1f W", $0) },
            r.tctl.map { String(format: "Tctl %.1f °C", $0) },
        ].compactMap { $0 }
        row("CPU (\(stats.ncpu) threads)", parts.isEmpty ? "—" : "", parts.joined(separator: " · "), nil)
    }
    lines.append(allOK ? "\nToutes les lectures sont plausibles. Activez l'écriture avec : nitroctl writes on"
                       : "\nAu moins une lecture est hors plage : ne PAS activer l'écriture.")
    return lines.joined(separator: "\n")
}

func cmdSensors(watch: Bool) {
    let k = openKext()
    let meter = CPUMeter()
    if let first = try? k.cpuStats() { _ = meter.update(first) }
    Thread.sleep(forTimeInterval: 0.5)
    if let info = try? k.info() {
        print("NitroWMI \(info.version) · méthode \(info.wmiMethod) · _UID \(info.wmiUID) · EC \(info.hasEC ? "oui" : "non") · SMN \(info.hasSMN ? "oui" : "non") · client \(info.privileged ? "root" : "utilisateur")")
    }
    print("Test de lecture (aucune écriture) :\n")
    repeat {
        let report = sensorsReport(k, meter: meter)
        if watch { print("\u{1B}[H\u{1B}[2J\(Date())\n") }
        print(report)
        if watch { Thread.sleep(forTimeInterval: 1) }
    } while watch
}

func cmdInfo() {
    let k = openKext()
    do {
        let i = try k.info()
        print("""
        NitroWMI \(i.version)
          méthode WMI      \(i.wmiMethod)  (_UID \(i.wmiUID))
          EC (PNP0C09)     \(i.hasEC ? "présent" : "absent")
          SMN (Tctl)       \(i.hasSMN ? "présent" : "absent")
          APERF/MPERF      \(i.hasAPERF ? "oui" : "non")    RAPL \(i.hasRAPL ? "oui" : "non")
          watchdog         \(i.watchdogMs / 1000) s, \(i.armed ? "armé" : "au repos"), failsafes déclenchés : \(i.failsafeCount)
          clients root     \(i.privClients)
        _WDG :
        """)
        for b in try k.wdg() {
            print("  \(b.guid)  \(pad(b.kind, 14)) instances \(b.instances) flags 0x\(String(format: "%02X", b.flags))")
        }
    } catch { fail("\(error)") }
}

func cmdEC() {
    do {
        let bytes = try openKext().ecDump()
        print("     " + (0..<16).map { String(format: "%02X", $0) }.joined(separator: " "))
        for row in 0..<16 {
            let line = (0..<16).map { String(format: "%02X", bytes[row * 16 + $0]) }.joined(separator: " ")
            print(String(format: "%02X:  ", row * 16) + line)
        }
    } catch { fail("\(error)") }
}

func cmdACPI(_ args: [String]) {
    guard args.count >= 2 else { fail("usage : nitroctl acpi DSDT dsdt.aml") }
    let instance = args.count >= 3 ? UInt32(args[1]) ?? 0 : 0
    let path = args.last!
    do {
        let data = try openKext().acpiTable(args[0].uppercased(), instance: instance)
        try data.write(to: URL(fileURLWithPath: path))
        print("\(args[0].uppercased()) #\(instance) : \(data.count) octets → \(path)")
    } catch { fail("\(error)") }
}

// MARK: Daemon commands

func daemon() -> (NSXPCConnection, NitroDaemonXPC) {
    let c = NSXPCConnection(machServiceName: NitroXPC.machService, options: .privileged)
    c.remoteObjectInterface = NSXPCInterface(with: NitroDaemonXPC.self)
    c.resume()
    guard let p = c.synchronousRemoteObjectProxyWithErrorHandler({ fail("service injoignable : \($0.localizedDescription)") }) as? NitroDaemonXPC
    else { fail("proxy XPC invalide") }
    return (c, p)
}

func status(_ p: NitroDaemonXPC) -> Snapshot {
    var snap: Snapshot?
    p.status { snap = try? JSONDecoder().decode(Snapshot.self, from: $0) }
    guard let snap else { fail("réponse illisible du service") }
    return snap
}

func check(_ error: String?) {
    if let error { fail(error) }
}

func cmdStatus() {
    let (_, p) = daemon()
    let s = status(p)
    func t(_ v: Double?) -> String { v.map { String(format: "%.0f °C", $0) } ?? "—" }
    print("""
    nitrocontrold \(s.daemonVersion) · kext \(s.kextLoaded ? s.kextVersion ?? "?" : "absent") · écriture \(s.writesEnabled ? "activée" : "verrouillée")
      CPU \(t(s.cpuTemp))  GPU \(t(s.gpuTemp))  système \(t(s.systemTemp))  Tctl \(t(s.tctl))
      ventilos CPU \(s.cpuFanRPM.map(String.init) ?? "—") tr/min · GPU \(s.gpuFanRPM.map(String.init) ?? "—") tr/min
      mode ventilos \(s.fanMode.title) (appliqué : \(s.appliedFanMode.title))\(s.coolBoost ? " + CoolBoost" : "")\(s.thermalGuardActive ? " · GARDE THERMIQUE" : "")
      profil \(s.profile?.title ?? "—") · secteur \(s.onACPower.map { $0 ? "oui" : "non" } ?? "?")
    """)
    if let e = s.lastError { print("  dernière erreur : \(e)") }
}

func cmdWrites(_ on: Bool) {
    let (_, p) = daemon()
    p.setWritesEnabled(on) { check($0) }
    print("Commandes d'écriture \(on ? "activées" : "désactivées").")
}

func cmdProfile(_ name: String) {
    let map: [String: PerformanceProfile] = ["quiet": .quiet, "balanced": .balanced, "normal": .balanced,
                                             "performance": .performance, "turbo": .turbo, "eco": .eco]
    guard let profile = map[name.lowercased()] else { fail("profil inconnu : \(name)") }
    let (_, p) = daemon()
    p.setProfile(profile.rawValue) { check($0) }
    print("Profil : \(profile.title)")
}

func cmdFan(_ args: [String]) {
    guard let modeName = args.first else { fail("usage : nitroctl fan auto|max|custom <cpu%> <gpu%>") }
    let (_, p) = daemon()
    switch modeName {
    case "auto":
        p.setFanMode(FanMode.auto.rawValue, cpuPercent: 50, gpuPercent: 50) { check($0) }
        print("Ventilateurs : Auto")
        return
    case "max":
        p.setFanMode(FanMode.max.rawValue, cpuPercent: 100, gpuPercent: 100) { check($0) }
    case "custom":
        guard args.count == 3, let c = Int(args[1]), let g = Int(args[2]) else { fail("usage : nitroctl fan custom <cpu%> <gpu%>") }
        p.setFanMode(FanMode.custom.rawValue, cpuPercent: c, gpuPercent: g) { check($0) }
    default:
        fail("mode inconnu : \(modeName)")
    }
    print("Ventilateurs : \(modeName). Ctrl-C pour quitter (le service repasse alors en Auto).")
    while true {
        let s = status(p)
        print("\r  CPU \(s.cpuFanRPM ?? 0) tr/min · GPU \(s.gpuFanRPM ?? 0) tr/min · \(Int(s.cpuTemp ?? 0))/\(Int(s.gpuTemp ?? 0)) °C   ", terminator: "")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 2)
    }
}

/// Encodings must match the values seen in the AcerHardwareService / AcerAgentService disassembly.
func cmdSelftest() {
    precondition(AcerWMI.fanBehavior(cpu: .auto, gpu: .auto) == 0x410009)
    precondition(AcerWMI.fanBehavior(cpu: .max, gpu: .max) == 0x820009)
    precondition(AcerWMI.fanBehavior(cpu: .custom, gpu: .custom) == 0xC30009)
    precondition(AcerWMI.fanSpeed(bit: AcerWMI.cpuFanBit, percent: 60) == 0x3C01)
    precondition(AcerWMI.fanSpeed(bit: AcerWMI.gpuFanBit, percent: 150) == 0x6404)
    precondition(AcerWMI.setProfile(.turbo) == 0x50B)
    precondition(AcerWMI.Sensor.gpuTemp.input == 0x0A01)
    precondition(AcerWMI.sensorValue(0x3400) == 0x34 && AcerWMI.sensorValue(0x3401) == nil)
    precondition(AcerWMI.profiles(fromBitmap: 0x33) == [.quiet, .balanced, .performance, .turbo])
    print("selftest OK")
}

// MARK: Main

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()
switch command {
case "selftest": cmdSelftest()
case "sensors", "test": cmdSensors(watch: args.contains("--watch"))
case "info": cmdInfo()
case "ec": cmdEC()
case "acpi": cmdACPI(args)
case "status": cmdStatus()
case "writes": cmdWrites(args.first == "on")
case "profile": cmdProfile(args.first ?? "")
case "fan": cmdFan(args)
default: print(usage)
}
