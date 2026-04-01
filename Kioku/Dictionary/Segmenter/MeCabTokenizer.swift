import Foundation
import mecab

// Wraps the MeCab C library lifecycle and provides Swift-friendly tokenization of Japanese text.
nonisolated final class MeCabTokenizer {
    private var mecabPtr: OpaquePointer?

    // Initializes MeCab with the compiled dictionary at the given directory path.
    // MeCab requires a mecabrc config file even when dictionary path is passed via -d.
    init?(dictionaryPath: String) {
        guard let rcPath = Bundle.main.path(forResource: "mecabrc", ofType: nil, inDirectory: "MeCab") else {
            print("MeCabTokenizer: mecabrc not found in bundle")
            return nil
        }
        let arg = "-r \(rcPath) -d \(dictionaryPath)"
        mecabPtr = mecab_new2(arg)
        guard mecabPtr != nil else {
            let err = mecab_strerror(nil).map { String(cString: $0) } ?? "unknown error"
            print("MeCabTokenizer: init failed for \(dictionaryPath) — \(err)")
            return nil
        }
    }

    deinit {
        if let mecabPtr {
            mecab_destroy(mecabPtr)
        }
    }

    // Tokenizes input text and returns parsed nodes with surface, features, and byte offsets.
    func tokenize(_ text: String) -> [MeCabNode] {
        guard let mecabPtr else { return [] }

        // Pass the text as a C string so MeCab owns a consistent pointer for byte-offset computation.
        return text.withCString { cStr in
            let len = strlen(cStr)
            guard let nodePtr = mecab_sparse_tonode2(mecabPtr, cStr, len) else { return [] }
            var current = nodePtr
            var nodes: [MeCabNode] = []

            // Walk the linked list of nodes, extracting surface and features for non-BOS/EOS nodes.
            var hasMore = true
            while hasMore {
                let n = current.pointee
                let status = Int(n.stat)
                // stat == 2 is BOS, stat == 3 is EOS — skip both.
                if status != 2 && status != 3 {
                    let surfaceLength = Int(n.length)
                    let surface: String
                    if surfaceLength > 0, let ptr = n.surface {
                        // Rebind CChar pointer to UInt8 for String(bytes:encoding:).
                        let uint8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                        surface = String(
                            bytes: UnsafeBufferPointer(start: uint8Ptr, count: surfaceLength),
                            encoding: .utf8
                        ) ?? ""
                    } else {
                        surface = ""
                    }

                    let feature = String(cString: n.feature)

                    // Compute byte offset from the start of the input C string.
                    let byteOffset: Int
                    if let surfPtr = n.surface {
                        byteOffset = surfPtr - cStr
                    } else {
                        byteOffset = 0
                    }

                    nodes.append(MeCabNode(
                        surface: surface,
                        feature: feature,
                        byteLength: surfaceLength,
                        byteOffset: byteOffset
                    ))
                }

                if let next = n.next {
                    current = UnsafePointer(next)
                } else {
                    hasMore = false
                }
            }

            return nodes
        }
    }

    // Returns the last error message from MeCab, if any.
    func lastError() -> String? {
        guard let mecabPtr else { return nil }
        let err = mecab_strerror(mecabPtr)
        return err.map { String(cString: $0) }
    }
}
