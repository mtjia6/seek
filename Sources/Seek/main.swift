import Foundation

// CLI mode for testing:  Seek --query "exact file name"
let args = CommandLine.arguments
if let qi = args.firstIndex(of: "--query"), qi + 1 < args.count {
    let index = FileIndex()
    let t0 = Date()
    index.rescan()
    let scanTime = Date().timeIntervalSince(t0)
    let searcher = Searcher(index: index)
    for q in args[(qi + 1)...] {
        let t1 = CFAbsoluteTimeGetCurrent()
        let r = searcher.search(q) ?? []
        let ms = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        print("── \"\(q)\"  \(r.count) results in \(String(format: "%.1f", ms)) ms")
        for x in r.prefix(8) { print("  [\(x.tier)] \(x.path)") }
    }
    print("index: \(index.count) items, scan \(String(format: "%.2f", scanTime))s")
    exit(0)
}

print("usage: Seek --query <name> [<name> ...]")
