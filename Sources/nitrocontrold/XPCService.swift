import Foundation
import NitroKit

final class XPCService: NSObject, NSXPCListenerDelegate {
    let controller: HardwareController

    init(controller: HardwareController) {
        self.controller = controller
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard controller.isAllowed(uid: connection.effectiveUserIdentifier) else {
            log("refused XPC client uid \(connection.effectiveUserIdentifier) pid \(connection.processIdentifier)")
            return false
        }
        let session = Session(controller: controller)
        connection.exportedInterface = NSXPCInterface(with: NitroDaemonXPC.self)
        connection.exportedObject = session
        let gone: () -> Void = { [controller, id = session.id] in controller.clientGone(id) }
        connection.invalidationHandler = gone
        connection.interruptionHandler = gone
        controller.touch(session.id)
        connection.resume()
        return true
    }
}

/// One per connection; its id is what the failsafe tracks.
final class Session: NSObject, NitroDaemonXPC {
    let id = UUID()
    let controller: HardwareController

    init(controller: HardwareController) {
        self.controller = controller
    }

    func status(_ reply: @escaping (Data) -> Void) {
        reply(controller.status(from: id))
    }

    func setFanMode(_ mode: Int, cpuPercent: Int, gpuPercent: Int, reply: @escaping (String?) -> Void) {
        guard let m = FanMode(rawValue: mode) else { return reply("Mode inconnu") }
        reply(controller.setFanMode(m, cpu: cpuPercent, gpu: gpuPercent, from: id))
    }

    func setCoolBoost(_ enabled: Bool, reply: @escaping (String?) -> Void) {
        reply(controller.setCoolBoost(enabled, from: id))
    }

    func setProfile(_ profile: Int, reply: @escaping (String?) -> Void) {
        reply(controller.setProfile(profile, from: id))
    }

    func setWritesEnabled(_ enabled: Bool, reply: @escaping (String?) -> Void) {
        reply(controller.setWritesEnabled(enabled, from: id))
    }
}
