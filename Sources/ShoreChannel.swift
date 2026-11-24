import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The channel between the shores, and the photos that fly across it during a hop.

// MARK: - Channel

/// The water between the shores: shows what is crossing, or how to start.
struct ChannelView: View {
    @ObservedObject var m: DeviceManager
    let destinationName: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 20)
            ChannelArc(active: m.isExporting || m.afcBusy).frame(height: 120)
            if m.isExporting {
                let p = m.progress
                VStack(spacing: 8) {
                    Text(m.isStopping ? "Stopping…" : "Hopping to \(destinationName ?? "your Mac")").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                    Text("\(Fmt.count(p.shownCount)) of \(Fmt.count(p.total))").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                        .monospacedDigit().contentTransition(.numericText())
                    GlowProgressBar(fraction: p.fraction).frame(width: 150)
                    Text(detail(p)).font(.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).monospacedDigit()
                    Button("Stop") { m.stopExport() }.buttonStyle(SoftButtonStyle()).disabled(m.isStopping)
                }
                .padding(18)
                .glassSurface(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if m.afcBusy {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(m.afcMessage).font(.callout).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).lineLimit(3)
                    Button("Stop") { m.stopTransfer() }.buttonStyle(SoftButtonStyle())
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "hand.draw").font(.system(size: 22)).foregroundStyle(Theme.accentLight)
                    Text("Drag a group across").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("or click a place on the right and pick what to copy. Nothing is removed from your \(m.deviceKind).")
                        .font(.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                    if !m.lastHop.isEmpty {
                        Text("Last hop: \(m.lastHop)").font(.caption2).foregroundStyle(Theme.faint).multilineTextAlignment(.center).padding(.top, 6)
                    }
                    if !m.afcMessage.isEmpty && !m.afcBusy {
                        Text(m.afcMessage).font(.caption2).foregroundStyle(m.afcMessageIsError ? Theme.warning : Theme.success).multilineTextAlignment(.center)
                    }
                    RemoveCopiedButton(m: m)
                }
                .transition(.opacity)
            }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: 240)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: m.isExporting)
    }

    private func detail(_ p: ExportProgress) -> String {
        var parts: [String] = []
        if p.bytesTotal > 0 { parts.append("\(Fmt.bytes(p.bytesDone)) of \(Fmt.bytes(p.bytesTotal))") }
        if p.bytesPerSecond > 0 {
            parts.append("\(Fmt.bytes(Int64(p.bytesPerSecond)))/s")
            let eta = Fmt.eta(Double(p.bytesTotal - p.bytesDone) / p.bytesPerSecond)
            if !eta.isEmpty { parts.append(eta) }
        }
        if p.skipped > 0 { parts.append("\(Fmt.count(p.skipped)) already there") }
        return parts.isEmpty ? "Keep the device connected and unlocked." : parts.joined(separator: "\n")
    }
}

/// A dotted arc across the water. While something is crossing, small cards hop along it.
struct ChannelArc: View {
    let active: Bool
    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in arc(phase: ctx.date.timeIntervalSinceReferenceDate) }
        } else {
            arc(phase: nil)
        }
    }

    private func arc(phase: Double?) -> some View {
        Canvas { g, size in
            let a = CGPoint(x: 6, y: size.height - 8), b = CGPoint(x: size.width - 6, y: size.height - 8)
            let c = CGPoint(x: size.width / 2, y: -size.height * 0.55)
            var path = Path()
            path.move(to: a)
            path.addQuadCurve(to: b, control: c)
            g.stroke(path, with: .color(Theme.accent.opacity(active ? 0.55 : 0.28)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 9]))
            guard let phase else { return }
            for i in 0..<3 {
                let t = CGFloat((phase * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
                let p = CGPoint(x: (1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * c.x + t * t * b.x,
                                y: (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * c.y + t * t * b.y)
                let r = CGRect(x: p.x - 9, y: p.y - 7, width: 18, height: 14)
                g.fill(Path(roundedRect: r, cornerRadius: 3), with: .linearGradient(Gradient(colors: [Theme.accentLight, Theme.accentDeep]),
                                                                                       startPoint: r.origin, endPoint: CGPoint(x: r.maxX, y: r.maxY)))
            }
        }
    }
}

// MARK: - Hop flight

struct Flight: Identifiable {
    let id = UUID()
    let from: CGPoint
    let to: CGPoint
    let delay: Double
}

private struct ArcPosition: ViewModifier, Animatable {
    var t: CGFloat
    let from: CGPoint
    let to: CGPoint
    var animatableData: CGFloat { get { t } set { t = newValue } }
    func body(content: Content) -> some View {
        let c = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 160)
        let x = (1 - t) * (1 - t) * from.x + 2 * (1 - t) * t * c.x + t * t * to.x
        let y = (1 - t) * (1 - t) * from.y + 2 * (1 - t) * t * c.y + t * t * to.y
        return content
            .rotationEffect(.degrees(Double(t - 0.5) * 50))
            .scaleEffect(1 - 0.25 * t)
            .opacity(t > 0.92 ? Double((1 - t) / 0.08) : 1)
            .position(x: x, y: y)
    }
}

struct FlightView: View {
    let flight: Flight
    @State private var t: CGFloat = 0

    /// A small card that hops across: a drop of tinted glass where Liquid Glass exists.
    @ViewBuilder private var token: some View {
        let icon = Image(systemName: "photo").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
        if #available(macOS 26.0, *) {
            icon.frame(width: 42, height: 34).glassEffect(.regular.tint(Theme.accent.opacity(0.75)), in: .rect(cornerRadius: 11))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.gradient)
                .frame(width: 38, height: 30)
                .overlay(icon)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5))
                .shadow(color: Theme.accent.opacity(0.7), radius: 12)
        }
    }
    var body: some View {
        token
            .modifier(ArcPosition(t: t, from: flight.from, to: flight.to))
            .onAppear { withAnimation(.easeInOut(duration: 0.95).delay(flight.delay)) { t = 1 } }
    }
}
