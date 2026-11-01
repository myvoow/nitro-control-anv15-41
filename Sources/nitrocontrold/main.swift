import Foundation
import NitroKit

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("nitrocontrold must run as root (launchd daemon)\n".utf8))
    exit(1)
}

let controller = HardwareController()
let service = XPCService(controller: controller)
let listener = NSXPCListener(machServiceName: NitroXPC.machService)
listener.delegate = service
listener.resume()
controller.start()

// launchd sends SIGTERM on unload/shutdown: hand the fans back to the EC first.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        controller.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
