import SwiftUI

/// One month of a group: how many photos and videos were taken in it.
struct MonthBucket: Identifiable {
    let id: Int          // year * 12 + month index
    let start: Date
    let end: Date
    var photos = 0
    var videos = 0
    var total: Int { photos + videos }
}

enum TimelineMath {
    /// Months from the oldest to the newest item, including empty months, so the strip reads as continuous time.
    static func buckets(_ assets: [PhotoAsset]) -> [MonthBucket] {
        let cal = Calendar.current
        var counts: [Int: (Int, Int)] = [:]
        var lo = Int.max, hi = Int.min
        for a in assets {
            guard let d = a.dateCreated else { continue }
            let c = cal.dateComponents([.year, .month], from: d)
            guard let y = c.year, let mo = c.month else { continue }
            let key = y * 12 + (mo - 1)
            lo = min(lo, key); hi = max(hi, key)
            var v = counts[key] ?? (0, 0)
            if a.isVideo { v.1 += 1 } else { v.0 += 1 }
            counts[key] = v
        }
        guard lo <= hi, hi - lo < 1200 else { return [] }
        return (lo...hi).compactMap { key in
            guard let s = cal.date(from: DateComponents(year: key / 12, month: key % 12 + 1, day: 1)),
                  let e = cal.date(byAdding: .month, value: 1, to: s) else { return nil }
            let v = counts[key] ?? (0, 0)
            return MonthBucket(id: key, start: s, end: e.addingTimeInterval(-1), photos: v.0, videos: v.1)
        }
    }
}

/// A strip of monthly bars above a group. Drag across it to keep only that stretch of time.
struct TimelineStrip: View {
    @ObservedObject var m: DeviceManager
    @State private var buckets: [MonthBucket] = []
    @State private var drag: (Int, Int)?

    var body: some View {
        VStack(spacing: 0) {
            if buckets.count >= 2 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(summary).font(.caption.weight(.semibold)).foregroundStyle(m.dateRange == nil ? Theme.faint : Theme.accentLight)
                        Spacer()
                        if m.dateRange != nil {
                            Button("Show all dates") { m.dateRange = nil }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accentLight)
                        }
                    }
                    GeometryReader { geo in
                        let w = geo.size.width / CGFloat(buckets.count)
                        let peak = CGFloat(max(1, buckets.map(\.total).max() ?? 1))
                        let sel = selectedIndices
                        Canvas { g, size in
                            if let sel {
                                let r = CGRect(x: CGFloat(sel.lowerBound) * w, y: 0, width: CGFloat(sel.count) * w, height: size.height)
                                g.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(Theme.accent.opacity(0.18)))
                            }
                            for (i, b) in buckets.enumerated() where b.total > 0 {
                                let x = CGFloat(i) * w + max(0.5, w * 0.15), bw = max(1, w * 0.7)
                                let hp = (size.height - 4) * CGFloat(b.photos) / peak, hv = (size.height - 4) * CGFloat(b.videos) / peak
                                let dim = sel.map { !$0.contains(i) } ?? false
                                g.fill(Path(roundedRect: CGRect(x: x, y: size.height - hp - hv, width: bw, height: hp), cornerRadius: min(2, bw / 2)),
                                       with: .color(Theme.accent.opacity(dim ? 0.25 : 0.9)))
                                g.fill(Path(roundedRect: CGRect(x: x, y: size.height - hv, width: bw, height: hv), cornerRadius: min(2, bw / 2)),
                                       with: .color(Theme.color(for: "smart_videos").opacity(dim ? 0.25 : 0.95)))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let a = index(v.startLocation.x, w), b = index(v.location.x, w)
                                drag = (min(a, b), max(a, b))
                            }
                            .onEnded { _ in
                                if let d = drag { m.dateRange = buckets[d.0].start...buckets[d.1].end }
                                drag = nil
                            })
                        .help("Drag across the months to keep only that stretch of time")
                    }
                    .frame(height: 46)
                    HStack {
                        Text(Self.month.string(from: buckets.first!.start))
                        Spacer()
                        Text(Self.month.string(from: buckets.last!.start))
                    }
                    .font(.caption2).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .transition(.opacity)
            }
        }
        .task(id: m.currentAlbum?.id) {
            let assets = m.currentAlbum?.assets ?? []
            let result = await Task.detached(priority: .userInitiated) { TimelineMath.buckets(assets) }.value
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { buckets = result } }
        }
    }

    private static let month: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f }()

    private func index(_ x: CGFloat, _ w: CGFloat) -> Int { max(0, min(buckets.count - 1, Int(x / max(w, 0.0001)))) }

    private var selectedIndices: ClosedRange<Int>? {
        if let d = drag { return d.0...d.1 }
        guard let r = m.dateRange else { return nil }
        let idx = buckets.indices.filter { buckets[$0].end >= r.lowerBound && buckets[$0].start <= r.upperBound }
        guard let a = idx.first, let b = idx.last else { return nil }
        return a...b
    }

    private var summary: String {
        if let d = drag { return AskParser.rangeText(buckets[d.0].start...buckets[d.1].end) }
        if let r = m.dateRange { return "\(AskParser.rangeText(r)) · \(Fmt.count(m.visibleAssets.count)) items" }
        return "Every month · drag across to pick a stretch of time"
    }
}
