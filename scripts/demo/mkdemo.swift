import AppKit
import CoreText

// usage: mkdemo pdf <out.pdf> <in.txt>   |   mkdemo png <out.png> <in.txt>
// Text files: lines starting with "# " are headings.
let a = CommandLine.arguments
let mode = a[1], out = a[2]
let text = try! String(contentsOfFile: a[3], encoding: .utf8)

func styled(_ text: String, body: NSFont, head: NSFont, color: NSColor) -> NSAttributedString {
    let s = NSMutableAttributedString()
    let p = NSMutableParagraphStyle(); p.paragraphSpacing = body.pointSize * 0.7; p.lineSpacing = body.pointSize * 0.25
    for line in text.components(separatedBy: "\n") {
        let isHead = line.hasPrefix("# ")
        let t = (isHead ? String(line.dropFirst(2)) : line) + "\n"
        s.append(NSAttributedString(string: t, attributes: [.font: isHead ? head : body, .foregroundColor: color, .paragraphStyle: p]))
    }
    return s
}

if mode == "pdf" {
    let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    var box = page
    let ctx = CGContext(URL(fileURLWithPath: out) as CFURL, mediaBox: &box, nil)!
    let s = styled(text, body: NSFont(name: "Times New Roman", size: 12)!, head: NSFont(name: "Times New Roman Bold", size: 14)!, color: .black)
    let fs = CTFramesetterCreateWithAttributedString(s)
    var loc = 0
    while loc < s.length {
        ctx.beginPDFPage(nil)
        let path = CGPath(rect: page.insetBy(dx: 72, dy: 72), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: loc, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
        loc += CTFrameGetVisibleStringRange(frame).length
        ctx.endPDFPage()
    }
    ctx.closePDF()
} else {
    // A lecture-slide screenshot: dark card, light text.
    let w = 1400, h = 520
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(srgbRed: 0.08, green: 0.09, blue: 0.14, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    let s = styled(text, body: .systemFont(ofSize: 24), head: .boldSystemFont(ofSize: 30), color: NSColor(white: 0.92, alpha: 1))
    s.draw(in: NSRect(x: 48, y: 40, width: w - 96, height: h - 80))
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}
