import AppKit

// Turns a square icon drawing on a white background into a 1024 px master with a transparent
// background, sized to Apple's macOS icon grid (artwork 824 px wide, centred).
// Usage: swift prepare_icon.swift <input.png> <output.png>
let input = NSImage(contentsOfFile: CommandLine.arguments[1])!
var rect = NSRect(origin: .zero, size: input.size)
let cg = input.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let bctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
bctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// 1. Flood-fill the near-white background from the four corners.
func whiteish(_ i: Int) -> Bool { px[i] > 228 && px[i + 1] > 228 && px[i + 2] > 228 }
var bg = [Bool](repeating: false, count: w * h)
var stack = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
while let (x, y) = stack.popLast() {
    guard x >= 0, y >= 0, x < w, y < h, !bg[y * w + x], whiteish((y * w + x) * 4) else { continue }
    bg[y * w + x] = true
    stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
}
// 2. Background becomes transparent. Pixels on the edge are a blend of white and the icon,
//    so recover their transparency from how close they are to white.
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let p = y * w + x, i = p * 4
        if bg[p] { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0; continue }
        var nearBg = false
        for dy in -2...2 { for dx in -2...2 {
            let nx = x + dx, ny = y + dy
            if nx >= 0, ny >= 0, nx < w, ny < h, bg[ny * w + nx] { nearBg = true }
        } }
        if nearBg {
            let darkest = Double(min(px[i], px[i + 1], px[i + 2]))
            let a = max(0, min(1, (255 - darkest) / (255 - 30)))
            if a < 0.02 { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0; continue }
            for c in 0..<3 {
                let v = (Double(px[i + c]) - 255 * (1 - a)) / a
                px[i + c] = UInt8(max(0, min(255, v * a)))   // stored premultiplied
            }
            px[i + 3] = UInt8(a * 255)
        }
        if px[i + 3] > 0 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    }
}
let cut = bctx.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

// 3. Place it on a 1024 canvas, 824 px across, centred, with a soft shadow in the margin.
let S = 1024, body = 824.0
let scale = body / Double(max(cut.width, cut.height))
let dw = Double(cut.width) * scale, dh = Double(cut.height) * scale
let out = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
out.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(srgbRed: 0, green: 0, blue: 0.05, alpha: 0.35))
out.draw(cut, in: CGRect(x: (Double(S) - dw) / 2, y: (Double(S) - dh) / 2 + 6, width: dw, height: dh))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("source \(w)x\(h), artwork \(cut.width)x\(cut.height), placed at \(Int(dw))x\(Int(dh)) on \(S)x\(S)")
