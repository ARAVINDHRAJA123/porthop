import SwiftUI
import AppKit

// MARK: - Screen transition

private struct GlideModifier: ViewModifier {
    let progress: Double   // 0 = fully hidden, 1 = in place
    let rise: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 14)
            .scaleEffect(0.975 + 0.025 * progress)
            .offset(y: (1 - progress) * rise)
    }
}

extension AnyTransition {
    /// Incoming screens rise into focus; outgoing ones blur away. Turn off under View ▸ Animated Screen Transitions.
    static var glide: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: GlideModifier(progress: 0, rise: 18), identity: GlideModifier(progress: 1, rise: 18)),
            removal: .modifier(active: GlideModifier(progress: 0, rise: -10), identity: GlideModifier(progress: 1, rise: -10)))
    }
}

struct Ring: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 7
    @State private var shown = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            Circle().trim(from: 0, to: shown ? min(1, max(0, fraction)) : 0)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { withAnimation(.spring(response: 1.0, dampingFraction: 0.8).delay(0.2)) { shown = true } }
    }
}

struct DeviceView: View {
    @ObservedObject var m: DeviceManager
    @State private var confirm: String? = nil
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    Image(systemName: m.isIPad ? "ipad" : (m.isAndroid ? "smartphone" : "iphone")).font(.system(size: 52, weight: .light)).foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.deviceName).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        Text("\(m.details.modelName) · \(m.osName) \(m.details.iosVersion) · \(m.device?.isNetwork == true ? "Wi-Fi" : "USB")")
                            .font(.title3).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.gradient))

                HStack(alignment: .top, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Battery").font(.headline)
                            HStack(spacing: 16) {
                                ZStack {
                                    Ring(fraction: Double(m.details.batteryPercent ?? 0) / 100, color: (m.details.batteryPercent ?? 100) < 20 ? .red : .green)
                                    Text(m.details.batteryPercent.map { "\($0)%" } ?? "—").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                                }
                                .frame(width: 70, height: 70)
                                VStack(alignment: .leading, spacing: 6) {
                                    fact("Charging", m.details.isCharging.map { $0 ? "Yes" : "No" } ?? "—")
                                    fact("Health", m.details.batteryHealth.map { "\($0)% of original capacity" } ?? "Not reported")
                                    fact("Charge cycles", m.details.cycleCount.map { Fmt.count($0) } ?? "Not reported")
                                }
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Storage").font(.headline)
                            if m.details.totalDiskBytes > 0 {
                                StorageBar(fraction: m.details.usedFraction).frame(height: 12)
                                fact("Used", Fmt.bytes(m.details.totalDiskBytes - m.details.freeDiskBytes))
                                fact("Available", Fmt.bytes(m.details.freeDiskBytes))
                                fact("Capacity", Fmt.bytes(m.details.totalDiskBytes))
                            } else {
                                Text("Not reported").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Device information").font(.headline)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(m.details.info.map { "\($0.label): \($0.value)" }.joined(separator: "\n"), forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                            } label: { Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc") }
                                .buttonStyle(.link)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())], alignment: .leading, spacing: 9) {
                            ForEach(m.details.info) { r in
                                HStack(spacing: 8) {
                                    Image(systemName: r.symbol).frame(width: 18).foregroundStyle(.secondary)
                                    Text(r.label).foregroundStyle(.secondary)
                                    Spacer(minLength: 8)
                                    Text(r.value).font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1).truncationMode(.middle)
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 13))
                            }
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quick actions").font(.headline)
                        HStack(spacing: 10) {
                            Button { confirm = "restart" } label: { Label("Restart", systemImage: "arrow.clockwise") }.buttonStyle(SoftButtonStyle())
                            Button { confirm = "sleep" } label: { Label("Sleep", systemImage: "moon.fill") }.buttonStyle(SoftButtonStyle())
                            if !m.isAndroid {
                                Button { m.selection = "nav_backup" } label: { Label("Back Up…", systemImage: "clock.arrow.circlepath") }.buttonStyle(SoftButtonStyle())
                            }
                            Button { m.connect(silent: false) } label: { Label("Refresh Details", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(SoftButtonStyle())
                            Spacer()
                        }
                        .disabled(m.isExporting || m.afcBusy || m.backupRunning || !m.canPower)
                        if !m.powerMessage.isEmpty {
                            Text(m.powerMessage).font(.callout).foregroundStyle(.secondary).transition(.opacity)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: m.powerMessage)

                Text("Photo library format: \(m.catalogWarnings.isEmpty ? "recognised" : "partly recognised"). This app reads the device's own photo database, which Apple can change in any update; if that happens the app says so instead of showing wrong results.")
                    .font(.caption).foregroundStyle(.secondary)
                    .opacity(m.isAndroid ? 0 : 1)
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(m.deviceName)
        .navigationSubtitle("")
        .confirmationDialog(confirm == "restart" ? "Restart \(m.deviceName)?" : "Put \(m.deviceName) to sleep?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirm == "restart" ? "Restart" : "Sleep") { if let c = confirm { m.power(c) }; confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            Text(confirm == "restart" ? "It will disconnect, restart, and reappear here in about a minute. Nothing is erased."
                                      : "The screen turns off. Wake it and unlock to keep using it here.")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 13))
    }
}
