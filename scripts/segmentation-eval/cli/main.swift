import Foundation
// Harness over the repo's REAL transition code (TransitionClass, SegmenterTransitionTable).
//   segcli count <lexical.txt> < gold.jsonl       → "start,end,className" per gold token
//   segcli fit <pairs.tsv> <configs> <outdir> < sentences   configs: "WEIGHT CLAMP"; lattice once, DP per config
//   segcli lemmas < surfaces                     → what each surface resolves to, with each lemma's score (the audit's input)
//   segcli oracle < gold.jsonl                   → per cut-through: is the gold parse in the lattice, and by how much does it lose
//   segcli features < gold.jsonl                → per sentence: characters, gold gap labels, shipped cuts, lattice gap features (boundary model input)
//   segcli run < sentences                         → the shipped path (bundled table, shipped weight)
//   segcli helpers < surfaces                    → "surface<TAB>lemma + helper…": the words deinflection folds into each surface
//   segcli compounds < surfaces                  → "surface<TAB>base + auxiliary" for each surface the lookup sheet names as a compound verb
//   segcli furigana < sentences                  → per sentence, a JSON list of [utf16Location, utf16Length, reading]: the Read view's furigana for dictionary words
// NO_EXTRAS=1                                  → skip the built-in Custom Words (Resources/extras.json)
// NO_BOUNDARY_MODEL=1                          → the path search without the boundary model
// Repo root: four levels up from this file (scripts/segmentation-eval/cli/main.swift), unless KIOKU_CHECKOUT says otherwise.
let root = ProcessInfo.processInfo.environment["KIOKU_CHECKOUT"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
let sourceDictionaryURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DB"] ?? "\(root)/Resources/dictionary.sqlite")
// The app writes its built-in Custom Words (Resources/extras.json) into the downloaded dictionary at
// runtime (CustomWordApplier); the build no longer bakes them in. segcli does the same on a temp copy,
// so the source file is never written. NO_EXTRAS=1 measures the bare dictionary.
let dictionaryURL: URL
if ProcessInfo.processInfo.environment["NO_EXTRAS"] == "1" {
    dictionaryURL = sourceDictionaryURL
} else {
    dictionaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("segcli-\(ProcessInfo.processInfo.processIdentifier).sqlite")
    try? FileManager.default.removeItem(at: dictionaryURL)
    try FileManager.default.copyItem(at: sourceDictionaryURL, to: dictionaryURL)
    guard let resources = Bundle(path: "\(root)/Resources") else { fatalError("no Resources folder at \(root)") }
    let builtIns = CustomWordStore.bundledDefaults(bundle: resources)
    guard builtIns.isEmpty == false else { fatalError("no built-in Custom Words read from \(root)/Resources/extras.json") }
    try CustomWordApplier.apply(builtIns, toDatabaseAt: dictionaryURL)
    atexit { try? FileManager.default.removeItem(at: dictionaryURL) }
}
let store = try DictionaryStore(databaseURL: dictionaryURL)
try store.populateSurfacePOSBitsMap()
var trie = DictionaryTrie()
let surfaceData = try store.fetchSurfaceData()
let trieBuildStart = Date()
for record in surfaceData.surfaceRecords { trie.insert(record) }
FileHandle.standardError.write("trie: \(surfaceData.surfaceRecords.count) records in \(String(format: "%.3f", Date().timeIntervalSince(trieBuildStart))) s\n".data(using: .utf8)!)
// SNAPSHOT=<path> saves the trie there (DictionaryTrie+Snapshot), reloads it and segments with the
// reloaded copy, timing both: a check that a snapshot round-trips to the same segmentation.
if let snapshotPath = ProcessInfo.processInfo.environment["SNAPSHOT"] {
    var t = Date()
    let bytes = trie.snapshotData(dictionaryKey: "k")
    try bytes.write(to: URL(fileURLWithPath: snapshotPath))
    FileHandle.standardError.write("snapshot write: \(bytes.count / 1_000_000) MB in \(Int(Date().timeIntervalSince(t) * 1000)) ms\n".data(using: .utf8)!)
    t = Date()
    let read = try Data(contentsOf: URL(fileURLWithPath: snapshotPath), options: .alwaysMapped)
    guard let restored = DictionaryTrie.restored(from: read, dictionaryKey: "k") else { fatalError("restore failed") }
    FileHandle.standardError.write("snapshot load: \(Int(Date().timeIntervalSince(t) * 1000)) ms\n".data(using: .utf8)!)
    trie = restored
}
let deinflector = Deinflector(ruleSet: try store.fetchDeinflectionRuleSet(), trie: trie)
let segmenter = Segmenter(
    trie: trie,
    deinflector: deinflector,
    partOfSpeechByEntryID: surfaceData.partOfSpeechByEntryID,
    frequenciesFrom: store
)
// NO_BOUNDARY_MODEL=1 measures the path search without the boundary model (Segmenter+BoundaryModel.swift).
if ProcessInfo.processInfo.environment["NO_BOUNDARY_MODEL"] == "1" { segmenter.boundaryModel = nil }
FileHandle.standardError.write("boundary model loaded: \(segmenter.boundaryModel != nil)\n".data(using: .utf8)!)
// NO_NAMES=1 measures the same dictionary without JMnedict name edges (Segmenter+Names.swift).
if ProcessInfo.processInfo.environment["NO_NAMES"] == "1" { segmenter.useNameSurfaces([]) }
UserDefaults.standard.removeObject(forKey: SegmenterSettings.strategyKey)
// STRATEGY=local measures the greedy walk (with its demotion list) instead of the shipped path search.
if ProcessInfo.processInfo.environment["STRATEGY"] == "local" {
    UserDefaults.standard.set(SegmentationStrategy.localLongestMatch.rawValue, forKey: SegmenterSettings.strategyKey)
}
UserDefaults.standard.removeObject(forKey: SegmentationDemotions.storageKey)
let separator = String(UnicodeScalar(0x1E)!)
let mode = CommandLine.arguments[1]

if mode == "lemmas" {
    let freq = try store.fetchFrequencyScoreBySurface()
    while let line = readLine() {
        let r = segmenter.resolvedTrieLemmasWithInflectionSteps(for: line)
        print(
            line,
            "steps=\(r.inflectionSteps)",
            "own=\(freq[line] ?? 0)",
            r.lemmas.sorted().map { "\($0)=\(freq[$0] ?? 0)" }.joined(separator: " ")
        )
    }
    exit(0)
}

if mode == "helpers" {
    while let line = readLine() {
        guard let lemma = segmenter.preferredLemma(for: line) else { print("\(line)\t-"); continue }
        let helpers = deinflector.helperWords(from: deinflector.deinflectionPaths(for: line), targetLemma: lemma)
        print("\(line)\t\(([lemma] + helpers).joined(separator: " + "))")
    }
    exit(0)
}

if mode == "compounds" {
    let posTags: (String) -> [String] = { candidate in
        let entries = (try? store.lookup(surface: candidate, mode: .kanjiAndKana)) ?? []
        return entries.flatMap { $0.senses.compactMap(\.pos) }.flatMap { $0.components(separatedBy: ",") }
    }
    while let line = readLine() {
        let edges = segmenter.longestMatchResult(for: line).latticeEdges
        if let parts = CompoundVerbSplitter.parts(surface: line, edges: edges, segmenter: segmenter, posTags: posTags) {
            print("\(line)\t\(parts.base) + \(parts.auxiliary)")
        }
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
                cache[surface] = edge.map { TransitionClass.name(surface: surface, partOfSpeech: $0.partOfSpeech, lexical: lexical) }
                    ?? TransitionClass.boundary
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
                let cls = edge.isDictionaryMatch ? TransitionClass.name(
                    surface: edge.surface,
                    partOfSpeech: edge.partOfSpeech,
                    lexical: table.lexical
                ) : TransitionClass.boundary
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

if mode == "furigana" {
    let readingData = SurfaceReadingDataMap(try store.fetchSurfaceReadingData())
    // Without the per-kanji fallback map (it needs the app's enrichment layer): that only paints
    // words the dictionary doesn't know, never a dictionary word's reading.
    let resolver = FuriganaResolver(segmenter: segmenter)
    while let line = readLine() {
        let furigana = resolver.build(for: line, edges: segmenter.longestMatchEdges(for: line), surfaceReadingData: readingData)
        let rows: [[Any]] = furigana.byLocation.keys.sorted().map { [$0, furigana.lengthByLocation[$0] ?? 0, furigana.byLocation[$0] ?? ""] }
        print(String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!)
    }
    exit(0)
}

if mode == "features" {
    // segcli features < gold.jsonl — training input for the boundary model (scripts/segmentation-eval/boundary),
    // taken from the real lattice so the model trains on exactly what the app computes. One JSON line per
    // sentence; offsets are Characters, the unit the path search uses. Position i (1..<n) is the gap
    // before character i:
    //   c  characters            k  script class per character (BoundaryFeatures.scriptClass)
    //   y  gold label per gap: 1 a gold token starts or ends there, 0 inside a gold token, -1 outside gold
    //   b  1 where the shipped path cuts
    //   f  per gap: BoundaryFeatures.gapFeatures
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentence = record["s"] as? String, let gold = record["g"] as? [[Any]] else {
            fatalError("features: unreadable gold line: \(line.prefix(80))")
        }
        let characters = Array(sentence)
        let n = characters.count
        // Gold spans count unicode scalars; map each scalar offset to the Character it falls in.
        var scalarToCharacter: [Int] = []
        for (offset, character) in characters.enumerated() {
            scalarToCharacter += Array(repeating: offset, count: character.unicodeScalars.count)
        }
        scalarToCharacter.append(n)
        var labels = [Int](repeating: -1, count: n + 1)
        for token in gold {
            guard let a = token[0] as? Int, let b = token[1] as? Int, a < b, b < scalarToCharacter.count else {
                fatalError("features: bad gold span in \(sentence)")
            }
            let start = scalarToCharacter[a], end = scalarToCharacter[b]
            for i in (start + 1)..<max(start + 1, end) where labels[i] != 1 { labels[i] = 0 }
            labels[start] = 1
            labels[end] = 1
        }
        let lattice = segmenter.buildLattice(for: sentence)
        let path = segmenter.absorbingBoundCharacters(in: segmenter.viterbiSelect(from: lattice, in: sentence).path, of: sentence)
        let row: [String: Any] = [
            "c": characters.map(String.init),
            "k": characters.map(BoundaryFeatures.scriptClass),
            "y": Array(labels[1..<max(1, n)]),
            "b": BoundaryFeatures.pathCuts(path, in: sentence),
            "f": BoundaryFeatures.gapFeatures(lattice: lattice, in: sentence),
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
    }
    exit(0)
}

if mode == "relabel" {
    // segcli relabel < gold.jsonl → the same gold with Kioku's word convention applied, for training the
    // boundary model: adjacent gold tokens are merged when the text spanning both resolves (the segmenter's lemma
    // resolution) to the first token's headword (or, for a vs noun, its する verb) — Tatoeba writes
    // 泣き|たく, 歩き|ながら, キス|して; the app reads each as one inflected word. Merges chain left to right
    // (クリア|して|ゆく). LABEL_DEBUG=1 prints each merge to stderr.
    let debug = ProcessInfo.processInfo.environment["LABEL_DEBUG"] == "1"
    // Spans repeat across sentences (して, たい, なさい…); resolve each surface once.
    var resolved: [String: [String]] = [:]
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentence = record["s"] as? String, let gold = record["g"] as? [[Any]] else {
            fatalError("relabel: unreadable gold line: \(line.prefix(80))")
        }
        let scalars = Array(sentence.unicodeScalars)
        // What the span a..<b resolves to: the segmenter's own lemma resolution, plus the noun of a
        // する compound. No lattice is built — resolution alone decides, which keeps this fast.
        func lemmas(_ a: Int, _ b: Int) -> [String] {
            let surface = String(String.UnicodeScalarView(scalars[a..<b]))
            if let cached = resolved[surface] { return cached }
            let found = Array(segmenter.resolvedTrieLemmasWithInflectionSteps(for: surface).lemmas)
                + [segmenter.suruCompoundPrefix(for: surface)].compactMap { $0 }
            resolved[surface] = found
            return found
        }
        var merged: [[Any]] = []
        for token in gold {
            guard let a = token[0] as? Int, let b = token[1] as? Int, let head = token[2] as? String else {
                fatalError("relabel: bad gold token in \(sentence)")
            }
            if var last = merged.last, let lastStart = last[0] as? Int, let lastEnd = last[1] as? Int,
               let lastHead = last[2] as? String, lastEnd == a {
                let spanning = lemmas(lastStart, b)
                // "headword + する" only for a noun JMdict tags as a する verb (vs) — not が + した.
                let suruNoun = segmenter.isValidatedSuruNounPrefix(lastHead)
                if spanning.contains(where: { $0 == lastHead || (suruNoun && $0 == lastHead + "する") }) {
                    if debug {
                        let text = String(String.UnicodeScalarView(scalars[lastStart..<b]))
                        FileHandle.standardError.write("merge \(text) (\(lastHead) + \(head))\n".data(using: .utf8)!)
                    }
                    last[1] = b
                    merged[merged.count - 1] = last
                    continue
                }
            }
            merged.append(token)
        }
        var out = record
        out["g"] = merged
        print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
    }
    exit(0)
}

if mode == "rescore" {
    // segcli rescore <probabilities> <weights> <outdir> < sentences — the shipped path search with the
    // boundary model's costs added (BoundaryCosts), once per weight: lattice once per sentence, outdir/cfgN.txt
    // per weight in `run`'s format. <probabilities>: one JSON array of P(cut) per gap per sentence line.
    let probabilityLines = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    let weights = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8).split(separator: "\n").compactMap { Double($0) }
    let outDir = CommandLine.arguments[4]
    var outputs = [String](repeating: "", count: weights.count)
    var lineNumber = 0
    while let line = readLine() {
        guard lineNumber < probabilityLines.count,
              let probabilities = try JSONSerialization.jsonObject(with: Data(probabilityLines[lineNumber].utf8)) as? [Double],
              probabilities.count == max(0, line.count - 1) else {
            fatalError("rescore: line \(lineNumber + 1) has no matching probabilities")
        }
        lineNumber += 1
        let lattice = segmenter.buildLattice(for: line)
        for (i, weight) in weights.enumerated() {
            let costs = weight == 0 ? nil : BoundaryCosts(cutProbabilities: probabilities, weight: weight)
            let path = segmenter.absorbingBoundCharacters(in: segmenter.viterbiSelect(from: lattice, in: line, boundaryCosts: costs).path, of: line)
            outputs[i] += path.map { $0.surface }.joined(separator: separator) + "\n"
        }
    }
    for (i, text) in outputs.enumerated() { try text.write(toFile: "\(outDir)/cfg\(i).txt", atomically: true, encoding: .utf8) }
    exit(0)
}

if mode == "run" {
    FileHandle.standardError.write("transition table loaded: \(segmenter.transitionTable != nil)\n".data(using: .utf8)!)
    while let line = readLine() { print(segmenter.longestMatchEdges(for: line).map { $0.surface }.joined(separator: separator)) }
    exit(0)
}

let pairsURL = URL(fileURLWithPath: CommandLine.arguments[2])
let configs: [[Double]] = try String(
    contentsOfFile: CommandLine.arguments[3],
    encoding: .utf8
).split(separator: "\n").map { $0.split(separator: " ").compactMap { Double($0) } }
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
