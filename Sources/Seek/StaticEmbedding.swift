import Accelerate
import Foundation

/// A Model2Vec static embedding model (potion-base-8M by default).
///
/// Model2Vec distills a sentence transformer (here bge-base-en-v1.5) into one
/// lookup table: every vocabulary token gets a fixed 256-d vector, and a text
/// is embedded as the normalized mean of its tokens' vectors. There is no
/// attention and no neural network at inference, so a passage costs
/// microseconds, yet the vectors inherit the teacher's *retrieval* training.
/// That is what Apple's NLEmbedding lacks: it is also an average of word
/// vectors, but of vectors never trained to make queries land near answers.
///
/// Files expected in `dir`: model.safetensors ([vocab, dim] f32),
/// tokenizer.json (BERT WordPiece). Downloaded by build.sh.
final class StaticEmbedding {
    let dim: Int
    private let table: [Float]
    private let vocab: [String: Int32]
    private let specialIds: Set<Int32>

    init?(dir: URL) {
        guard let blob = try? Data(contentsOf: dir.appendingPathComponent("model.safetensors"), options: .mappedIfSafe),
              blob.count > 8,
              let tokData = try? Data(contentsOf: dir.appendingPathComponent("tokenizer.json")),
              let tok = try? JSONSerialization.jsonObject(with: tokData) as? [String: Any],
              let model = tok["model"] as? [String: Any],
              let v = model["vocab"] as? [String: Int]
        else { return nil }

        // safetensors: u64 little-endian header length, JSON header, raw tensor bytes.
        let headerLen = blob.prefix(8).withUnsafeBytes { Int($0.loadUnaligned(as: UInt64.self).littleEndian) }
        guard blob.count >= 8 + headerLen,
              let header = try? JSONSerialization.jsonObject(with: blob.subdata(in: 8..<(8 + headerLen))) as? [String: Any],
              let emb = header["embeddings"] as? [String: Any], emb["dtype"] as? String == "F32",
              let shape = emb["shape"] as? [Int], shape.count == 2,
              let offs = emb["data_offsets"] as? [Int], offs.count == 2
        else { return nil }
        let rows = shape[0]
        dim = shape[1]
        let start = 8 + headerLen + offs[0]
        guard blob.count >= start + rows * dim * 4 else { return nil }
        table = blob.subdata(in: start..<(start + rows * dim * 4)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        var vv: [String: Int32] = [:]
        for (k, id) in v where id < rows { vv[k] = Int32(id) }
        vocab = vv
        specialIds = Set(["[CLS]", "[SEP]", "[PAD]", "[MASK]", "[UNK]"].compactMap { vv[$0] })
    }

    /// Loads from the app bundle, falling back to the dev checkout's Resources/.
    static func loadDefault() -> StaticEmbedding? {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("potion-base-8M")) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // .build/release/Seek -> repo root
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("../../Resources/potion-base-8M").standardized)
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/potion-base-8M"))
        for c in candidates where FileManager.default.fileExists(atPath: c.appendingPathComponent("model.safetensors").path) {
            if let m = StaticEmbedding(dir: c) { return m }
        }
        return nil
    }

    /// L2-normalized mean of token vectors, or nil if no token is in the vocabulary.
    func embed(_ text: String) -> [Float]? {
        let ids = tokenize(text)
        guard !ids.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        table.withUnsafeBufferPointer { tb in
            for id in ids { vDSP_vadd(sum, 1, tb.baseAddress! + Int(id) * dim, 1, &sum, 1, vDSP_Length(dim)) }
        }
        var norm: Float = 0
        vDSP_svesq(sum, 1, &norm, vDSP_Length(dim))
        guard norm > 0 else { return nil }
        var inv = 1 / sqrt(norm)
        vDSP_vsmul(sum, 1, &inv, &sum, 1, vDSP_Length(dim))
        return sum
    }

    // MARK: - BERT tokenization (BertNormalizer + BertPreTokenizer + WordPiece)

    func tokenize(_ text: String, maxTokens: Int = 512) -> [Int32] {
        // Normalizer: lowercase, strip accents, drop control characters.
        let normalized = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var ids: [Int32] = []
        var word: [Unicode.Scalar] = []

        func flush() {
            guard !word.isEmpty else { return }
            wordPiece(word, into: &ids)
            word.removeAll(keepingCapacity: true)
        }

        for sc in normalized.unicodeScalars {
            if ids.count >= maxTokens { break }
            if sc.properties.isWhitespace { flush(); continue }
            if sc.value == 0 || sc.value == 0xFFFD || sc.properties.generalCategory == .control { continue }
            // Pre-tokenizer: punctuation and CJK ideographs are tokens of their own.
            if Self.isPunctuation(sc) || Self.isCJK(sc) {
                flush(); word.append(sc); flush(); continue
            }
            word.append(sc)
        }
        flush()
        return ids.count > maxTokens ? Array(ids.prefix(maxTokens)) : ids
    }

    /// Greedy longest-match-first. Continuation pieces carry the "##" prefix.
    /// A word that can't be fully covered becomes [UNK], which is dropped.
    private func wordPiece(_ chars: [Unicode.Scalar], into ids: inout [Int32]) {
        if chars.count > 100 { return }
        var pieces: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: Int32? = nil
            while start < end {
                var s = start > 0 ? "##" : ""
                s.unicodeScalars.append(contentsOf: chars[start..<end])
                if let id = vocab[s] { found = id; break }
                end -= 1
            }
            guard let id = found else { return }  // whole word is [UNK]
            pieces.append(id)
            start = end
        }
        for p in pieces where !specialIds.contains(p) { ids.append(p) }
    }

    private static func isPunctuation(_ sc: Unicode.Scalar) -> Bool {
        let v = sc.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        switch sc.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    private static func isCJK(_ sc: Unicode.Scalar) -> Bool {
        let v = sc.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }
}
