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

// MARK: - Home (task-first start screen)

struct HomeView: View {
    @ObservedObject var m: DeviceManager
    @State private var shown = false

    private func count(_ id: String) -> Int { m.smartAlbums.first { $0.id == id }?.assets.count ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What would you like to do?").font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("\(m.deviceName) is connected · \(m.osName) \(m.details.iosVersion)")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let b = m.details.batteryPercent {
                        gauge(Double(b) / 100, "\(b)%", m.details.isCharging == true ? "Charging" : "Battery", b < 20 ? .red : .green)
                    }
                    if m.details.totalDiskBytes > 0 {
                        gauge(m.details.usedFraction, Fmt.bytes(m.details.freeDiskBytes), "Free", m.details.usedFraction > 0.9 ? .orange : Theme.accent)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                  if m.isAndroid {
                    task(0, "camera.fill", "Copy camera photos to this Mac",
                         "Everything the camera took, in the DCIM folder.", [.blue, .cyan]) { m.openFolder("/sdcard/DCIM") }
                    task(1, "photo.on.rectangle.angled", "Pictures and screenshots",
                         "Saved images, screenshots and pictures from apps.", [.indigo, .purple]) { m.openFolder("/sdcard/Pictures") }
                    task(2, "arrow.up.doc.fill", "Send files to the \(m.deviceKind)",
                         "Open Download, or any folder, and drag files in from Finder.", [.mint, .teal]) { m.openFolder("/sdcard/Download") }
                    task(3, "video.fill", "Movies and recordings",
                         "Videos saved in the Movies folder.", [.purple, .pink]) { m.openFolder("/sdcard/Movies") }
                    task(4, "folder.fill", "Browse all storage",
                         "Every folder in the device's shared storage.", [.orange, .pink]) { m.selection = "nav_files" }
                    task(5, "info.circle.fill", "Check the \(m.deviceKind)",
                         "Battery, storage, serial number and other details.", [.gray, .blue]) { m.selection = "nav_device" }
                  } else {
                    task(0, "photo.on.rectangle.angled", "Copy photos to this Mac",
                         "\(Fmt.count(count("smart_all"))) photos and videos. Pick some or take everything.", [.blue, .cyan]) { m.selection = "smart_all" }
                    task(1, "eye.slash.fill", "Get the Hidden album",
                         "\(Fmt.count(count("smart_hidden"))) hidden items, kept out of every other album.", [.indigo, .purple]) { m.selection = "smart_hidden" }
                    task(2, "arrow.up.doc.fill", "Send files to the \(m.deviceKind)",
                         m.apps.isEmpty ? "No apps on this device share a folder yet." : "Drop files into \(m.apps.count) apps, such as video players and readers.",
                         [.mint, .teal]) { if let a = m.apps.first { m.selection = "app:\(a.id)" } }
                        .disabled(m.apps.isEmpty).opacity(m.apps.isEmpty ? 0.5 : 1)
                    task(3, "clock.arrow.circlepath", "Back up the \(m.deviceKind)",
                         "A full copy of messages, app data and settings, to this Mac or a drive.", [.orange, .pink]) { m.selection = "nav_backup" }
                    task(4, "video.fill", "Just the videos",
                         "\(Fmt.count(count("smart_videos"))) videos, usually the biggest files. Sort by size to free space.", [.purple, .pink]) { m.selection = "smart_videos" }
                    task(5, "info.circle.fill", "Check the \(m.deviceKind)",
                         "Battery health, storage, serial number and other details.", [.gray, .blue]) { m.selection = "nav_device" }
                  }
                }
            }
            .padding(28)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(m.deviceName)
        .navigationSubtitle("")
        .onAppear { shown = true }
    }

    private func gauge(_ fraction: Double, _ value: String, _ label: String, _ color: Color) -> some View {
        ZStack {
            Ring(fraction: fraction, color: color)
            VStack(spacing: 0) {
                Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
        }
        .frame(width: 78, height: 78)
    }

    private func task(_ order: Int, _ symbol: String, _ title: String, _ text: String, _ colors: [Color], action: @escaping () -> Void) -> some View {
        TaskTile(symbol: symbol, title: title, text: text, colors: colors, action: action)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 22)
            .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05 * Double(order)), value: shown)
    }
}

struct TaskTile: View {
    let symbol: String
    let title: String
    let text: String
    let colors: [Color]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white))
                        .shadow(color: colors[0].opacity(hovering ? 0.55 : 0.3), radius: hovering ? 16 : 8, y: 5)
                        .rotationEffect(.degrees(hovering ? -4 : 0))
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(hovering ? Color.primary : Color.secondary.opacity(0.5))
                        .offset(x: hovering ? 4 : 0)
                }
                Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: hovering ? colors : [Color.primary.opacity(0.08), Color.primary.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: hovering ? 1.5 : 1))
            .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 18, y: 8)
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
    }
}

// MARK: - Device details

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
