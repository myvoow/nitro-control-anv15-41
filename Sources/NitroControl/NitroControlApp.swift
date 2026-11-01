import AppKit
import NitroKit
import SwiftUI

@main
struct NitroControlApp: App {
    @StateObject private var store = NitroStore()

    var body: some Scene {
        Window("Nitro Control", id: "main") {
            MainView().environmentObject(store)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView().environmentObject(store)
        } label: {
            let temp = store.snapshot.highestTemp.map { "\(Int($0))°" } ?? "—"
            Text("\(Image(systemName: store.snapshot.appliedFanMode.symbol)) \(temp)")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Polls nitrocontrold once a second; each poll doubles as the failsafe heartbeat.
/// Quitting the app closes the XPC connection, and the daemon puts the fans back on Auto.
final class NitroStore: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var connected = false
    @Published var error: String?
    private var connection: NSXPCConnection?
    private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    private var daemon: NitroDaemonXPC? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: NitroXPC.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: NitroDaemonXPC.self)
            c.invalidationHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.connection = nil
                    self?.connected = false
                }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            DispatchQueue.main.async { self?.connected = false }
        } as? NitroDaemonXPC
    }

    func refresh() {
        daemon?.status { data in
            guard let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.connected = true
                self?.snapshot = snap
            }
        }
    }

    private func finish(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.error = message
            self?.refresh()
        }
    }

    func setFanMode(_ mode: FanMode) {
        daemon?.setFanMode(mode.rawValue, cpuPercent: snapshot.cpuFanPercent, gpuPercent: snapshot.gpuFanPercent) { self.finish($0) }
    }

    func setSpeeds(cpu: Int, gpu: Int) {
        daemon?.setFanMode(FanMode.custom.rawValue, cpuPercent: cpu, gpuPercent: gpu) { self.finish($0) }
    }

    func setCoolBoost(_ on: Bool) {
        daemon?.setCoolBoost(on) { self.finish($0) }
    }

    func setProfile(_ profile: PerformanceProfile) {
        daemon?.setProfile(profile.rawValue) { self.finish($0) }
    }

    /// Why the controls are unusable, if they are.
    var notice: String? {
        if !connected { return "Service nitrocontrold injoignable — installez-le avec « make install »." }
        if !snapshot.kextLoaded { return "NitroWMI.kext n'est pas chargé — redémarrez après l'installation." }
        if !snapshot.writesEnabled { return "Commandes verrouillées : vérifiez « nitroctl sensors », puis « nitroctl writes on »." }
        return nil
    }

    var profiles: [PerformanceProfile] {
        snapshot.supportedProfiles.isEmpty ? [.quiet, .balanced, .performance, .turbo] : snapshot.supportedProfiles
    }
}
