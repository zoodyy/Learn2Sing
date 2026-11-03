import Foundation
import CoreGraphics
import CoreText

// Measures the English headlines of the originals: per line the font size, vertical squash,
// origin, centre line and baseline that reproduce the original pixels, plus each block's ink box.
// The `shots` constants in render/ come from this output. Re-run it if the English design changes.
//
//   measure <originals base>

let english: [[String]] = [
    ["See Your", "Pitch"],
    ["Create", "Your Own", "Exercises"],
    ["Over 100", "Bundled", "Exercises"],
    ["And Share", "Them", "With The", "Community"],
    ["Customise", "Your", "Experience"],
]

struct LineFit { var text: String; var x: CGFloat; var baseline: CGFloat; var adv: CGFloat; var residual: Double; var orig: Box; var size: CGFloat; var k: CGFloat }

let base = CommandLine.arguments[1]
for (idx, lines) in english.enumerated() {
    let path = "\(base) \(idx + 1).png"
    let img = Canvas(path: path)
    let rowBG = rowBackground(img, maxY: headerRows)
    let (labels, boxes) = components(img, maxY: headerRows, rowBG: rowBG)
    let textIDs = boxes.indices.filter { isText(boxes[$0]) }
    // Cluster the text components into lines by vertical overlap.
    var groups: [(Box, [Int])] = []
    for id in textIDs.sorted(by: { boxes[$0].y0 < boxes[$1].y0 }) {
        let b = boxes[id]
        if let k = groups.lastIndex(where: { $0.0.y1 >= b.y0 && b.y1 >= $0.0.y0 }) { groups[k].0.add(b); groups[k].1.append(id) }
        else { groups.append((b, [id])) }
    }
    precondition(groups.count == lines.count, "screenshot \(idx + 1): \(groups.count) lines found, \(lines.count) expected")
    var origBoxes: [Box] = []
    for (gb, ids) in groups {
        let set = Set(ids.map { Int32($0) })
        var b = Box()
        for y in gb.y0...gb.y1 { for x in gb.x0...gb.x1 where set.contains(labels[y * img.w + x]) && diff(img.rgb(x, y), BG) > 60 { b.add(x, y) } }
        origBoxes.append(b)
    }
    let clean = cleanHeader(path).clean
    // Starting size from the ink widths (the squash doesn't change widths).
    var num = 0.0, den = 0.0
    for (j, t) in lines.enumerated() {
        num += Double(origBoxes[j].width); den += Double(inkBox(makeLine(t, size: 100, lang: "en"), x: 100, baselineFromTop: 500).width) / 100
    }
    let S = CGFloat(num / den)
    // Then size, squash, origin and baseline per line, by descent on the pixel difference.
    var fits: [LineFit] = []
    for (j, t) in lines.enumerated() {
        let o = origBoxes[j]
        let b = inkBox(makeLine(t, size: S, lang: "en"), x: 0, baselineFromTop: 0)
        var x = CGFloat(o.x0 - b.x0 + o.x1 - b.x1) / 2, bl = CGFloat(o.y1 - b.y1) * 0.97
        var sz = S, kk: CGFloat = 0.928
        let cx = max(0, o.x0 - 6), cy = max(0, o.y0 - 6), cw = min(img.w - cx, o.width + 12), ch = o.height + 12
        func score(_ x: CGFloat, _ bl: CGFloat, _ size: CGFloat, _ k: CGFloat) -> Double {
            let c = clean.crop(x: cx, y: cy, w: cw, h: ch)
            c.ctx.textMatrix = CGAffineTransform(scaleX: 1, y: k)
            drawLine(makeLine(t, size: size, lang: "en"), on: c, x: x - CGFloat(cx), baselineFromTop: bl - CGFloat(cy))
            var sum = 0
            for yy in 0..<ch { for xx in 0..<cw { sum += diff(c.rgb(xx, yy), img.rgb(cx + xx, cy + yy)) } }
            return Double(sum) / Double(cw * ch)
        }
        var best = score(x, bl, sz, kk)
        for step in [4.0, 2.0, 1.0, 0.5, 0.25, 0.125] as [CGFloat] {
            var improved = true
            while improved {
                improved = false
                for (dx, dy, ds, dk) in [(step, 0, 0, 0), (-step, 0, 0, 0), (0, step, 0, 0), (0, -step, 0, 0), (0, 0, step / 4, 0), (0, 0, -step / 4, 0), (0, 0, 0, step / 200), (0, 0, 0, -step / 200)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                    let s = score(x + dx, bl + dy, sz + ds, kk + dk)
                    if s < best { best = s; x += dx; bl += dy; sz += ds; kk += dk; improved = true }
                }
            }
        }
        fits.append(LineFit(text: t, x: x, baseline: bl, adv: advance(makeLine(t, size: sz, lang: "en")), residual: best, orig: o, size: sz, k: kk))
    }
    print("SCREENSHOT \(idx + 1)")
    for (j, f) in fits.enumerated() {
        var s = String(format: "  %-11@ size %7.2f squash %.4f  centre %7.2f  baseline %7.2f  ink y %d-%d x %d-%d  residual %.2f",
                       f.text as NSString, f.size, f.k, f.x + f.adv / 2, f.baseline, f.orig.y0, f.orig.y1, f.orig.x0, f.orig.x1, f.residual)
        if j > 0 { s += String(format: "  pitch %.4f × squashed size", (f.baseline - fits[j - 1].baseline) / (f.size * f.k)) }
        print(s)
    }
    print(String(format: "  ink box centre y %.1f", Double(fits.first!.orig.y0 + fits.last!.orig.y1) / 2))
}
