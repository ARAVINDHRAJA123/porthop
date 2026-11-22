import SwiftUI
import AppKit

// The animated screen while a library is read.

// MARK: - Loading

/// The screen while a library is read: the phone and the Mac with photos hopping between them, and the steps so far.
struct LinkLoader: View {
    let device: String
    let symbol: String
    let organising: Bool

    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 0) {
                IconTile(symbol: symbol, color: Theme.accent, size: 76)
                HopLane().frame(width: 230, height: 90)
                IconTile(symbol: "laptopcomputer", color: Color(nsColor: .systemIndigo), size: 76)
            }
            VStack(spacing: 6) {
                Text(organising ? "Almost there" : "Reading \(device)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                Text("Large libraries can take a minute. Keep \(device) unlocked — nothing on it is changed.")
                    .font(.callout).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                row(.done, "Connected over USB")
                row(organising ? .done : .active, "Reading the photo library")
                row(organising ? .active : .waiting, "Sorting it into albums")
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(width: 340, alignment: .leading)
            .contentSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: organising)
    }

    private enum StepState { case done, active, waiting }

    private func row(_ state: StepState, _ text: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.success)
                case .active: ProgressView().controlSize(.small)
                case .waiting: Circle().strokeBorder(Theme.faint, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).frame(width: 17, height: 17)
                }
            }
            .frame(width: 20)
            Text(text).font(.system(size: 14, weight: state == .active ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? Theme.faint : Theme.text)
        }
    }
}

/// Little photos hopping along an arc from the phone to the Mac, over and over.
private struct HopLane: View {
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let w = size.width, base = size.height * 0.62, lift = size.height * 0.5
                var dots = Path()
                for i in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let x = 14 + (w - 28) * i, y = base - lift * sin(.pi * i)
                    dots.addEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                }
                ctx.fill(dots, with: .color(Theme.faint))
                let t = tl.date.timeIntervalSinceReferenceDate
                let colours: [Color] = [Color(nsColor: .systemPink), Color(nsColor: .systemOrange), Color(nsColor: .systemTeal)]
                for k in 0..<3 {
                    let p = (t / 1.8 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let x = 14 + (w - 28) * p, y = base - lift * sin(.pi * p)
                    let fade = min(1, min(p, 1 - p) * 6)
                    var card = ctx
                    card.opacity = fade
                    card.translateBy(x: x, y: y)
                    card.rotate(by: .degrees((p - 0.5) * 40))
                    let r = CGRect(x: -11, y: -9, width: 22, height: 18)
                    card.fill(Path(roundedRect: r, cornerRadius: 4), with: .linearGradient(Gradient(colors: [colours[k].opacity(0.95), colours[k].opacity(0.65)]),
                                                                                       startPoint: CGPoint(x: 0, y: -9), endPoint: CGPoint(x: 0, y: 9)))
                    card.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                }
            }
        }
    }
}
