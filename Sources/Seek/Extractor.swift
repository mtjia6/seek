import AppKit
import PDFKit
import Vision

enum ContentKind: Int {
    case text = 1, pdf, rich, office, image  // raw order = indexing priority (cheap first)
}

/// Pulls searchable text out of a file. Everything is capped so one huge file
/// can't stall the indexer or bloat the database.
enum Extractor {
    static let maxChars = 200_000

    static let textExts: Set<String> = [
        "txt", "md", "markdown", "rst", "org", "tex", "bib", "csv", "tsv", "log",
        "json", "yaml", "yml", "toml", "xml", "ini", "cfg", "conf", "ipynb",
        "html", "htm", "css", "scss", "js", "mjs", "ts", "tsx", "jsx", "vue", "svelte",
        "py", "java", "kt", "scala", "c", "h", "cc", "cpp", "hpp", "m", "mm", "swift",
        "go", "rs", "rb", "php", "sh", "zsh", "bash", "fish", "sql", "r", "jl", "lua",
        "hs", "ml", "ex", "exs", "erl", "clj", "dart", "s", "asm", "proto", "gradle",
        "cmake", "makefile", "dockerfile", "srt", "vtt",
    ]
    static let richExts: Set<String> = ["rtf", "doc", "docx", "odt"]
    static let officeExts: Set<String> = ["pptx", "xlsx"]
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]

    /// Dependency trees and caches: you never want their *contents* in results.
    static let excludedFragments = ["/go/pkg/mod/", "/venvs/", "/vendor/", "/.build/", "/build/", "/dist/",
                                    "/target/", "/Pods/", ".xcassets/", "/node_modules/"]

    /// Cheap check from the path alone (no I/O).
    static func kind(for path: String) -> ContentKind? {
        if excludedFragments.contains(where: path.contains) { return nil }
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if textExts.contains(ext) || (ext.isEmpty && ["makefile", "dockerfile", "readme"].contains(name)) { return .text }
        if ext == "pdf" { return .pdf }
        if richExts.contains(ext) { return .rich }
        if officeExts.contains(ext) { return .office }
        if imageExts.contains(ext) { return .image }
        return nil
    }

    static func sizeAllowed(_ kind: ContentKind, _ size: Int64) -> Bool {
        switch kind {
        case .text: return size <= 2_000_000
        case .pdf: return size <= 80_000_000
        case .rich: return size <= 30_000_000
        case .office: return size <= 50_000_000
        case .image: return size >= 15_000 && size <= 40_000_000  // tiny images are icons
        }
    }

    static func extract(_ path: String, _ kind: ContentKind) -> String? {
        switch kind {
        case .text: return plainText(path)
        case .pdf: return pdfText(path)
        case .rich: return richText(path)
        case .office: return officeText(path)
        case .image: return ocrText(path)
        }
    }

    private static func plainText(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 256 * 1024), !data.isEmpty else { return nil }
        if data.prefix(8192).contains(0) { return nil }  // binary masquerading as text
        return String(decoding: data, as: UTF8.self)
    }

    private static func pdfText(_ path: String) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked else { return nil }
        var out = ""
        for i in 0..<min(doc.pageCount, 150) {
            if let s = doc.page(at: i)?.string { out += s; out += "\n" }
            if out.count > maxChars { break }
        }
        return out.isEmpty ? nil : String(out.prefix(maxChars))
    }

    private static func richText(_ path: String) -> String? {
        let s = try? NSAttributedString(url: URL(fileURLWithPath: path), options: [:], documentAttributes: nil)
        return s.map { String($0.string.prefix(maxChars)) }
    }

    /// Text in screenshots, photos of whiteboards, scanned pages. Vision runs the
    /// recognizer on the Neural Engine; "accurate" is ~10x slower than "fast" but
    /// reads small UI text reliably, and it only ever runs once per image.
    private static func ocrText(_ path: String) -> String? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
        do { try handler.perform([req]) } catch { return nil }
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : String(lines.joined(separator: "\n").prefix(maxChars))
    }

    /// .pptx/.xlsx are zip archives of XML; pull the text nodes out with unzip.
    private static func officeText(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        let members = ext == "pptx" ? ["ppt/slides/slide*.xml", "ppt/notesSlides/*.xml"] : ["xl/sharedStrings.xml"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", path] + members
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let xml = String(decoding: data.prefix(4_000_000), as: UTF8.self)
        // Keep only text between tags.
        var out = "", inTag = false
        out.reserveCapacity(xml.count / 3)
        for ch in xml {
            if ch == "<" { inTag = true; out.append(" ") } else if ch == ">" { inTag = false } else if !inTag { out.append(ch) }
        }
        return String(out.prefix(maxChars))
    }
}
