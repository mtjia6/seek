import Accelerate
import Foundation

/// Turns text into unit vectors whose dot product measures similarity of meaning.
///
/// Backed by a Model2Vec static model (see StaticEmbedding). Measured on this
/// machine's own files (5 natural-language queries, 3.8k docs), it reached MRR
/// 0.56 against 0.01 for Apple's NLEmbedding and 0.22 for NLContextualEmbedding,
/// at ~0.7 ms per document instead of 16-28 ms. The table is immutable, so one
/// instance is safe to share across threads.
final class Embedder {
    static let modelName = "potion-base-8M"
    let dim: Int
    private let model: StaticEmbedding?

    init() {
        model = StaticEmbedding.loadDefault()
        dim = model?.dim ?? 256
        if model == nil { log("semantic: \(Self.modelName) not found; semantic search disabled") }
    }
    var available: Bool { model != nil }

    func vector(_ text: String) -> [Float]? { model?.embed(text) }

    /// One passage per document: its name plus its first ~100 words.
    ///
    /// Splitting long files into many windows and scoring by the best one
    /// measured *worse* (MRR 0.16): every extra window is another chance of a
    /// spuriously high cosine, so long noisy files float to the top.
    static func passage(name: String, body: String) -> String? {
        let title = ((name as NSString).deletingPathExtension)
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let words = body.split(whereSeparator: \.isWhitespace).prefix(100)
        guard words.count >= 5 else { return nil }
        return title + " " + words.joined(separator: " ")
    }
}

/// Brute-force nearest-neighbour search over every document vector.
///
/// At this scale (thousands of documents) an exact scan is one
/// matrix-vector product, M (rows x dim) * q, which Accelerate runs in well
/// under a millisecond. An approximate index (HNSW, IVF) would only start
/// paying off past ~10^6 vectors, and it would give up exactness to get there.
final class VectorIndex {
    let dim: Int
    private let lock = NSLock()
    private var matrix: [Float] = []       // row-major, rows x dim
    private var docOfRow: [Int64] = []
    private var pathOf: [Int64: String] = [:]
    private var dead = Set<Int64>()

    init(dim: Int) { self.dim = dim }

    var rows: Int { lock.withLock { docOfRow.count } }

    func add(doc: Int64, path: String, vector: [Float]) {
        guard vector.count == dim else { return }
        lock.withLock {
            matrix += vector; docOfRow.append(doc)
            pathOf[doc] = path
            dead.remove(doc)
        }
    }

    func remove(doc: Int64) { lock.withLock { dead.insert(doc); pathOf[doc] = nil } }

    /// Top documents by cosine similarity, at or above `minScore`.
    func search(_ q: [Float], k: Int, minScore: Float) -> [(path: String, score: Float)] {
        lock.withLock {
            let n = docOfRow.count
            guard n > 0, q.count == dim else { return [] }
            var scores = [Float](repeating: 0, count: n)
            vDSP_mmul(matrix, 1, q, 1, &scores, 1, vDSP_Length(n), 1, vDSP_Length(dim))
            var hits: [(Int64, Float)] = []
            for i in 0..<n where scores[i] >= minScore && !dead.contains(docOfRow[i]) {
                hits.append((docOfRow[i], scores[i]))
            }
            hits.sort { $0.1 > $1.1 }
            return hits.prefix(k).compactMap { d, s in pathOf[d].map { ($0, s) } }
        }
    }
}
