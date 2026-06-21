import XCTest
@testable import Kioku

// Regression for the user-reported 月色チャイのん furigana drop. Drives the REAL segmenter + REAL
// surface_readings so it mirrors production exactly. The defect was 生きてゆく: the surface okurigana
// 〜てゆく failed to phonetically match the stored reading いきていく (〜ていく), so the kanji-run reading
// was rejected and 生 rendered with no ruby at all (and being a dictionary match, the per-kanji
// fallback was suppressed). A furigana span may cover more than one kanji (化石 → かせき over [0,2)),
// so the assertion checks each kanji is COVERED by some annotation, not that each has its own entry.
@MainActor
final class FuriganaSongLineRegressionTests: XCTestCase {

    private func realPipeline() throws -> (FuriganaResolver, Segmenter, SurfaceReadingDataMap) {
        let resources = try TestReadResources.shared()
        let map = SurfaceReadingDataMap(try resources.dictionaryStore.fetchSurfaceReadingData())
        return (FuriganaResolver(segmenter: resources.segmenter), resources.segmenter, map)
    }

    // Renders the edge list and resolved ruby for a line so an assertion failure is self-explanatory.
    private func diagnostics(_ line: String, _ segmenter: Segmenter, _ map: SurfaceReadingDataMap, _ resolved: (byLocation: [Int: String], lengthByLocation: [Int: Int])) -> String {
        var out = "\nLINE: \(line)\n"
        for edge in segmenter.longestMatchEdges(for: line) {
            out += "  edge surface=\(edge.surface) dictMatch=\(edge.isDictionaryMatch) lemma=\(segmenter.preferredLemma(for: edge.surface) ?? "nil") reading=\(FuriganaResolver.readingForSegment(edge.surface, surfaceReadingData: map) ?? "nil")\n"
        }
        out += "  annotations: \(resolved.byLocation.sorted { $0.key < $1.key }.map { "@\($0.key)(len \(resolved.lengthByLocation[$0.key] ?? -1))=\($0.value)" }.joined(separator: " "))\n"
        return out
    }

    // True when UTF-16 position `p` falls inside some annotation's [location, location+length) span.
    private func isCovered(_ p: Int, _ resolved: (byLocation: [Int: String], lengthByLocation: [Int: Int])) -> Bool {
        for (loc, _) in resolved.byLocation {
            let len = resolved.lengthByLocation[loc] ?? 0
            if p >= loc && p < loc + len { return true }
        }
        return false
    }

    // Asserts every kanji in `line` is covered by a furigana annotation span.
    private func assertEveryKanjiHasRuby(_ line: String, file: StaticString = #filePath, line lineNo: UInt = #line) throws {
        let (resolver, segmenter, map) = try realPipeline()
        let edges = segmenter.longestMatchEdges(for: line)
        let resolved = resolver.build(for: line, edges: edges, surfaceReadingData: map)
        let context = diagnostics(line, segmenter, map, resolved)

        var utf16Index = 0
        for ch in Array(line) {
            if ScriptClassifier.containsKanji(String(ch)) {
                XCTAssertTrue(isCovered(utf16Index, resolved),
                              "kanji \(ch) @\(utf16Index) has no furigana\(context)",
                              file: file, line: lineNo)
            }
            utf16Index += String(ch).utf16.count
        }
    }

    // The direct trigger: 生きてゆく (〜てゆく) vs stored reading いきていく (〜ていく).
    func testIkiteyukuKanjiHasRuby() throws { try assertEveryKanjiHasRuby("生きてゆく") }

    // The lyric lines from the screenshots, end to end through the real pipeline.
    func testLyricLine1EveryKanjiHasRuby() throws { try assertEveryKanjiHasRuby("掬いあげた化石ムーンフラグメント") }
    func testLyricLine5EveryKanjiHasRuby() throws { try assertEveryKanjiHasRuby("生きてゆくのシェノン") }

    // Second screenshot: 振り子 (pendulum, ふりこ) is a 振 / 子 two-run compound split by り —
    // 振 must get ふ and 子 must get こ. Plus the full line it sits in.
    func testFurikoEveryKanjiHasRuby() throws { try assertEveryKanjiHasRuby("振り子") }
    func testLyricLineFurikoEveryKanjiHasRuby() throws { try assertEveryKanjiHasRuby("振り子の様止まらず流されてたゆた") }
}
