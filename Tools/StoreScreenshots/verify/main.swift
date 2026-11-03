import Foundation
import ImageIO

// Checks every rendered screenshot against its original: 1242×2688 without alpha, nothing changed
// below the header, the phones in screenshot 5 untouched, and the side margins still empty.
//
//   verify <originals base> <output dir>

let a = CommandLine.arguments
let base = a[1], outDir = a[2]
let folders = try! FileManager.default.contentsOfDirectory(atPath: outDir).filter { !$0.hasPrefix(".") && !$0.hasPrefix("_") }.sorted()
let originals = (1...5).map { Canvas(path: "\(base) \($0).png") }
let cleans = (1...5).map { cleanHeader("\(base) \($0).png").clean }
var problems = 0, files = 0
for f in folders {
    for n in 1...5 {
        let path = "\(outDir)/\(f)/YouCanSing app store \(n).png"
        guard FileManager.default.fileExists(atPath: path) else { print("MISSING", path); problems += 1; continue }
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!, 0, nil) as! [CFString: Any]
        let w = props[kCGImagePropertyPixelWidth] as! Int, h = props[kCGImagePropertyPixelHeight] as! Int
        let alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let o = Canvas(path: path), orig = originals[n - 1], clean = cleans[n - 1]
        var below = 0, phone = 0, margin = 0
        for y in 0..<h { for x in 0..<w {
            let p = o.rgb(x, y)
            if y >= headerRows { if diff(p, orig.rgb(x, y)) != 0 { below += 1 }; continue }
            let c = clean.rgb(x, y)
            if n == 5 && diff(c, BG) > 40 && diff(p, orig.rgb(x, y)) != 0 { phone += 1 }
            if (x < 50 || x >= w - 50) && diff(p, c) != 0 { margin += 1 }
        } }
        files += 1
        if !(w == 1242 && h == 2688 && !alpha && below == 0 && phone == 0 && margin == 0) {
            problems += 1
            print("PROBLEM \(f) #\(n): \(w)x\(h) alpha \(alpha) changed below header \(below), phone pixels \(phone), margin pixels \(margin)")
        }
    }
}
print("checked \(files) files in \(folders.count) folders, problems: \(problems)")
