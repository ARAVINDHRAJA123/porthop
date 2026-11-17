import SwiftUI
import AppKit

// MARK: - Theme

/// PortHop's look, taken from the app icon: deep navy water, electric-blue motion and warm cream folders.
enum Theme {
    /// A colour with one value for light mode and one for dark, switching live with the system.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    // Apple's grouped look: cards on a slightly darker page, in both modes.
    static let bg = dynamic(rgb(0xF2F2F7), rgb(0x0B0B0D))
    static let bgDeep = dynamic(rgb(0xE9E9EF), rgb(0x050506))
    static let surface = dynamic(rgb(0xFFFFFF), rgb(0x1C1C1E))
    static let raised = dynamic(rgb(0xF4F4F7), rgb(0x2C2C2E))
    static let line = Color(nsColor: .separatorColor)
    static let text = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color(nsColor: .systemBlue)
    static let accentLight = dynamic(rgb(0x3D8BFF), rgb(0x7DB8FF))
    static let accentDeep = dynamic(rgb(0x0058D0), rgb(0x1F66EB))
    static let cream = dynamic(rgb(0xF3EDE2), rgb(0x2A2722))
    static let creamDeep = dynamic(rgb(0xDCD1BF), rgb(0x3A352D))
    static let ink = Color(nsColor: .labelColor)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    static let gradient = LinearGradient(colors: [accentLight, accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func color(for id: String) -> Color {
        switch id {
        case "smart_hidden": return Color(red: 0.45, green: 0.42, blue: 1.0)
        case "smart_all": return accent
        case "smart_favorites": return Color(red: 1.0, green: 0.42, blue: 0.58)
        case "smart_videos": return Color(red: 0.62, green: 0.45, blue: 1.0)
        case "smart_live": return Color(red: 1.0, green: 0.66, blue: 0.26)
        case "smart_screenshots": return Color(red: 0.22, green: 0.78, blue: 0.84)
        case "smart_selfies": return Color(red: 0.30, green: 0.80, blue: 0.52)
        case "smart_trashed": return Color(red: 0.50, green: 0.55, blue: 0.64)
        case "nav_device": return accent
        case "nav_files": return Color(red: 0.50, green: 0.58, blue: 0.72)
        default: return Color(red: 0.36, green: 0.66, blue: 1.0)
        }
    }
}

// MARK: - Building blocks

/// An icon in Apple's own style: a colour tile lit from above with a glassy rim, carrying an SF Symbol.
/// On macOS 26 and later the symbol uses SF Symbols 7's gradient rendering, as Apple's apps do.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            shape.fill(color)
            // Light from above, shade below.
            shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.30), location: 0), .init(color: .white.opacity(0.04), location: 0.5),
                                              .init(color: .black.opacity(0.20), location: 1)], startPoint: .top, endPoint: .bottom))
            // The upper-left glow where glass catches the light.
            shape.fill(RadialGradient(colors: [.white.opacity(0.26), .clear], center: UnitPoint(x: 0.22, y: 0), startRadius: 0, endRadius: size * 0.75))
            TileSymbol(symbol: symbol, size: size)
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.05), .white.opacity(0.22)], startPoint: .top, endPoint: .bottom),
                                    lineWidth: max(0.6, size * 0.03)))
        .shadow(color: color.opacity(0.35), radius: size * 0.15, y: size * 0.07)
    }
}

private struct TileSymbol: View {
    let symbol: String
    let size: CGFloat
    var body: some View {
        let glyph = Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.22), radius: size * 0.025, y: size * 0.025)
        if #available(macOS 26.0, *) {
            glyph.symbolColorRenderingMode(.gradient)
        } else {
            glyph
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 16).padding(.vertical, 8)
        return Group {
            if #available(macOS 26.0, *) {
                label.background(Capsule().fill(Theme.accent)).glassEffect(.regular.interactive(), in: .capsule)
            } else {
                label
                    .background(Capsule().fill(Theme.gradient))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: Theme.accent.opacity(enabled ? 0.45 : 0), radius: 10, y: 3)
            }
        }
        .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 14).padding(.vertical, 8)
        return Group {
            if #available(macOS 26.0, *) {
                label.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                label
                    .background(Capsule().fill(Theme.raised.opacity(configuration.isPressed ? 1 : 0.85)))
                    .overlay(Capsule().strokeBorder(Theme.line))
            }
        }
        .opacity(enabled ? 1 : 0.4)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Liquid Glass

/// On macOS 26 and later, floating surfaces and controls are Liquid Glass; earlier versions keep the solid navy look.
var liquidGlass: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
}

struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive: Bool
    var fallback: Color
    var stroke: Color

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(shape.fill(fallback))
                .overlay(shape.stroke(stroke, lineWidth: 1))
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        return interactive ? g.interactive() : g
    }
}

extension View {
    /// A floating surface: Liquid Glass where available, otherwise a solid fill with a hairline edge.
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false,
                                fallback: Color = Theme.surface, stroke: Color = Theme.line) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, fallback: fallback, stroke: stroke))
    }

    /// A content surface (cards, tiles): a solid system-style fill in both modes. Glass is kept for what floats above content.
    func contentSurface<S: Shape>(_ shape: S, highlighted: Bool = false) -> some View {
        background(shape.fill(highlighted ? Theme.raised : Theme.surface))
            .overlay(shape.stroke(Theme.line.opacity(0.6), lineWidth: 0.5))
    }

    /// Toolbar items already sit on the system's glass on macOS 26; earlier versions draw their own capsule.
    @ViewBuilder func toolbarChrome(stroke: Color = Theme.line) -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            self.background(Capsule().fill(Theme.raised)).overlay(Capsule().strokeBorder(stroke))
        }
    }

    /// Renders nearby glass shapes together, so they sample the same backdrop and can blend.
    @ViewBuilder func glassGroup(spacing: CGFloat? = nil) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// A small label above a group of things.
struct ShoreLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint).textCase(nil)
    }
}

/// The page behind every screen: Apple's quiet grouped background, so the glass controls read clearly on it.
struct ShoreBackground: View {
    var body: some View {
        Theme.bg.ignoresSafeArea()
    }
}
