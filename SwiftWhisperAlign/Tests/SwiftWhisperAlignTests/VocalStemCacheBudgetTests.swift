// VocalStemCacheBudgetTests.swift
// Pins VocalStemCache.enforceBudget — the LRU size cap that bounds the previously-unbounded vocal
// stem cache (which had grown to multiple GB on-device). Verifies the dir is brought under budget
// and that the most-recently-used entry survives eviction.

import XCTest
@testable import SwiftWhisperAlign

final class VocalStemCacheBudgetTests: XCTestCase {

    // Same path enforceBudget() operates on (Caches/VocalStems). On the test host this is scratch.
    private var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VocalStems", isDirectory: true)
    }
    private var written: [URL] = []

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for u in written { try? FileManager.default.removeItem(at: u) }
    }

    @discardableResult
    private func write(_ name: String, bytes: Int, ageSeconds: TimeInterval) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path)
        written.append(url)
        return url
    }

    private func dirSize() -> Int {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    // The invariant: after enforcement the directory is at or under the budget.
    func testEnforcesTotalUnderBudget() throws {
        try write("budgettest-1.f32", bytes: 300_000, ageSeconds: 300)
        try write("budgettest-2.f32", bytes: 300_000, ageSeconds: 200)
        try write("budgettest-3.f32", bytes: 300_000, ageSeconds: 100)
        VocalStemCache.enforceBudget(maxBytes: 500_000)
        XCTAssertLessThanOrEqual(dirSize(), 500_000)
    }

    // Eviction is least-recently-used: the freshest file must outlive older ones.
    func testNewestSurvivesEviction() throws {
        let fresh = try write("budgettest-fresh.f32", bytes: 300_000, ageSeconds: 5)
        try write("budgettest-stale.f32", bytes: 300_000, ageSeconds: 99_999)
        VocalStemCache.enforceBudget(maxBytes: 400_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "most-recently-used stem must survive eviction")
    }

    // Under budget: nothing is touched.
    func testUnderBudgetKeepsEverything() throws {
        let a = try write("budgettest-keep.f32", bytes: 100_000, ageSeconds: 100)
        VocalStemCache.enforceBudget(maxBytes: 10_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }
}
