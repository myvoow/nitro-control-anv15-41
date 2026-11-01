import AppKit
import NitroKit
import SwiftUI

// MARK: - Main window

struct MainView: View {
    @EnvironmentObject var store: NitroStore

    var body: some View {
        let s = store.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(s)
                if let notice = store.notice {
                    Label(notice, systemImage: "lock.fill").font(.callout).glassCard(tint: .orange)
                }
                if let error = store.error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).glassCard()
                }
                HStack(spacing: 16) {
                    TempTile(title: "CPU", symbol: "cpu", value: s.cpuTemp)
                    TempTile(title: "GPU", symbol: "display", value: s.gpuTemp)
                    TempTile(title: "Système", symbol: "laptopcomputer", value: s.systemTemp)
                }
                HStack(spacing: 16) {
                    FanGauge(title: "Ventilateur CPU", rpm: s.cpuFanRPM)
                    FanGauge(title: "Ventilateur GPU", rpm: s.gpuFanRPM)
                    CPUCard(snapshot: s)
                }
                HStack(alignment: .top, spacing: 16) {
                    FanControlCard().glassCard()
                    ProfileCard().glassCard()
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .frame(minWidth: 880, minHeight: 640)
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    private func header(_ s: Snapshot) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nitro Control").font(.largeTitle.weight(.semibold))
                Text("Acer Nitro V 15 · ANV15-41").foregroundStyle(.secondary)
            }
            Spacer()
            if let ac = s.onACPower {
                Label(ac ? "Secteur" : "Batterie", systemImage: ac ? "bolt.fill" : "battery.75percent").chip()
            }
            if let p = s.profile {
                Label(p.title, systemImage: p.symbol).chip()
            }
            Label(s.appliedFanMode.title + (s.coolBoost ? " · CoolBoost" : ""), systemImage: s.appliedFanMode.symbol).chip()
        }
    }
}

struct TempTile: View {
    let title: String
    let symbol: String
    let value: Double?

    var body: some View {
        // Bar spans 30–100 °C.
        let fraction = min(1, max(0, ((value ?? 30) - 30) / 70))
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { "\(Int($0))" } ?? "—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value ?? 0))
                Text("°C").font(.title3).foregroundStyle(.secondary)
            }
            .foregroundStyle(heatColor(value))
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.blue, .orange, .red], startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) { Capsule().frame(width: geo.size.width * fraction) }
            }
            .frame(height: 8)
        }
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Température \(title)")
        .accessibilityValue(value.map { "\(Int($0)) degrés" } ?? "indisponible")
    }
}

struct FanGauge: View {
    let title: String
    let rpm: Int?
    private let stroke = StrokeStyle(lineWidth: 14, lineCap: .round)

    var body: some View {
        let value = Double(rpm ?? 0)
        // shortcut: full scale is 6000 tr/min (or the highest reading), not the fan's rated maximum.
        let fraction = value / max(6000, value)
        VStack(spacing: 10) {
            ZStack {
                arc(1).stroke(.quaternary, style: stroke)
                arc(fraction).stroke(
                    AngularGradient(colors: [.cyan, .blue, .purple], center: .center,
                                    startAngle: .degrees(135), endAngle: .degrees(405)),
                    style: stroke)
                VStack(spacing: 0) {
                    Text(rpm.map(String.init) ?? "—")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: value))
                    Text("tr/min").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)
            Label(title, systemImage: "fanblades.fill").font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(rpm.map { "\($0) tours par minute" } ?? "indisponible")
    }

    private func arc(_ f: Double) -> some Shape {
        Circle().trim(from: 0, to: 0.75 * f).rotation(.degrees(135))
    }
}

struct CPUCard: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Processeur", systemImage: "cpu").font(.headline).foregroundStyle(.secondary)
            row("Fréquence moyenne", snapshot.cpuFreqMHz.map { String(format: "%.2f GHz", $0 / 1000) })
            row("Cœur le plus rapide", snapshot.cpuMaxFreqMHz.map { String(format: "%.2f GHz", $0 / 1000) })
            row("Charge", snapshot.cpuLoad.map { String(format: "%.0f %%", $0 * 100) })
            row("Puissance package", snapshot.packagePowerW.map { String(format: "%.1f W", $0) })
            row("Tctl", snapshot.tctl.map { String(format: "%.1f °C", $0) })
        }
        .glassCard()
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—").monospacedDigit()
        }
    }
}

struct FanControlCard: View {
    @EnvironmentObject var store: NitroStore
    @State private var cpu = 50.0
    @State private var gpu = 50.0

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 14) {
            Label("Ventilation", systemImage: "fanblades.fill").font(.headline)
            Picker("Mode", selection: Binding(get: { s.fanMode }, set: store.setFanMode)) {
                ForEach(FanMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if s.fanMode == .custom {
                Group {
                    speedSlider("CPU", $cpu)
                    speedSlider("GPU", $gpu)
                }
                .onAppear {
                    cpu = Double(s.cpuFanPercent)
                    gpu = Double(s.gpuFanPercent)
                }
            }
            Toggle(isOn: Binding(get: { s.coolBoost }, set: store.setCoolBoost)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CoolBoost")
                    Text("Courbe plus agressive que celle de l'EC (mode Auto)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(s.fanMode != .auto)
            if s.thermalGuardActive {
                Label("Garde thermique : ventilateurs forcés au maximum", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text("Retour automatique en Auto si l'app se ferme ou si le service ne répond plus.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!s.writesEnabled)
    }

    private func speedSlider(_ name: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(name).frame(width: 36, alignment: .leading)
            Slider(value: value, in: 20...100, step: 5) { editing in
                if !editing { store.setSpeeds(cpu: Int(cpu), gpu: Int(gpu)) }
            }
            .accessibilityLabel("Vitesse ventilateur \(name)")
            Text("\(Int(value.wrappedValue)) %").monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }
}

struct ProfileCard: View {
    @EnvironmentObject var store: NitroStore

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 14) {
            Label("Mode de fonctionnement", systemImage: "gauge.with.dots.needle.67percent").font(.headline)
            Picker("Mode", selection: Binding(get: { s.profile }, set: { if let p = $0 { store.setProfile(p) } })) {
                ForEach(store.profiles) { Label($0.title, systemImage: $0.symbol).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(s.profile?.subtitle ?? "Mode actuel inconnu").font(.callout).foregroundStyle(.secondary)
        }
        .disabled(!s.writesEnabled)
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @EnvironmentObject var store: NitroStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MiniTemp(name: "CPU", value: s.cpuTemp)
                MiniTemp(name: "GPU", value: s.gpuTemp)
                MiniTemp(name: "Système", value: s.systemTemp)
            }
            Text("Ventilateurs : CPU \(s.cpuFanRPM.map(String.init) ?? "—") · GPU \(s.gpuFanRPM.map(String.init) ?? "—") tr/min")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Ventilation", selection: Binding(get: { s.fanMode }, set: store.setFanMode)) {
                ForEach(FanMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!s.writesEnabled)
            Picker("Mode", selection: Binding(get: { s.profile }, set: { if let p = $0 { store.setProfile(p) } })) {
                ForEach(store.profiles) { Text($0.title).tag(Optional($0)) }
            }
            .disabled(!s.writesEnabled)
            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Button("Ouvrir Nitro Control") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct MiniTemp: View {
    let name: String
    let value: Double?

    var body: some View {
        VStack(spacing: 2) {
            Text(value.map { "\(Int($0))°" } ?? "—")
                .font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(heatColor(value))
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Style

/// Blue ≤ 45 °C, orange at 72 °C, red from 90 °C.
func heatColor(_ t: Double?) -> Color {
    guard let t else { return .secondary }
    let stops: [(t: Double, r: Double, g: Double, b: Double)] = [(45, 0.25, 0.55, 1.0), (72, 1.0, 0.6, 0.1), (90, 1.0, 0.22, 0.2)]
    if t <= stops[0].t { return Color(red: stops[0].r, green: stops[0].g, blue: stops[0].b) }
    for (a, b) in zip(stops, stops.dropFirst()) where t <= b.t {
        let k = (t - a.t) / (b.t - a.t)
        return Color(red: a.r + (b.r - a.r) * k, green: a.g + (b.g - a.g) * k, blue: a.b + (b.b - a.b) * k)
    }
    return Color(red: 1.0, green: 0.22, blue: 0.2)
}

extension View {
    /// Liquid Glass on macOS 26, translucent material before.
    @ViewBuilder func glass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0.opacity(0.3)) } ?? .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    func glassCard(tint: Color? = nil) -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: tint)
    }

    func chip() -> some View {
        font(.callout).padding(.horizontal, 12).padding(.vertical, 6).glass(in: Capsule())
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
