import SwiftUI
import AppKit

// Screens shown before a device is ready: connect, trust, loading, errors.

// MARK: - Sidebar

struct StatusView: View {
    @ObservedObject var m: DeviceManager
    @State private var pulse = false
    @State private var stepsShown = false

    private var phaseKey: String {
        switch m.phase {
        case .searching: return "searching"
        case .toolsMissing: return "tools"
        case .noDevice: return "none"
        case .needsTrust: return "trust"
        case .loading: return "loading"
        case .ready: return "ready"
        case .catalogError: return "error"
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 22) { content }
                .padding(40)
                .id(phaseKey)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: phaseKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { m.connect(silent: false) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Look for a device again")
            }
        }
        .navigationTitle("PortHop")
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    @ViewBuilder private var content: some View {
        switch m.phase {
        case .searching:
            ProgressView().controlSize(.large)
            Text("Looking for your device…").font(.title3).foregroundStyle(.secondary)
        case .loading(let msg):
            LinkLoader(device: m.deviceName, symbol: m.isIPad ? "ipad" : "iphone", organising: msg.hasPrefix("Organising"))
        case .noDevice where m.isRestarting:
            hero("arrow.clockwise", rings: true)
            Text("\(m.deviceName) is restarting").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("It will appear here again by itself in a minute or two. If it asks, unlock it and tap Trust.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            waiting("Waiting for it to come back")
        case .noDevice:
            hero("cable.connector", rings: true)
            VStack(spacing: 6) {
                Text(m.tools?.adb != nil ? "Connect your iPhone, iPad or Android" : "Connect your iPhone or iPad").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Copy photos and videos to your Mac or an external drive over USB.").font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                step(1, "cable.connector.horizontal", "Plug in", "Use a USB cable that carries data.")
                step(2, "lock.open.fill", "Unlock & Trust", "Unlock the device and tap Trust if it asks.")
                step(3, "arrow.right.circle.fill", "Hop it across", "Drag a group of photos onto a folder or drive.")
            }
            .frame(maxWidth: 720)
            .onAppear { stepsShown = true }
            if m.tools?.adb == nil { AndroidSetupRow(m: m) }
            waiting("Waiting for a device — it will appear here automatically")
        case .needsTrust(let msg):
            hero("lock.iphone", rings: true)
            Text("Unlock and Trust").font(.system(size: 30, weight: .bold, design: .rounded))
            Text(msg).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            waiting("Checking again every few seconds")
        case .toolsMissing:
            hero("shippingbox.fill", rings: false)
            Text("A part of the app is missing").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("The built-in device tools were not found. Rebuild the app, or install them with Homebrew in Terminal:")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            HStack(spacing: 10) {
                Text("brew install libimobiledevice").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install libimobiledevice", forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
            waiting("Checking again every few seconds")
        case .catalogError(let msg):
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 52)).foregroundStyle(.orange)
            Text("Can't read this photo library").font(.system(size: 30, weight: .bold, design: .rounded))
            Text(msg).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            Text("Nothing on the device was changed.").font(.callout).foregroundStyle(.secondary)
            Button("Try Again") { m.connect(silent: false) }.buttonStyle(PrimaryButtonStyle())
        case .ready:
            EmptyView()
        }
    }

    private func hero(_ symbol: String, rings: Bool) -> some View {
        ZStack {
            if rings {
                ForEach(0..<3, id: \.self) { i in
                    Circle().stroke(Theme.accent.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 112, height: 112)
                        .scaleEffect(pulse ? 2.1 : 1)
                        .opacity(pulse ? 0 : 0.7)
                        .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: pulse)
                }
            }
            Circle().fill(Theme.gradient).frame(width: 112, height: 112)
                .shadow(color: Theme.accent.opacity(0.45), radius: 26, y: 10)
            Image(systemName: symbol).font(.system(size: 46, weight: .medium)).foregroundStyle(.white)
        }
        .frame(height: 150)
    }

    private func step(_ n: Int, _ symbol: String, _ title: String, _ text: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.gradient)
                    Spacer()
                    Text("\(n)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(Circle().fill(Color.primary.opacity(0.08)))
                }
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        }
        .opacity(stepsShown ? 1 : 0)
        .offset(y: stepsShown ? 0 : 18)
        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.12 * Double(n)), value: stepsShown)
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }
}
