import AppKit
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import Vision

/// What the evidence pane shows for one result: proof of *why* it matched.
///
/// - PDF: the region of the page around the hit, rendered, with every match
///   on that page highlighted. ⌥↓ / ⌥↑ move between hits across pages.
/// - Image: the picture, with boxes where OCR found your words.
/// - Code / text: the lines around the hit, numbered, hits highlighted.
/// - Office / rich text, meaning-only: the matching passage.
/// - Folder: its most recently changed items.
/// - Anything else: a Quick Look thumbnail.
struct Evidence {
    enum Body {
        case render(NSImage)                         // PDF crop, already highlighted
        case image(NSImage, boxes: [CGRect])         // boxes: Vision-normalized (origin bottom-left)
        case text(NSAttributedString, numbered: Bool)
        case folder([(name: String, path: String)], total: Int)
        case thumbnail(NSImage)
        case none(String)
    }
    var path: String
    var meta: String
    var body: Body
    var hitIndex = 0
    var hitCount = 0
    var location: String? = nil   // "page 3 of 14", "line 120"
}

final class EvidenceLoader {
    private let queue = DispatchQueue(label: "seek.evidence", qos: .userInitiated)
    private let ocrQueue = DispatchQueue(label: "seek.evidence.ocr", qos: .userInitiated)
    private let gen = Generation()
    private var ocrCache: [String: [VNRecognizedTextObservation]] = [:]
    private let cacheLock = NSLock()
    let store: ContentStore?

    init(store: ContentStore?) { self.store = store }

    /// Loads evidence for `r`. `update` may be called more than once (an image
    /// appears first, its OCR boxes arrive after); calls from a superseded
    /// request are dropped.
    func load(_ r: SearchResult, query: String, hit: Int, size: CGSize, update: @escaping (Evidence) -> Void) {
        let my = gen.bump()
        let deliver: (Evidence) -> Void = { [gen] e in
            DispatchQueue.main.async { if gen.current == my { update(e) } }
        }
        queue.async { [self] in
            guard gen.current == my else { return }
            let words = Self.terms(query)
            let meta = Self.meta(r.path, isDir: r.isDir)
            if r.isDir { deliver(folder(r.path, meta)); return }
            let ext = (r.path as NSString).pathExtension.lowercased()
            let kind = Extractor.kind(for: r.path)

            if ext == "pdf", let e = pdf(r.path, meta: meta, query: query, words: words, hit: hit, size: size) {
                deliver(e); return
            }
            if kind == .image, let img = NSImage(contentsOfFile: r.path) {
                var e = Evidence(path: r.path, meta: meta, body: .image(img, boxes: []))
                deliver(e)
                guard r.sources.contains(.content), !words.isEmpty else { return }
                ocrQueue.async { [self] in
                    guard gen.current == my else { return }
                    let boxes = ocrBoxes(r.path, img, words)
                    e.body = .image(img, boxes: boxes)
                    e.hitCount = boxes.count
                    deliver(e)
                }
                return
            }
            if let text = bodyText(r.path, kind: kind), !text.isEmpty {
                let code = kind == .text
                deliver(excerpt(r, text: text, meta: meta, words: words, hit: hit, numbered: code))
                return
            }
            deliver(thumbnail(r.path, meta: meta, size: size))
        }
    }

    // MARK: - PDF

    private func pdf(_ path: String, meta: String, query: String, words: [String], hit: Int, size: CGSize) -> Evidence? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), doc.pageCount > 0 else { return nil }
        var sels: [PDFSelection] = []
        if !words.isEmpty && doc.pageCount <= 400 {
            let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            sels = doc.findString(query.trimmingCharacters(in: .whitespaces), withOptions: opts)
            if sels.isEmpty, let longest = words.max(by: { $0.count < $1.count }) {
                sels = doc.findString(longest, withOptions: opts)
            }
        }
        sels = Array(sels.prefix(500))
        let idx = sels.isEmpty ? 0 : ((hit % sels.count) + sels.count) % sels.count
        let page = sels.isEmpty ? doc.page(at: 0)! : (sels[idx].pages.first ?? doc.page(at: 0)!)
        let pageNo = doc.index(for: page) + 1
        let onPage = sels.filter { $0.pages.contains(page) }.map { $0.bounds(for: page) }
        let focus = sels.isEmpty ? nil : sels[idx].bounds(for: page)
        guard let img = Self.renderCrop(page, focus: focus, highlights: onPage, current: focus, size: size) else { return nil }
        var e = Evidence(path: path, meta: meta, body: .render(img))
        e.hitIndex = idx
        e.hitCount = sels.count
        e.location = "page \(pageNo) of \(doc.pageCount)"
        return e
    }

    /// Renders the part of the page around `focus` at a readable scale: about
    /// 400 pt of page width across the pane, instead of a whole page shrunk to
    /// illegibility. Highlights are drawn into the bitmap so they stay aligned.
    static func renderCrop(_ page: PDFPage, focus: CGRect?, highlights: [CGRect], current: CGRect?, size: CGSize) -> NSImage? {
        let box = page.bounds(for: .cropBox)
        // Crop to the page's text column (plus a little air), not a fixed window:
        // margins go, but a line of text is never cut in half.
        var column = box
        if let text = page.selection(for: box)?.bounds(for: page), text.width > 40 {
            column = text.insetBy(dx: -14, dy: 0).intersection(box)
        }
        let cropW = min(column.width, box.width)
        let scale = size.width / cropW
        let cropH = min(box.height, size.height / scale)
        var origin = CGPoint(x: column.minX, y: box.maxY - cropH)                    // top of page
        if let f = focus {
            origin.y = min(max(box.minY, f.midY - cropH * 0.55), box.maxY - cropH)   // hit a bit above center
        }
        let crop = CGRect(origin: origin, size: CGSize(width: cropW, height: cropH))
        let px = 2.0
        let w = Int(size.width * px), h = Int(cropH * scale * px)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale * px, y: scale * px)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        page.draw(with: .cropBox, to: ctx)
        // Highlights in fixed light-mode accent: the page itself is always white paper.
        for r in highlights {
            let isCurrent = current.map { $0 == r } ?? false
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.42, blue: 0.24, alpha: isCurrent ? 0.42 : 0.22))
            ctx.fill(r.insetBy(dx: -1.5, dy: -1))
            if isCurrent {
                ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.33, blue: 0.16, alpha: 1))
                ctx.fill(CGRect(x: r.minX - 1.5, y: r.minY - 2.5, width: r.width + 3, height: 1.5))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: size.width, height: cropH * scale))
    }

    // MARK: - Images

    /// Where in the image your words are. Recognition is cached per file, so
    /// re-selecting a screenshot or typing more of the query is instant.
    private func ocrBoxes(_ path: String, _ img: NSImage, _ words: [String]) -> [CGRect] {
        var obs = cacheLock.withLock { ocrCache[path] }
        if obs == nil {
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            obs = req.results ?? []
            cacheLock.withLock { if ocrCache.count > 64 { ocrCache.removeAll() }; ocrCache[path] = obs }
        }
        var boxes: [CGRect] = []
        for o in obs ?? [] {
            guard let cand = o.topCandidates(1).first else { continue }
            let s = cand.string
            for w in words {
                var from = s.startIndex
                while let r = s.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: from..<s.endIndex) {
                    if let b = try? cand.boundingBox(for: r)?.boundingBox { boxes.append(b) }
                    from = r.upperBound
                }
            }
        }
        return Self.mergeLineBoxes(boxes)
    }

    /// Word boxes that sit on the same line and nearly touch become one box, so
    /// "page table base register" reads as a single highlight, not four.
    static func mergeLineBoxes(_ boxes: [CGRect]) -> [CGRect] {
        let sorted = boxes.sorted { abs($0.midY - $1.midY) > min($0.height, $1.height) / 2 ? $0.midY > $1.midY : $0.minX < $1.minX }
        var out: [CGRect] = []
        for b in sorted {
            if let last = out.last,
               abs(last.midY - b.midY) < min(last.height, b.height) * 0.5,
               b.minX - last.maxX < max(last.height, b.height) * 0.9, b.minX >= last.minX - 0.001 {
                out[out.count - 1] = last.union(b)
            } else {
                out.append(b)
            }
        }
        return out
    }

    // MARK: - Text

    private func bodyText(_ path: String, kind: ContentKind?) -> String? {
        if kind == .text, let d = FileManager.default.contents(atPath: path), !d.prefix(8192).contains(0) {
            return String(decoding: d.prefix(512 * 1024), as: UTF8.self)
        }
        return store?.body(path: path)
    }

    private func excerpt(_ r: SearchResult, text: String, meta: String, words: [String], hit: Int, numbered: Bool) -> Evidence {
        let ns = text as NSString
        let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [NSRange] = []
        for w in words where w.count >= 2 || words.count == 1 {
            var search = NSRange(location: 0, length: ns.length)
            while hits.count < 2000 {
                let f = ns.range(of: w, options: opts, range: search)
                if f.location == NSNotFound { break }
                hits.append(f)
                search = NSRange(location: f.upperBound, length: ns.length - f.upperBound)
            }
        }
        hits.sort { $0.location < $1.location }
        // Prefer the exact phrase: those are the hits you step through. Otherwise
        // start at the line holding the most distinct query words.
        let phrase = words.joined(separator: " ")
        if words.count > 1 {
            var phraseHits: [NSRange] = []
            var search = NSRange(location: 0, length: ns.length)
            while phraseHits.count < 2000 {
                let f = ns.range(of: phrase, options: opts, range: search)
                if f.location == NSNotFound { break }
                phraseHits.append(f)
                search = NSRange(location: f.upperBound, length: ns.length - f.upperBound)
            }
            if !phraseHits.isEmpty { hits = phraseHits }
            else if let best = Self.densestHit(hits, in: ns, words: words) {
                hits.removeAll { $0 == best }; hits.insert(best, at: 0)
            }
        }
        let idx = hits.isEmpty ? 0 : ((hit % hits.count) + hits.count) % hits.count
        let anchor = hits.isEmpty ? 0 : hits[idx].location

        var e = Evidence(path: r.path, meta: meta, body: .none(""))
        e.hitIndex = idx
        e.hitCount = hits.count
        if numbered {
            // Lines around the hit, with numbers. Only the window is laid out.
            var lineStarts = [0]
            ns.enumerateSubstrings(in: NSRange(location: 0, length: min(ns.length, anchor + 4000)),
                                   options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
                lineStarts.append(enclosing.upperBound)
            }
            let line = max(0, (lineStarts.lastIndex { $0 <= anchor } ?? 0))
            let first = max(0, line - 4)
            let out = NSMutableAttributedString()
            var n = first
            var pos = lineStarts[min(first, lineStarts.count - 1)]
            while n < first + 14 && pos < ns.length {
                let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
                var content = ns.substring(with: lr).replacingOccurrences(of: "\t", with: "    ")
                while content.hasSuffix("\n") || content.hasSuffix("\r") { content.removeLast() }
                let num = NSAttributedString(string: String(format: "%4d  ", n + 1),
                                             attributes: [.font: Theme.mono(11), .foregroundColor: Theme.ink3])
                out.append(num)
                out.append(highlight(content, words, base: [.font: Theme.mono(11), .foregroundColor: Theme.ink],
                                     current: n == line))
                out.append(NSAttributedString(string: "\n"))
                pos = lr.upperBound
                n += 1
            }
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingTail
            p.lineSpacing = 2
            out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
            e.body = .text(out, numbered: true)
            e.location = "line \(line + 1)"
        } else {
            // Prose: a passage around the hit (or the opening, for a meaning match).
            let clean = { (s: String) in s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            let lo = max(0, anchor - 260)
            let hi = min(ns.length, anchor + 700)
            var passage = clean(ns.substring(with: NSRange(location: lo, length: hi - lo)))
            if lo > 0 { passage = "…" + passage }
            if hi < ns.length { passage += "…" }
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 3.5
            let s = NSMutableAttributedString(attributedString:
                highlight(passage, words, base: [.font: Theme.ui(13), .foregroundColor: Theme.ink2], current: false))
            s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
            e.body = .text(s, numbered: false)
        }
        return e
    }

    /// The hit whose line contains the most distinct query words.
    static func densestHit(_ hits: [NSRange], in ns: NSString, words: [String]) -> NSRange? {
        var best: (NSRange, Int)?
        for h in hits.prefix(400) {
            let line = ns.substring(with: ns.lineRange(for: h)).lowercased()
            let n = words.filter { line.contains($0.lowercased()) }.count
            if best == nil || n > best!.1 { best = (h, n) }
            if n == words.count { break }
        }
        return best?.0
    }

    private func highlight(_ s: String, _ words: [String], base: [NSAttributedString.Key: Any], current: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString(string: s, attributes: base)
        let ns = s as NSString
        for w in words where w.count >= 2 || words.count == 1 {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                if r.location == NSNotFound { break }
                out.addAttributes([.backgroundColor: Theme.hit, .foregroundColor: Theme.ink], range: r)
                search = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
            }
        }
        if current { out.addAttribute(.foregroundColor, value: Theme.ink, range: NSRange(location: 0, length: out.length)) }
        return out
    }

    // MARK: - Folder & fallback

    private func folder(_ path: String, _ meta: String) -> Evidence {
        let url = URL(fileURLWithPath: path)
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        let sorted = items.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        return Evidence(path: path, meta: meta,
                        body: .folder(sorted.prefix(10).map { ($0.lastPathComponent, $0.path) }, total: items.count))
    }

    private func thumbnail(_ path: String, meta: String, size: CGSize) -> Evidence {
        let sem = DispatchSemaphore(value: 0)
        var out: NSImage?
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size, scale: 2,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in out = rep?.nsImage; sem.signal() }
        _ = sem.wait(timeout: .now() + 1.5)
        if let out { return Evidence(path: path, meta: meta, body: .thumbnail(out)) }
        return Evidence(path: path, meta: meta, body: .none("No preview for this kind of file"))
    }

    // MARK: - Metadata

    private static let sizeFormatter: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()
    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()

    /// "PDF document, 2.1 MB, modified 6 months ago". Plain words, no separators to decode.
    static func meta(_ path: String, isDir: Bool) -> String {
        let url = URL(fileURLWithPath: path)
        let v = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey])
        var parts: [String] = []
        parts.append(v?.localizedTypeDescription ?? (isDir ? "Folder" : "File"))
        if !isDir, let s = v?.fileSize { parts.append(sizeFormatter.string(fromByteCount: Int64(s))) }
        if let d = v?.contentModificationDate { parts.append("modified " + dateFormatter.localizedString(for: d, relativeTo: Date())) }
        return parts.joined(separator: ", ")
    }

    static func terms(_ q: String) -> [String] {
        q.split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init).filter { !$0.isEmpty }
    }
}
