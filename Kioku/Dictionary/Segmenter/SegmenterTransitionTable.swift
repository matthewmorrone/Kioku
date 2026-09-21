import Foundation

// Transition costs for the path search: how much more or less likely word class B is directly
// after word class A than the two meeting by chance. Node costs (SegmenterScoring.edgeCost) charge
// −ln P(word) for each word alone; this adds what context says, which is what separates two
// parses that are both made of plausible words (電|気をつけて vs 電気|を|つけて).
//
// The numbers live in segmenter-transitions.tsv beside this file: one "A <tab> B <tab> PMI" row per
// class pair the training data has an opinion about, PMI = ln[ P(A,B) / (P(A)·P(B)) ] in nats,
// counted from Tatoeba sentences tokenized at JMdict granularity and classed by TransitionClass.
// Regenerate it with scripts/calibration/fit_transition_costs.py; never edit it by hand.
//
// Do NOT substitute IPADic's connection matrix. That was tried: it is trained for IPADic's lexicon
// and short-unit granularity, and it over-splits JMdict units.
nonisolated final class SegmenterTransitionTable: Sendable {
    // A class as the table indexes it: the full class and the coarser one to back off to.
    // -1 means the table has never seen that name.
    struct ClassIDs: Sendable {
        let fine: Int32
        let coarse: Int32
    }

    // Words with a class of their own ("w:は" rows in the file).
    let lexical: Set<String>
    private let idByName: [String: Int32]
    // Cost in centi-nats keyed by (previous id << 32 | next id), weight and clamp already applied.
    private let costByPair: [UInt64: Int]
    private let boundaryIDs: ClassIDs

    // Loads the pair file, scaling each PMI into a cost: −weight · clamp(PMI), in centi-nats.
    init(
        contentsOf url: URL,
        weight: Double = SegmenterScoring.transitionWeight,
        clampNats: Double = SegmenterScoring.transitionClampNats
    ) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var idByName: [String: Int32] = [:]
        var costByPair: [UInt64: Int] = [:]
        var lexical = Set<String>()

        // Interns a class name, recording the word behind a "w:" class.
        func intern(_ name: Substring) -> Int32 {
            let key = String(name)
            if let id = idByName[key] { return id }
            let id = Int32(idByName.count)
            idByName[key] = id
            if key.hasPrefix("w:") { lexical.insert(String(key.dropFirst(2))) }
            return id
        }

        for row in text.split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let pmi = Double(fields[2]) else { continue }
            let clamped = max(-clampNats, min(clampNats, pmi))
            costByPair[Self.key(intern(fields[0]), intern(fields[1]))] = Int((-weight * clamped * 100).rounded())
        }

        self.idByName = idByName
        self.costByPair = costByPair
        self.lexical = lexical
        let boundary = idByName[TransitionClass.boundary] ?? -1
        self.boundaryIDs = ClassIDs(fine: boundary, coarse: boundary)
    }

    // The table shipped with the app: from the bundle on device, or from the source tree when the
    // code runs outside an app bundle (unit tests, the command-line eval harness).
    static func bundled() -> SegmenterTransitionTable? {
        let besideThisFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("segmenter-transitions.tsv")
        let candidates = [Bundle.main.url(forResource: "segmenter-transitions", withExtension: "tsv"), besideThisFile]
        for case let url? in candidates {
            if let table = try? SegmenterTransitionTable(contentsOf: url) { return table }
        }
        return nil
    }

    // Packs an ordered class pair into one dictionary key.
    private static func key(_ previous: Int32, _ next: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: previous)) << 32 | UInt64(UInt32(bitPattern: next))
    }

    // Classes for a dictionary word, by the same naming the table was counted with.
    func classIDs(surface: String, partOfSpeech: UInt64) -> ClassIDs {
        let name = TransitionClass.name(surface: surface, partOfSpeech: partOfSpeech, lexical: lexical)
        return ClassIDs(fine: idByName[name] ?? -1, coarse: idByName[TransitionClass.coarse(name)] ?? -1)
    }

    // Classes for a lattice edge; nil stands for the start or end of the text. Text the
    // dictionary doesn't cover (names, digits, punctuation) is a boundary: the gold sentences skip
    // exactly that material, so the counts treat it as a break between word runs.
    func classIDs(for edge: LatticeEdge?) -> ClassIDs {
        guard let edge, edge.isDictionaryMatch else { return boundaryIDs }
        return classIDs(surface: edge.surface, partOfSpeech: edge.partOfSpeech)
    }

    // Cost of `next` directly after `previous`. Backs off from the full classes to the coarse ones
    // (next first, then previous, then both) until the table has an opinion; none at all costs 0.
    func cost(from previous: ClassIDs, to next: ClassIDs) -> Int {
        lookup(previous.fine, next.fine) ?? lookup(previous.fine, next.coarse)
            ?? lookup(previous.coarse, next.fine) ?? lookup(previous.coarse, next.coarse) ?? 0
    }

    // The stored cost for one id pair; nil when either id is unknown or the pair has no row.
    private func lookup(_ previous: Int32, _ next: Int32) -> Int? {
        guard previous >= 0, next >= 0 else { return nil }
        return costByPair[Self.key(previous, next)]
    }
}
