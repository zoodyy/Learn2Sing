import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// An 8-bit RGB bitmap whose CGContext draws straight into `px`.
final class Canvas {
    let w: Int, h: Int
    let px: UnsafeMutablePointer<UInt8>
    let ctx: CGContext
    init(w: Int, h: Int, fill: (UInt8, UInt8, UInt8)) {
        self.w = w; self.h = h
        px = .allocate(capacity: w * h * 4)
        ctx = CGContext(data: px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for i in 0..<(w * h) { px[i*4] = fill.0; px[i*4+1] = fill.1; px[i*4+2] = fill.2; px[i*4+3] = 255 }
        configure()
    }
    init(path: String) {
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        w = img.width; h = img.height
        px = .allocate(capacity: w * h * 4)
        ctx = CGContext(data: px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setBlendMode(.normal)
        configure()
    }
    deinit { px.deallocate() }
    private func configure() {
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false); ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelPositioning(true); ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false); ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.textMatrix = .identity
    }
    @inline(__always) func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(px[i]), Int(px[i+1]), Int(px[i+2])) }
    @inline(__always) func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) { let i = (y * w + x) * 4; px[i] = c.0; px[i+1] = c.1; px[i+2] = c.2; px[i+3] = 255 }
    /// PNG, RGB without alpha, sRGB, 300 dpi: the same as the originals.
    func save(_ path: String) {
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest), "PNG write failed: \(path)")
    }
    func crop(x: Int, y: Int, w cw: Int, h ch: Int) -> Canvas {
        let c = Canvas(w: cw, h: ch, fill: (0, 0, 0))
        for yy in 0..<ch { for xx in 0..<cw { let (r, g, b) = rgb(x + xx, y + yy); c.set(xx, yy, (UInt8(r), UInt8(g), UInt8(b))) } }
        return c
    }
}

/// The purple behind the headlines.
let BG: (Int, Int, Int) = (205, 73, 253)
@inline(__always) func diff(_ c: (Int, Int, Int), _ d: (Int, Int, Int)) -> Int { abs(c.0 - d.0) + abs(c.1 - d.1) + abs(c.2 - d.2) }

struct Box { var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
    var empty: Bool { x1 < x0 }
    mutating func add(_ x: Int, _ y: Int) { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) }
    mutating func add(_ b: Box) { if !b.empty { add(b.x0, b.y0); add(b.x1, b.y1) } }
    var width: Int { x1 - x0 + 1 }; var height: Int { y1 - y0 + 1 }
}

/// Rows 0..<headerRows hold the headline; everything below is kept from the original untouched.
let headerRows = 1300

/// The background colour of each row: the most common near-purple colour in it. The header
/// is flat (205,73,253) except for a faint 2-px seam across the whole width at rows 549-550.
func rowBackground(_ c: Canvas, maxY: Int) -> [(Int, Int, Int)] {
    (0..<maxY).map { y in
        var counts: [Int: Int] = [:]
        for x in 3..<(c.w - 3) {
            let p = c.rgb(x, y)
            if diff(p, BG) < 40 { counts[(p.0 << 16) | (p.1 << 8) | p.2, default: 0] += 1 }
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return BG }
        return ((best >> 16) & 255, (best >> 8) & 255, best & 255)
    }
}

/// Connected components (8-connected) of pixels that differ from their row's background, in rows
/// [0, maxY). The outer 3 columns are skipped: the originals carry a 2-px strip down each edge
/// from row 549.
func components(_ c: Canvas, maxY: Int, rowBG: [(Int, Int, Int)]) -> (labels: [Int32], boxes: [Box]) {
    var labels = [Int32](repeating: -1, count: c.w * maxY)
    var boxes: [Box] = []
    var stack: [Int] = []
    @inline(__always) func fg(_ x: Int, _ y: Int) -> Bool { diff(c.rgb(x, y), rowBG[y]) != 0 }
    for y in 0..<maxY { for x in 3..<(c.w - 3) {
        let i = y * c.w + x
        if labels[i] != -1 || !fg(x, y) { continue }
        let id = Int32(boxes.count); var box = Box()
        labels[i] = id; stack.append(i)
        while let j = stack.popLast() {
            let jx = j % c.w, jy = j / c.w; box.add(jx, jy)
            for dy in -1...1 { for dx in -1...1 {
                let nx = jx + dx, ny = jy + dy
                if nx < 3 || ny < 0 || nx >= c.w - 3 || ny >= maxY { continue }
                let k = ny * c.w + nx
                if labels[k] == -1 && fg(nx, ny) { labels[k] = id; stack.append(k) }
            } }
        }
        boxes.append(box)
    } }
    return (labels, boxes)
}

/// Text is every component that ends above row 990 (the phones reach further down).
func isText(_ b: Box) -> Bool { b.y1 < 990 && b.y0 > 50 }

/// An original with its headline painted over in each row's background colour, plus where the
/// phones start in each column (only screenshot 5 has phones that high).
struct CleanHeader { let clean: Canvas; let phoneTop: [Int]; let minPhoneClear: Int }
func cleanHeader(_ path: String) -> CleanHeader {
    let img = Canvas(path: path)
    let rowBG = rowBackground(img, maxY: headerRows)
    let (labels, boxes) = components(img, maxY: headerRows, rowBG: rowBG)
    var textIDs = Set<Int32>()
    for (i, b) in boxes.enumerated() where isText(b) { textIDs.insert(Int32(i)) }
    let clean = Canvas(path: path)
    var textBottom = [Int](repeating: -1, count: img.w)
    for y in 0..<headerRows { for x in 0..<img.w where textIDs.contains(labels[y * img.w + x]) {
        if diff(img.rgb(x, y), BG) > 60 { textBottom[x] = max(textBottom[x], y) }
        clean.set(x, y, (UInt8(rowBG[y].0), UInt8(rowBG[y].1), UInt8(rowBG[y].2)))
    } }
    // Whatever is left in the header that isn't background is a phone.
    var phoneTop = [Int](repeating: Int.max, count: img.w)
    for x in 3..<(img.w - 3) { for y in 0..<headerRows where diff(clean.rgb(x, y), rowBG[y]) != 0 { phoneTop[x] = y; break } }
    var minClear = Int.max
    for x in 0..<img.w where textBottom[x] >= 0 && phoneTop[x] != Int.max { minClear = min(minClear, phoneTop[x] - textBottom[x]) }
    return CleanHeader(clean: clean, phoneTop: phoneTop, minPhoneClear: minClear)
}

/// The headline font as chosen in the design tool. It has no Latin letters or digits, so CoreText
/// sets those in Helvetica Bold (and Cyrillic too); only its space, its leading and Arabic are its own.
let primaryFontName = "DamascusBold"

/// Per-language style tweaks: `cjkFont` puts Helvetica Bold and then that font in front of the
/// system fallback; `palt` turns on proportional kana; `boost` scales the starting size.
struct Style { var cjkFont: String? = nil; var palt = false; var boost: CGFloat = 1 }
/// Keyed by language code, or "code#folder" for a row that styles one folder only.
var styles: [String: Style] = [:]

func makeLine(_ text: String, size: CGFloat, lang: String?) -> CTLine {
    var font = CTFontCreateWithName(primaryFontName as CFString, size, nil)
    if let lang, let st = styles[lang], let cjk = st.cjkFont {
        var cjkAttrs: [CFString: Any] = [kCTFontNameAttribute: cjk]
        if st.palt { cjkAttrs[kCTFontFeatureSettingsAttribute] = [[kCTFontOpenTypeFeatureTag: "palt", kCTFontOpenTypeFeatureValue: 1]] }
        let cascade = [CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: "Helvetica-Bold"] as CFDictionary),
                       CTFontDescriptorCreateWithAttributes(cjkAttrs as CFDictionary)]
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: primaryFontName, kCTFontCascadeListAttribute: cascade] as CFDictionary)
        font = CTFontCreateWithFontDescriptor(desc, size, nil)
    }
    var attrs: [NSAttributedString.Key: Any] = [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)]
    if let lang { attrs[kCTLanguageAttributeName as NSAttributedString.Key] = langCode(lang) }
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
}

func langCode(_ key: String) -> String { String(key.split(separator: "#").first!) }

func advance(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

/// Ink box (rows/cols over the diff>60 threshold) of a line drawn with its origin at
/// (x, baselineFromTop), drawn unsquashed.
func inkBox(_ line: CTLine, x: CGFloat, baselineFromTop: CGFloat) -> Box {
    let path = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let pad = 4
    let lw = Int(ceil(path.width)) + 2 * pad + 2, lh = Int(ceil(path.height)) + 2 * pad + 2
    let ox = floor(x + path.minX) - CGFloat(pad)                    // column of local column 0
    let topY = floor(baselineFromTop - path.maxY) - CGFloat(pad)    // row of local row 0
    let c = Canvas(w: lw, h: lh, fill: (UInt8(BG.0), UInt8(BG.1), UInt8(BG.2)))
    c.ctx.textPosition = CGPoint(x: x - ox, y: CGFloat(lh) - (baselineFromTop - topY))
    CTLineDraw(line, c.ctx)
    var b = Box()
    for yy in 0..<lh { for xx in 0..<lw where diff(c.rgb(xx, yy), BG) > 60 { b.add(xx + Int(ox), yy + Int(topY)) } }
    return b
}

func drawLine(_ line: CTLine, on c: Canvas, x: CGFloat, baselineFromTop: CGFloat) {
    c.ctx.textPosition = CGPoint(x: x, y: CGFloat(c.h) - baselineFromTop)
    CTLineDraw(line, c.ctx)
}
