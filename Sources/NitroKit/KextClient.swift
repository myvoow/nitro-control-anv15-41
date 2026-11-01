import CNitroWMI
import Foundation
import IOKit

public enum NitroError: Error, CustomStringConvertible {
    case kextNotLoaded
    case ioKit(String, kern_return_t)
    case firmware(String, UInt8)

    public var description: String {
        switch self {
        case .kextNotLoaded:
            "NitroWMI.kext n'est pas chargé"
        case let .ioKit(what, kr):
            String(format: "%@ a échoué (0x%08x%@)", what, UInt32(bitPattern: kr),
                   kr == kIOReturnNotPrivileged ? ", accès root requis" : "")
        case let .firmware(what, status):
            String(format: "%@ refusé par le firmware (statut 0x%02x)", what, status)
        }
    }
}

public struct KextInfo {
    public let version: String
    public let wmiMethod: String
    public let wmiUID: String
    public let flags: UInt32
    public let ncpu: Int
    public let watchdogMs: Int
    public let failsafeCount: Int
    public let privClients: Int

    public var hasEC: Bool { flags & NITRO_INFO_EC != 0 }
    public var hasSMN: Bool { flags & NITRO_INFO_SMN != 0 }
    public var privileged: Bool { flags & NITRO_INFO_PRIVILEGED != 0 }
    public var armed: Bool { flags & NITRO_INFO_ARMED != 0 }
    public var hasAPERF: Bool { flags & NITRO_INFO_APERF != 0 }
    public var hasRAPL: Bool { flags & NITRO_INFO_RAPL != 0 }
}

public struct WDGBlock {
    public let guid: String
    public let objectId: String
    public let instances: Int
    public let flags: UInt8

    public var kind: String {
        if flags & 0x8 != 0 { return "event 0x\(String(format: "%02X", objectId.utf8.first ?? 0))" }
        if flags & 0x2 != 0 { return "method WM\(objectId)" }
        return "data WQ\(objectId)"
    }
}

/// Thin wrapper around the NitroWMI user client. Read selectors work for any user,
/// write selectors need root (the kext checks it).
public final class KextClient {
    private var conn: io_connect_t = 0

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NitroWMI"))
        guard service != 0 else { throw NitroError.kextNotLoaded }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { throw NitroError.ioKit("IOServiceOpen", kr) }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    public func info() throws -> KextInfo {
        var raw = NitroInfo()
        var size = MemoryLayout<NitroInfo>.size
        let kr = IOConnectCallStructMethod(conn, UInt32(kNitroSelGetInfo), nil, 0, &raw, &size)
        guard kr == KERN_SUCCESS else { throw NitroError.ioKit("GetInfo", kr) }
        let v = raw.version
        return KextInfo(
            version: "\(v >> 16).\((v >> 8) & 0xFF).\(v & 0xFF)",
            wmiMethod: Self.string(raw.wmiMethod),
            wmiUID: Self.string(raw.wmiUID),
            flags: raw.flags,
            ncpu: Int(raw.ncpu),
            watchdogMs: Int(raw.watchdogMs),
            failsafeCount: Int(raw.failsafeCount),
            privClients: Int(raw.privClients)
        )
    }

    /// Raw AcerGamingFunction call; returns the firmware result word.
    public func wmi(_ method: UInt32, _ input: UInt64) throws -> UInt64 {
        var inputs: [UInt64] = [UInt64(method), input]
        var output: UInt64 = 0
        var count: UInt32 = 1
        let kr = IOConnectCallScalarMethod(conn, UInt32(kNitroSelWMICall), &inputs, 2, &output, &count)
        guard kr == KERN_SUCCESS else { throw NitroError.ioKit(String(format: "WMI %u(0x%llX)", method, input), kr) }
        return output
    }

    public func sensor(_ s: AcerWMI.Sensor) throws -> (value: Int?, raw: UInt64) {
        let raw = try wmi(AcerWMI.getSysInfo, s.input)
        return (AcerWMI.sensorValue(raw), raw)
    }

    public func ecDump() throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: Int(NITRO_EC_SIZE))
        var size = buf.count
        let kr = IOConnectCallStructMethod(conn, UInt32(kNitroSelECDump), nil, 0, &buf, &size)
        guard kr == KERN_SUCCESS else { throw NitroError.ioKit("ECDump", kr) }
        return buf
    }

    public func cpuStats() throws -> NitroCPUStats {
        var stats = NitroCPUStats()
        var size = MemoryLayout<NitroCPUStats>.size
        let kr = IOConnectCallStructMethod(conn, UInt32(kNitroSelCPUStats), nil, 0, &stats, &size)
        guard kr == KERN_SUCCESS else { throw NitroError.ioKit("CPUStats", kr) }
        return stats
    }

    public func wdg() throws -> [WDGBlock] {
        var buf = [UInt8](repeating: 0, count: Int(NITRO_WDG_MAX))
        var size = buf.count
        let kr = IOConnectCallStructMethod(conn, UInt32(kNitroSelWDG), nil, 0, &buf, &size)
        guard kr == KERN_SUCCESS else { throw NitroError.ioKit("_WDG", kr) }
        return stride(from: 0, to: size - 19, by: 20).map { i in
            let b = Array(buf[i..<i + 20])
            let guid = String(format: "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                              b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
            let id = String(bytes: b[16...17].map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x3F }, encoding: .ascii) ?? "??"
            return WDGBlock(guid: guid, objectId: id, instances: Int(b[18]), flags: b[19])
        }
    }

    public func kickWatchdog() throws {
        let kr = IOConnectCallScalarMethod(conn, UInt32(kNitroSelKick), nil, 0, nil, nil)
        guard kr == KERN_SUCCESS else { throw NitroError.ioKit("Watchdog", kr) }
    }

    /// Copies an ACPI table ("DSDT", "SSDT" + instance...) from the platform expert.
    public func acpiTable(_ signature: String, instance: UInt32 = 0) throws -> Data {
        let sig = signature.utf8.prefix(4).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * UInt64($1.offset))) }
        var result = Data()
        var total = UInt64.max
        while UInt64(result.count) < total {
            var inputs: [UInt64] = [sig, UInt64(instance), UInt64(result.count)]
            var chunk = [UInt8](repeating: 0, count: Int(NITRO_TABLE_CHUNK))
            var size = chunk.count
            var count: UInt32 = 1
            let kr = IOConnectCallMethod(conn, UInt32(kNitroSelACPITable), &inputs, 3, nil, 0, &total, &count, &chunk, &size)
            guard kr == KERN_SUCCESS else { throw NitroError.ioKit("ACPI \(signature)", kr) }
            if size == 0 { break }
            result.append(contentsOf: chunk[0..<size])
        }
        return result
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
