import Foundation

// Loads IPADic's CRF-trained connection-cost matrix from Resources/MeCab/ipadic/matrix.bin
// and exposes O(1) bigram-cost lookups by IPADic context ID pair. This is what makes the
// trie segmenter's Viterbi path competitive with MeCab's native segmentation: instead of
// averaging the matrix into POS-class buckets (which throws away most of the discrimination
// signal), every (right_id_prev, left_id_next) pair gets its own empirically-fitted cost.
//
// File format (little-endian throughout):
//   uint16 lsize    -- left-context dimension (number of distinct left_id values)
//   uint16 rsize    -- right-context dimension (currently equal to lsize in IPADic)
//   int16  cost[lsize × rsize]   -- row-major; cost(right_prev, left_next) = matrix[r + l*lsize]
//
// IPADic 2.7.0 is 1316×1316 → ~3.5 MB. We load lazily on first access and keep one shared
// instance for the app lifetime. Reads are O(1) — pointer + offset into the mmap'd buffer.
nonisolated final class IPADicMatrix: @unchecked Sendable {

    static let shared = IPADicMatrix()

    private let buffer: [Int16]?
    private let lsize: Int
    private let rsize: Int

    private init() {
        guard let url = Self.matrixURL() else {
            buffer = nil
            lsize = 0
            rsize = 0
            print("IPADicMatrix: matrix.bin not found in bundle — trie-Viterbi will fall back to POS buckets")
            return
        }
        guard let raw = try? Data(contentsOf: url) else {
            buffer = nil
            lsize = 0
            rsize = 0
            print("IPADicMatrix: failed to read matrix.bin at \(url.path)")
            return
        }
        guard raw.count >= 4 else {
            buffer = nil
            lsize = 0
            rsize = 0
            print("IPADicMatrix: matrix.bin too small (\(raw.count) bytes)")
            return
        }

        let l = raw.withUnsafeBytes { ptr -> Int in
            Int(ptr.load(fromByteOffset: 0, as: UInt16.self))
        }
        let r = raw.withUnsafeBytes { ptr -> Int in
            Int(ptr.load(fromByteOffset: 2, as: UInt16.self))
        }
        let expectedBytes = 4 + l * r * 2
        guard raw.count >= expectedBytes else {
            buffer = nil
            lsize = 0
            rsize = 0
            print("IPADicMatrix: matrix.bin size \(raw.count) < expected \(expectedBytes) for \(l)×\(r)")
            return
        }

        // Slice the body and reinterpret as int16. Copying into a [Int16] keeps lifetime simple;
        // 3.5 MB is small enough that we don't need to mmap and manage memory by hand.
        let body = raw.subdata(in: 4..<expectedBytes)
        var costs = [Int16](repeating: 0, count: l * r)
        _ = costs.withUnsafeMutableBytes { dest in
            body.copyBytes(to: dest, count: dest.count)
        }
        buffer = costs
        lsize = l
        rsize = r
    }

    // Returns the connection cost between adjacent nodes with the given context IDs.
    // Matches MeCab's internal formula: matrix_[lNode.rcAttr + rNode.lcAttr * lsize_].
    // Out-of-range IDs return 0 so partially-tagged lattices degrade gracefully.
    func cost(rightID rid: Int32, leftID lid: Int32) -> Int {
        guard let buffer else { return 0 }
        let r = Int(rid)
        let l = Int(lid)
        guard r >= 0, r < lsize, l >= 0, l < rsize else { return 0 }
        return Int(buffer[r + l * lsize])
    }

    // True when the matrix is loaded and ready to serve lookups.
    var isAvailable: Bool { buffer != nil }

    // Locates matrix.bin in the app bundle, mirroring the path the mecabrc and MeCab segmenter
    // already point at. Walks all bundles as a fallback so test runners that don't use the main
    // bundle layout still resolve the file.
    private static func matrixURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "matrix", withExtension: "bin", subdirectory: "MeCab/ipadic") {
            return bundled
        }
        // Fallback for test bundles that load resources differently.
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: "matrix", withExtension: "bin", subdirectory: "MeCab/ipadic") {
                return url
            }
        }
        return nil
    }
}
