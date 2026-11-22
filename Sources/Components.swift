import SwiftUI
import AppKit

// Small shared pieces: storage bar, glowing progress bar, pill.

// MARK: - Shared pieces

struct StorageBar: View {
    let fraction: Double
    @State private var shown = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Theme.gradient)
                    .frame(width: max(4, geo.size.width * (shown ? min(1, max(0, fraction)) : 0)))
            }
        }
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.15)) { shown = true } }
    }
}

struct GlowProgressBar: View {
    let fraction: Double
    @State private var sweep = false
    var body: some View {
        GeometryReader { geo in
            let w = max(8, geo.size.width * min(1, max(0, fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Theme.gradient).frame(width: w)
                    .overlay(alignment: .leading) {
                        LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 70).offset(x: sweep ? w : -70)
                    }
                    .clipShape(Capsule())
                    .animation(.easeOut(duration: 0.35), value: fraction)
            }
        }
        .frame(height: 6)
        .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { sweep = true } }
    }
}

struct Pill: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .foregroundStyle(.secondary)
    }
}
