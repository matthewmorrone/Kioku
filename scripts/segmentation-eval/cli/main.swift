import Foundation
// Harness over the repo's REAL transition code (TransitionClass, SegmenterTransitionTable).
//   segcli count <lexical.txt> < gold.jsonl       → "start,end,className" per gold token
//   segcli fit <pairs.tsv> <configs> <outdir> < sentences   configs: "WEIGHT CLAMP"; lattice once, DP per config
//   segcli lemmas < surfaces                     → what each surface resolves to, with each lemma's score (the audit's input)
//   segcli oracle < gold.jsonl                   → per cut-through: is the gold parse in the lattice, and by how much does it lose
//   segcli run < sentences                         → the shipped path (bundled table, shipped weight)
// Repo root: four levels up from this file (scripts/segmentation-eval/cli/main.swift), unless KIOKU_CHECKOUT says otherwise.
let root = ProcessInfo.processInfo.environment["KIOKU_CHECKOUT"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
let store = try DictionaryStore(databaseURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DB"] ?? "\(root)/Resources/dictionary.sqlite"))
try store.populateSurfacePOSBitsMap()
let trie = DictionaryTrie()
let surfaceData = try store.fetchSurfaceData()
for record in surfaceData.surfaceRecords { trie.insert(record) }
let deinflector = try Deinflector(jsonFileURL: URL(fileURLWithPath: "\(root)/Resources/deinflection.json"), trie: trie)
let segmenter = Segmenter(trie: trie, deinflector: deinflector, partOfSpeechByEntryID: surfaceData.partOfSpeechByEntryID, frequenciesFrom: store)
UserDefaults.standard.removeObject(forKey: SegmenterSettings.strategyKey)
// STRATEGY=local measures the greedy walk (with its demotion list) instead of the shipped path search.
if ProcessInfo.processInfo.environment["STRATEGY"] == "local" { UserDefaults.standard.set(SegmentationStrategy.localLongestMatch.rawValue, forKey: SegmenterSettings.strategyKey) }
UserDefaults.standard.removeObject(forKey: SegmentationDemotions.storageKey)
// Gold comparisons run with clusters whole (the path search's own output); SPLIT_CLUSTERS=1 shows the app default.
UserDefaults.standard.set(ProcessInfo.processInfo.environment["SPLIT_CLUSTERS"] != nil, forKey: SegmenterSettings.splitsParticleClustersKey)
let separator = String(UnicodeScalar(0x1E)!)
let mode = CommandLine.arguments[1]

if mode == "lemmas" {
    let freq = try store.fetchFrequencyScoreBySurface()
    while let line = readLine() {
        let r = segmenter.resolvedTrieLemmasWithInflectionSteps(for: line)
        print(line, "steps=\(r.inflectionSteps)", "own=\(freq[line] ?? 0)", r.lemmas.sorted().map { "\($0)=\(freq[$0] ?? 0)" }.joined(separator: " "))
    }
    exit(0)
}

if mode == "count" {
    let lexical = Set(try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).split(separator: "\n").map(String.init))
    var cache: [String: String] = [:]
    while let line = readLine() {
        guard let data = line.data(using: .utf8), let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentence = record["s"] as? String, let gold = record["g"] as? [[Any]] else { print(""); continue }
        let scalars = Array(sentence.unicodeScalars)
        var parts: [String] = []
        for token in gold {
            guard let a = token[0] as? Int, let b = token[1] as? Int, a < b, b <= scalars.count else { continue }
            var view = String.UnicodeScalarView(); view.append(contentsOf: scalars[a..<b])
            let surface = String(view)
            if cache[surface] == nil {
                // The class the lattice would give this exact span: take the real edge, not a re-derivation.
                let edge = segmenter.buildLattice(for: surface).first { $0.surface == surface && $0.isDictionaryMatch }
                cache[surface] = edge.map { TransitionClass.name(surface: surface, partOfSpeech: $0.partOfSpeech, lexical: lexical) } ?? TransitionClass.boundary
            }
            parts.append("\(a),\(b),\(cache[surface]!)")
        }
        print(parts.joined(separator: " "))
    }
    exit(0)
}

if mode == "explain" {
    // segcli explain < lines of "text<TAB>seg|seg|seg"  — cost breakdown of the chosen path vs the wanted one.
    guard let table = segmenter.transitionTable else { fatalError("no transition table") }
    func describe(_ path: [LatticeEdge], label: String) {
        var total = 0
        var previous: LatticeEdge?
        print("  \(label):")
        for edge in path + [nil] as [LatticeEdge?] {
            let transition = table.cost(from: table.classIDs(for: previous), to: table.classIDs(for: edge))
            total += transition
            if let edge {
                let node = SegmenterScoring.edgeCost(edge)
                total += node
                let cls = edge.isDictionaryMatch ? TransitionClass.name(surface: edge.surface, partOfSpeech: edge.partOfSpeech, lexical: table.lexical) : TransitionClass.boundary
                print(String(format: "    %@  node %5d  (score %.2f, steps %d, class %@)  transition-in %5d", edge.surface, node, edge.frequencyScore, edge.inflectionSteps, cls, transition))
            } else {
                print(String(format: "    <end>  transition-in %5d", transition))
            }
            previous = edge
        }
        print("    TOTAL \(total) centi-nats")
    }
    while let line = readLine() {
        let parts = line.components(separatedBy: "\t")
        guard parts.count == 2 else { continue }
        let text = parts[0]
        let wanted = parts[1].components(separatedBy: "|")
        let lattice = segmenter.buildLattice(for: text)
        print("— \(parts[1])")
        describe(segmenter.viterbiSelect(from: lattice, in: text).path, label: "chosen")
        var spans = Set<String>(); var offset = 0
        for w in wanted { spans.insert("\(offset),\(offset + w.count)"); offset += w.count }
        let allowed = lattice.filter { spans.contains("\(text.distance(from: text.startIndex, to: $0.start)),\(text.distance(from: text.startIndex, to: $0.end))") }
        let forced = segmenter.viterbiSelect(from: allowed, in: text).path
        if forced.isEmpty { print("  wanted: NOT IN LATTICE — missing edge for one of: \(wanted.filter { w in !allowed.contains { $0.surface == w } })") } else { describe(forced, label: "wanted") }
    }
    exit(0)
}

if mode == "oracle" {
    // segcli oracle < gold.jsonl — for each sentence with a cut-through: the chosen path vs the cheapest
    // path that cuts through NO gold token. One TSV row each:
    //   line  marginCentiNats|NOPATH  culprits(surface:score:steps:dict)  chosen  constrained  missingGoldEdges
    // NOPATH / a non-empty last column mean no cost model can fix it: the gold token has no lattice edge.
    // The margin ignores transition costs (node costs only).
    var lineNumber = 0
    while let line = readLine() {
        lineNumber += 1
        guard let data = line.data(using: .utf8),
              let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentence = record["s"] as? String, let gold = record["g"] as? [[Any]] else { continue }
        let spans: [(Int, Int)] = gold.compactMap { t in
            guard let a = t[0] as? Int, let b = t[1] as? Int else { return nil }
            return (a, b)
        }
        let lattice = segmenter.buildLattice(for: sentence)
        let scalars = sentence.unicodeScalars
        func offset(_ index: String.Index) -> Int { scalars.distance(from: scalars.startIndex, to: index) }
        let bounds = lattice.map { (offset($0.start), offset($0.end)) }
        func cutsThrough(_ e: (Int, Int)) -> Bool {
            spans.contains { g in e.0 < g.1 && e.1 > g.0 && (e.0 < g.0 || e.1 > g.1) && !(e.0 <= g.0 && e.1 >= g.1) }
        }
        let chosen = segmenter.viterbiSelect(from: lattice, in: sentence).path
        let culprits = chosen.filter { cutsThrough((offset($0.start), offset($0.end))) }
        if culprits.isEmpty { continue }
        let allowed = zip(lattice, bounds).filter { !cutsThrough($0.1) }.map { $0.0 }
        let constrained = segmenter.viterbiSelect(from: allowed, in: sentence).path
        func cost(_ path: [LatticeEdge]) -> Int { path.reduce(0) { $0 + SegmenterScoring.edgeCost($1) } }
        let margin = constrained.isEmpty ? "NOPATH" : String(cost(constrained) - cost(chosen))
        let edgeSet = Set(bounds.map { "\($0.0),\($0.1)" })
        let missing = spans.filter { g in culprits.contains { c in offset(c.start) < g.1 && offset(c.end) > g.0 } && !edgeSet.contains("\(g.0),\(g.1)") }
            .map { g in String(String.UnicodeScalarView(Array(scalars)[g.0..<g.1])) }
        func show(_ path: [LatticeEdge]) -> String { path.map { "\($0.surface):\(String(format: "%.2f", $0.frequencyScore)):\($0.inflectionSteps)" }.joined(separator: " ") }
        let culpritText = culprits.map { "\($0.surface):\(String(format: "%.2f", $0.frequencyScore)):\($0.inflectionSteps):\($0.isDictionaryMatch ? 1 : 0)" }.joined(separator: " ")
        print([String(lineNumber), margin, culpritText, show(chosen), show(constrained), missing.joined(separator: " ")].joined(separator: "\t"))
    }
    exit(0)
}

if mode == "run" {
    FileHandle.standardError.write("transition table loaded: \(segmenter.transitionTable != nil)\n".data(using: .utf8)!)
    while let line = readLine() { print(segmenter.longestMatchEdges(for: line).map { $0.surface }.joined(separator: separator)) }
    exit(0)
}

let pairsURL = URL(fileURLWithPath: CommandLine.arguments[2])
let configs: [[Double]] = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8).split(separator: "\n").map { $0.split(separator: " ").compactMap { Double($0) } }
let tables: [SegmenterTransitionTable?] = try configs.map { $0[0] == 0 ? nil : try SegmenterTransitionTable(contentsOf: pairsURL, weight: $0[0], clampNats: $0[1]) }
let outDir = CommandLine.arguments[4]
var outputs = [String](repeating: "", count: configs.count)
while let line = readLine() {
    let lattice = segmenter.buildLattice(for: line)
    for i in configs.indices {
        segmenter.transitionTable = tables[i]
        let path = segmenter.absorbingBoundCharacters(in: segmenter.viterbiSelect(from: lattice, in: line).path, of: line)
        outputs[i] += path.map { $0.surface }.joined(separator: separator) + "\n"
    }
}
for (i, text) in outputs.enumerated() { try text.write(toFile: "\(outDir)/cfg\(i).txt", atomically: true, encoding: .utf8) }
