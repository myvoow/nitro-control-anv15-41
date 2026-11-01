import Foundation

public enum NitroXPC {
    public static let machService = "com.myvo.nitrocontrold"
    public static let version = "1.0.0"
}

/// Interface exported by nitrocontrold. Snapshots travel as JSON-encoded `Snapshot`.
/// Every call counts as a heartbeat for the failsafe.
@objc public protocol NitroDaemonXPC {
    func status(_ reply: @escaping (Data) -> Void)
    func setFanMode(_ mode: Int, cpuPercent: Int, gpuPercent: Int, reply: @escaping (String?) -> Void)
    func setCoolBoost(_ enabled: Bool, reply: @escaping (String?) -> Void)
    func setProfile(_ profile: Int, reply: @escaping (String?) -> Void)
    func setWritesEnabled(_ enabled: Bool, reply: @escaping (String?) -> Void)
}
