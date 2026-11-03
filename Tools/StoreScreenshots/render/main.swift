import Foundation
import CoreGraphics
import CoreText

// Renders the translated App Store screenshots: erases the English headline of each original
// and sets the translation in its place, at the original's size unless it doesn't fit.
//
//   render <originals base> <output dir> <headlines.tsv> [folder or language,...]
//
// <originals base> is the path without " N.png", e.g. ~/Downloads/YouCanSing app store

// MARK: - The five originals, as measured by measure/ (size, centre line, ink-box centre).

struct Shot { let n: Int; let S0: CGFloat; let cx: CGFloat; let anchorY: CGFloat; let topMin: CGFloat; let bottomMax: CGFloat }
let shots = [
    Shot(n: 1, S0: 252.40, cx: 625.90, anchorY: 546.0, topMin: 150, bottomMax: 945),
    Shot(n: 2, S0: 223.37, cx: 629.05, anchorY: 546.5, topMin: 150, bottomMax: 945),
    Shot(n: 3, S0: 236.56, cx: 623.98, anchorY: 546.5, topMin: 150, bottomMax: 945),
    Shot(n: 4, S0: 205.27, cx: 618.17, anchorY: 546.0, topMin: 150, bottomMax: 945),
    Shot(n: 5, S0: 205.24, cx: 615.72, anchorY: 424.5, topMin: 115, bottomMax: 1300),
]
/// The originals' text is squashed vertically to 92.8 % (a horizontally stretched text layer).
let K: CGFloat = 0.928
let squash = CGAffineTransform(scaleX: 1, y: K)
let sideMargin: CGFloat = 60      // originals: widest line ("Community") leaves 62 px
/// Latin gap between cap-height lines at the tool's 1.0 line height, used to space CJK lines alike.
let capGap: CGFloat = 1.0 - 0.7197

// MARK: - Inputs

let args = CommandLine.arguments
let originalsBase = args[1]
let outDir = args[2]
let tablePath = args[3]              // TSV: folder \t lang \t text1 \t ... \t text5 [\t style]   ("\n" = line break)
let only = args.count > 4 ? Set(args[4].split(separator: ",").map(String.init)) : nil

// MARK: - Line measurement

struct Ink { var top: [Int]; var bottom: [Int]; var col0: Int; var minRow: Int; var maxRow: Int; var minCol: Int; var maxCol: Int }
/// Rasterises a line at origin x / integer baseline 0 and returns per-column ink rows relative to the baseline.
func measure(_ line: CTLine, x: CGFloat, size: CGFloat) -> Ink {
    let adv = advance(line)
    let pad = Int(size * 0.5) + 8
    let col0 = Int(floor(x)) - pad
    let w = Int(ceil(adv)) + 2 * pad + 2
    let above = Int(size * 1.4) + 8, below = Int(size * 0.8) + 8
    let c = Canvas(w: w, h: above + below, fill: (UInt8(BG.0), UInt8(BG.1), UInt8(BG.2)))
    c.ctx.textMatrix = squash
    c.ctx.textPosition = CGPoint(x: x - CGFloat(col0), y: CGFloat(below))
    CTLineDraw(line, c.ctx)
    var top = [Int](repeating: Int.max, count: w), bottom = [Int](repeating: Int.min, count: w)
    var minRow = Int.max, maxRow = Int.min, minCol = Int.max, maxCol = Int.min
    for yy in 0..<c.h { for xx in 0..<w where diff(c.rgb(xx, yy), BG) > 60 {
        let r = yy - above   // rows relative to the baseline (negative = above)
        top[xx] = min(top[xx], r); bottom[xx] = max(bottom[xx], r)
        minRow = min(minRow, r); maxRow = max(maxRow, r); minCol = min(minCol, xx + col0); maxCol = max(maxCol, xx + col0)
    } }
    return Ink(top: top, bottom: bottom, col0: col0, minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol)
}

func isCJK(_ lang: String) -> Bool { ["ja", "zh-Hans", "zh-Hant", "ko"].contains(langCode(lang)) }

/// Ink height of a full ideograph / Hangul block, for spacing CJK lines like the Latin ones.
func cjkBodyHeight(_ lang: String, size: CGFloat) -> CGFloat {
    let ink = measure(makeLine(langCode(lang) == "ko" ? "한" : "国", size: size, lang: lang), x: 0, size: size)
    return CGFloat(ink.maxRow - ink.minRow + 1)
}

/// Line metrics the way the originals' text system stacks lines: the ascent includes the largest
/// leading of any run (so a line holding a Damascus space sits 0.0215 em lower), and the descent
/// ignores runs that are only whitespace.
func lineMetrics(_ line: CTLine, _ text: String) -> (ascent: CGFloat, descent: CGFloat) {
    var asc: CGFloat = 0, lead: CGFloat = 0, desc: CGFloat = 0
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        asc = max(asc, CTFontGetAscent(font)); lead = max(lead, CTFontGetLeading(font))
        let r = CTRunGetStringRange(run)
        let sub = (text as NSString).substring(with: NSRange(location: r.location, length: r.length))
        if !sub.allSatisfy(\.isWhitespace) { desc = max(desc, CTFontGetDescent(font)) }
    }
    return ((asc + lead) * K, desc * K)
}

struct Layout { var size: CGFloat; var xs: [CGFloat]; var baselines: [CGFloat]; var lines: [CTLine]; var inks: [Ink]; var top: Int; var bottom: Int; var minCol: Int; var maxCol: Int }

func layout(_ texts: [String], lang: String, size S: CGFloat, shot: Shot, shiftUp: CGFloat = 0) -> Layout {
    let lines = texts.map { makeLine($0, size: S, lang: lang) }
    let xs = lines.map { shot.cx - advance($0) / 2 }
    let inks = zip(lines, xs).map { measure($0, x: $1, size: S) }
    let metrics = zip(lines, texts).map { lineMetrics($0, $1) }
    let cjkPitch = isCJK(lang) ? cjkBodyHeight(lang, size: S) + capGap * S * K : nil
    let minClear = Int((0.05 * S * K).rounded())
    var baselines: [CGFloat] = [0]
    for i in 1..<max(1, lines.count) {
        var b = baselines[i - 1] + (cjkPitch ?? (metrics[i - 1].descent + metrics[i].ascent))
        // Push the line down if any column of it comes closer than minClear to the line above.
        let a = inks[i - 1], c = inks[i]
        var worst = Int.max
        for gx in max(a.col0, c.col0)..<min(a.col0 + a.top.count, c.col0 + c.top.count) {
            let ab = a.bottom[gx - a.col0], ct = c.top[gx - c.col0]
            if ab == Int.min || ct == Int.max { continue }
            worst = min(worst, Int(b.rounded()) - Int(baselines[i - 1].rounded()) + ct - ab)
        }
        if worst < minClear { b += CGFloat(minClear - worst) }
        baselines.append(b)
    }
    // Centre the block's ink box on the original's ink-box centre.
    let top0 = CGFloat(inks[0].minRow) + baselines[0]
    let bottom0 = CGFloat(inks.last!.maxRow) + baselines.last!
    let shift = shot.anchorY - (top0 + bottom0) / 2 - shiftUp
    baselines = baselines.map { $0 + shift }
    let top = Int(baselines[0].rounded()) + inks[0].minRow, bottom = Int(baselines.last!.rounded()) + inks.last!.maxRow
    return Layout(size: S, xs: xs, baselines: baselines, lines: lines, inks: inks, top: top, bottom: bottom,
                  minCol: inks.map(\.minCol).min()!, maxCol: inks.map(\.maxCol).max()!)
}

/// Smallest clearance between the text and the phones (screenshot 5), column by column.
func phoneClearance(_ L: Layout, _ p: CleanHeader) -> Int {
    var worst = Int.max
    for (i, ink) in L.inks.enumerated() {
        for (k, b) in ink.bottom.enumerated() where b != Int.min {
            let gx = ink.col0 + k
            guard gx >= 0, gx < p.phoneTop.count, p.phoneTop[gx] != Int.max else { continue }
            worst = min(worst, p.phoneTop[gx] - (Int(L.baselines[i].rounded()) + b))
        }
    }
    return worst
}

/// The largest size up to the original's that keeps the side margins, the vertical envelope and
/// (screenshot 5) the clearance to the phones.
func fit(_ texts: [String], lang: String, shot: Shot, header: CleanHeader) -> Layout {
    let needClear = shot.n == 5 ? max(header.minPhoneClear, 16) : 0
    var S = shot.S0 * (styles[lang]?.boost ?? 1)
    for _ in 0..<80 {
        var L = layout(texts, lang: lang, size: S, shot: shot)
        var scale: CGFloat = 1
        let left = CGFloat(L.minCol), right = CGFloat(L.maxCol)
        if left < sideMargin { scale = min(scale, (shot.cx - sideMargin) / (shot.cx - left)) }
        if right > 1242 - sideMargin { scale = min(scale, (1242 - sideMargin - shot.cx) / (right - shot.cx)) }
        // Phones: move the block up as far as the top margin allows before shrinking.
        if shot.n == 5 {
            var clear = phoneClearance(L, header)
            if clear < needClear {
                let up = min(CGFloat(L.top) - shot.topMin, CGFloat(needClear - clear))
                if up > 0 { L = layout(texts, lang: lang, size: S, shot: shot, shiftUp: up); clear = phoneClearance(L, header) }
                if clear < needClear { scale = min(scale, 0.99) }
            }
        }
        let h = CGFloat(L.bottom - L.top)
        let allowed = 2 * min(shot.anchorY - shot.topMin, shot.bottomMax - shot.anchorY)
        if shot.n != 5 && h > allowed { scale = min(scale, allowed / h) }
        if shot.n == 5 && CGFloat(L.top) < shot.topMin { scale = min(scale, 0.99) }
        if scale >= 1 { return L }
        S = (S * min(scale, 0.997) * 100).rounded(.down) / 100
    }
    fatalError("could not fit \(texts)")
}

// MARK: - Run

let headers = shots.map { cleanHeader("\(originalsBase) \($0.n).png") }

let table = try! String(contentsOfFile: tablePath, encoding: .utf8)
for row in table.split(separator: "\n") where !row.hasPrefix("#") && !row.trimmingCharacters(in: .whitespaces).isEmpty {
    let f = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    precondition(f.count == 7 || f.count == 8, "bad row: \(row)")
    let folder = f[0], lang = f[1]
    // An optional 8th column styles the row, e.g. "cjk=HiraginoSans-W8;palt;boost=1.3". It is
    // keyed by folder too, so variants of one language can be rendered side by side.
    let key = f.count == 8 ? "\(lang)#\(folder)" : lang
    if f.count == 8 {
        var st = Style()
        for opt in f[7].split(separator: ";") {
            let kv = opt.split(separator: "=", maxSplits: 1).map(String.init)
            switch kv[0] {
            case "cjk": st.cjkFont = kv[1]
            case "palt": st.palt = true
            case "boost": st.boost = CGFloat(Double(kv[1])!)
            default: fatalError("unknown style option \(opt)")
            }
        }
        styles[key] = st
    }
    if let only, !only.contains(folder) && !only.contains(lang) { continue }
    try! FileManager.default.createDirectory(atPath: "\(outDir)/\(folder)", withIntermediateDirectories: true)
    var report = String(format: "%-22@", folder as NSString)
    for (k, shot) in shots.enumerated() {
        let texts = f[2 + k].components(separatedBy: "\\n")
        let L = fit(texts, lang: key, shot: shot, header: headers[k])
        // The cleaned header, then everything below it straight from the original.
        let out = Canvas(path: "\(originalsBase) \(shot.n).png")
        for i in 0..<(out.w * headerRows * 4) { out.px[i] = headers[k].clean.px[i] }
        out.ctx.textMatrix = squash
        for (i, l) in L.lines.enumerated() {
            out.ctx.textPosition = CGPoint(x: L.xs[i], y: CGFloat(out.h) - L.baselines[i])
            CTLineDraw(l, out.ctx)
        }
        out.save("\(outDir)/\(folder)/YouCanSing app store \(shot.n).png")
        report += String(format: "  %d:%3.0f%% %dl", shot.n, L.size / shot.S0 * 100, L.lines.count)
    }
    print(report)
}
