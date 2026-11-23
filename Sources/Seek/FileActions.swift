import Foundation

/// Batch file operations for the result list. Nothing here can destroy data:
/// a move refuses a name that is already taken at the destination, and delete
/// means the Trash. Each operation reports where every item ended up, which is
/// exactly what undo needs.
enum FileActions {
    struct Outcome {
        /// Items that moved, and where to. Undo is this list read backwards.
        var done: [(from: String, to: String)] = []
        /// Left alone because something with that name was already there.
        var skipped = 0
        var failed = 0
        /// The first failure, in Cocoa's words.
        var error: String?

        fileprivate mutating func fail(_ e: Error) {
            failed += 1
            if error == nil { error = e.localizedDescription }
        }
    }

    /// Drop paths that sit inside another target: moving a folder already moves them.
    static func roots(_ paths: [String]) -> [String] {
        let all = Set(paths)
        return paths.filter { p in
            var dir = (p as NSString).deletingLastPathComponent
            while dir.count > 1 {
                if all.contains(dir) { return false }
                dir = (dir as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    static func move(_ paths: [String], into dir: String) -> Outcome {
        var out = Outcome()
        for p in roots(paths) {
            let dest = (dir as NSString).appendingPathComponent((p as NSString).lastPathComponent)
            if exists(dest) { out.skipped += 1; continue }   // includes "it is already in that folder"
            do {
                try FileManager.default.moveItem(atPath: p, toPath: dest)
                out.done.append((p, dest))
            } catch { out.fail(error) }
        }
        return out
    }

    static func trash(_ paths: [String]) -> Outcome {
        var out = Outcome()
        for p in roots(paths) {
            var landed: NSURL?
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &landed)
                out.done.append((p, landed?.path ?? ""))
            } catch { out.fail(error) }
        }
        return out
    }

    /// Put every item back where it came from. An original location that has
    /// been reused in the meantime is left alone.
    static func undo(_ done: [(from: String, to: String)]) -> Outcome {
        var out = Outcome()
        for (from, to) in done.reversed() {
            if to.isEmpty || exists(from) { out.skipped += 1; continue }
            do {
                try FileManager.default.moveItem(atPath: to, toPath: from)
                out.done.append((to, from))
            } catch { out.fail(error) }
        }
        return out
    }

    /// lstat, not `fileExists`: a dangling symlink still occupies its name.
    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}
