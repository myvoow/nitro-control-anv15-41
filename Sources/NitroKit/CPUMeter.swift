import CNitroWMI
import Foundation

public struct CPUReading {
    public var avgMHz: Double?
    public var maxMHz: Double?
    public var load: Double?
    public var packageW: Double?
    public var tctl: Double?
}

/// Turns successive APERF/MPERF/RAPL samples into frequencies and power.
/// MPERF ticks at the P0 rate (== TSC on Zen) while a core is in C0.
public final class CPUMeter {
    private var previous: NitroCPUStats?
    private let tscHz: Double

    public init() {
        var hz: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("machdep.tsc.frequency", &hz, &size, nil, 0)
        tscHz = hz > 0 ? Double(hz) : 3.3e9
    }

    public func update(_ s: NitroCPUStats) -> CPUReading {
        var r = CPUReading()
        if s.flags & NITRO_CPU_TCTL != 0 {
            var t = Double((s.tctlRaw >> 21) & 0x7FF) / 8.0
            if s.tctlRaw & (1 << 19) != 0 { t -= 49 }
            r.tctl = t
        }
        defer { previous = s }
        guard let p = previous, s.tsc > p.tsc else { return r }
        let dTSC = Double(s.tsc - p.tsc)

        if s.flags & NITRO_CPU_APERF != 0, s.ncpu > 0 {
            let a = Self.array(s.aperf), m = Self.array(s.mperf)
            let pa = Self.array(p.aperf), pm = Self.array(p.mperf)
            var sumA = 0.0, sumM = 0.0, best = 0.0
            for i in 0..<Int(s.ncpu) where a[i] >= pa[i] && m[i] > pm[i] {
                let da = Double(a[i] - pa[i]), dm = Double(m[i] - pm[i])
                sumA += da
                sumM += dm
                if dm > dTSC * 0.02 { best = max(best, tscHz * da / dm) }
            }
            if sumM > 0 {
                r.avgMHz = tscHz * sumA / sumM / 1e6
                r.maxMHz = best > 0 ? best / 1e6 : nil
                r.load = min(1, sumM / (dTSC * Double(s.ncpu)))
            }
        }
        if s.flags & NITRO_CPU_RAPL != 0 {
            let unit = pow(0.5, Double((s.raplUnit >> 8) & 0x1F))
            let dE = Double((s.pkgEnergy &- p.pkgEnergy) & 0xFFFF_FFFF) * unit
            r.packageW = dE / (dTSC / tscHz)
        }
        return r
    }

    private static func array<T>(_ tuple: T) -> [UInt64] {
        withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: UInt64.self)) }
    }
}
