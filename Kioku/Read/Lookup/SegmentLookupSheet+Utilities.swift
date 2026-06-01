import UIKit

// NOTE: a `ProviderBox` @unchecked-Sendable wrapper and a background `providerQueue` used to live
// here, smuggling the @MainActor-isolated provider closures onto a background queue. That tripped
// a dispatch_assert_queue(main) precondition at runtime (SIGTRAP on every word tap) — the wrapper
// silenced the compile-time isolation check but not the runtime one. The providers read ReadView
// @State and must run on the main actor; see refreshSheetSupplementalDataAsync below. Both the box
// and the queue were removed.

extension SegmentLookupSheet {
    // Picks the dictionary entry whose reading matches the one `SurfaceSheetViewController`
    // will paint first, so the gloss panel and the reading header agree on initial open.
    // Mirrors the controller's initial-reading-pick logic (override-if-known else readings[0]),
    // and falls back to the lemma resolver's default entry when neither the override nor the
    // first reading has a mapped entry — that fallback path covers custom user-typed readings
    // and kana-only entries that don't participate in the reading→entry map.
    //
    // Without this hop, `resolvedDictionaryEntryForCurrentSelectedSegment()` and the displayed
    // reading were sourced from independent paths and could disagree: e.g. tap 様 in context
    // where furigana renders よう, but the resolver returns the higher-frequency さま entry,
    // so the panel showed "Mr; Mrs; Miss; Ms" under a よう header until the user clicked a
    // chevron. This brings the chevron-handler's reading→entry coupling forward to first paint.
    fileprivate func entryMatchingDisplayedReading(
        readings: [String],
        readingMap: [String: (lemma: String, chain: [String], entry: DictionaryEntry?)],
        fallback: DictionaryEntry?
    ) -> DictionaryEntry? {
        let override = activeReadingOverrideProvider?()
        let displayedReading: String?
        if let override, readings.contains(override) {
            displayedReading = override
        } else {
            displayedReading = readings.first
        }
        if let displayedReading, let mapped = readingMap[displayedReading]?.entry {
            return mapped
        }
        return fallback
    }

    // Runs every supplemental provider, then calls `completion`. Deferred by one main-actor hop
    // (DispatchQueue.main.async) so the sheet's present() animation starts BEFORE the heavy
    // dictionary work — the user sees the sheet move ~16ms after the tap, then the dynamic
    // sections populate a beat later. Stale results from a superseded tap are dropped via the
    // generation counter.
    //
    // CRITICAL — why this runs on MAIN, not a background queue: the providers read ReadView's
    // @State (currentSelectedSurface(), surfaceReadingData, segmentEdges, text…). Under this
    // project's SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, those closures are @MainActor-isolated
    // and carry a dispatch_assert_queue(main) precondition. The previous version dispatched them
    // onto `providerQueue` (background); the very first provider call then tripped that assertion
    // → SIGTRAP on EVERY tap. ProviderBox/@unchecked Sendable silenced the COMPILE-time isolation
    // check but not the RUNTIME assert. Slowness and isolation are orthogonal: this data must be
    // read on the main actor. The heavy dictionary lookups inside (lexicon/segmenter/
    // DictionaryStore) are themselves nonisolated and could be split off-main later on a plain
    // snapshot if timing proves it necessary — see the per-provider timings logged below.
    func refreshSheetSupplementalDataAsync(completion: @escaping @MainActor @Sendable () -> Void) {
        refreshGeneration += 1
        let generation = refreshGeneration

        TapDiagnostics.mark("refreshSheetSupplementalDataAsync scheduled (gen=\(generation))")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.refreshGeneration == generation else {
                    TapDiagnostics.mark("refresh: gen=\(generation) discarded as stale (current=\(self.refreshGeneration))")
                    return
                }

                // Per-provider timing so we can SEE whether any provider exceeds a frame budget
                // (~16ms) on a real device. If one consistently does, that's the candidate for a
                // snapshot-on-main / compute-off-main split; until then, on-main keeps it simple
                // and crash-free.
                func timed<T>(_ label: String, _ work: () -> T) -> T {
                    let start = CFAbsoluteTimeGetCurrent()
                    let result = work()
                    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    TapDiagnostics.mark(String(format: "provider %@ took %.1fms", label, ms))
                    return result
                }

                let overallStart = CFAbsoluteTimeGetCurrent()
                let readings = timed("readings") { self.sheetReadingsProvider?() ?? [] }
                let sublattice = timed("sublattice") { self.sheetSublatticeProvider?() ?? [] }
                let frequency = timed("frequency") { self.sheetFrequencyProvider?() }
                let lemmaInfo = timed("lemmaInfo") { self.sheetLemmaInfoProvider?() }
                let lemmaInfoByReading = timed("lemmaInfoByReading") { self.sheetLemmaInfoByReadingProvider?() ?? [:] }
                let dictionaryEntry = timed("dictionaryEntry") { self.sheetDictionaryEntryProvider?() }
                let compoundComponents = timed("compoundComponents") { self.sheetCompoundComponentsProvider?() ?? [] }

                self.currentSheetUniqueReadings = readings
                self.currentSheetSublatticeEdges = sublattice
                self.currentSheetFrequencyByReading = frequency
                self.currentSheetLemmaInfo = lemmaInfo
                self.currentSheetLemmaInfoByReading = lemmaInfoByReading
                self.currentSheetDictionaryEntry = self.entryMatchingDisplayedReading(
                    readings: readings,
                    readingMap: lemmaInfoByReading,
                    fallback: dictionaryEntry
                )
                self.currentSheetLexiconDebugInfo = ""
                self.currentSheetWordComponents = []
                self.currentSheetCompoundComponents = compoundComponents

                let totalMs = (CFAbsoluteTimeGetCurrent() - overallStart) * 1000
                TapDiagnostics.mark(String(format: "refresh: all providers done in %.1fms (gen=%d)", totalMs, generation))
                completion()
            }
        }
    }

    // Synchronous fallback retained for tests and any caller that genuinely needs the data
    // to be in place before the function returns. NOT recommended for the hot tap path —
    // prefer `refreshSheetSupplementalDataAsync` so the main thread can keep painting.
    func refreshSheetSupplementalData() {
        refreshGeneration += 1
        currentSheetUniqueReadings = sheetReadingsProvider?() ?? []
        currentSheetSublatticeEdges = sheetSublatticeProvider?() ?? []
        currentSheetFrequencyByReading = sheetFrequencyProvider?()
        currentSheetLemmaInfo = sheetLemmaInfoProvider?()
        currentSheetLemmaInfoByReading = sheetLemmaInfoByReadingProvider?() ?? [:]
        currentSheetDictionaryEntry = entryMatchingDisplayedReading(
            readings: currentSheetUniqueReadings,
            readingMap: currentSheetLemmaInfoByReading,
            fallback: sheetDictionaryEntryProvider?()
        )
        currentSheetLexiconDebugInfo = ""
        currentSheetWordComponents = []
        currentSheetCompoundComponents = sheetCompoundComponentsProvider?() ?? []
    }

    // Delivers and clears one-shot dismissal callback used by the read view to clear selection state.
    func fireOnDismissIfNeeded() {
        guard let onDismiss else {
            return
        }

        self.onDismiss = nil
        onDismiss()
    }

    // Routes horizontal sheet swipe gestures to the current selection-navigation callbacks.
    @objc func handleSheetSwipe(_ gestureRecognizer: UISwipeGestureRecognizer) {
        switch gestureRecognizer.direction {
            case .left: onSheetSelectNext?()
            case .right: onSheetSelectPrevious?()
            default: break
        }
    }

    // Generates initial left and right segment groups for split mode from the tapped surface text.
    func initialSplitSegments(for surface: String) -> (left: [String], right: [String]) {
        let allSegments = segmentizeSurface(surface)
        if allSegments.isEmpty {
            return (left: [surface], right: [])
        }

        if allSegments.count == 1 {
            return (left: [allSegments[0]], right: [])
        }

        return (left: [allSegments[0]], right: Array(allSegments.dropFirst()))
    }

    // Splits surface text into segment units for transfer between split inputs.
    func segmentizeSurface(_ surface: String) -> [String] {
        let whitespaceSegments = surface
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)

        if whitespaceSegments.isEmpty == false {
            return whitespaceSegments
        }

        return surface.map { String($0) }
    }

    // Delegates to the shared static implementation on LatticeEdge.
    func sublatticeValidPaths(from edges: [LatticeEdge]) -> [[String]] {
        LatticeEdge.validPaths(from: edges)
    }

    // Rebuilds one segment row with tappable chip buttons that transfer segments across split inputs.
    func rebuildSegmentRow(
        _ row: UIStackView,
        segments: [String],
        onSegmentPressed: @escaping (String) -> Void
    ) {
        row.arrangedSubviews.forEach { arrangedSubview in
            row.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        if segments.isEmpty {
            let placeholder = UILabel()
            placeholder.text = "—"
            placeholder.textColor = .tertiaryLabel
            placeholder.font = .systemFont(ofSize: 13)
            row.addArrangedSubview(placeholder)
            return
        }

        for segment in segments {
            let segmentButton = UIButton(type: .system)
            segmentButton.setTitle(segment, for: .normal)
            segmentButton.setTitleColor(.label, for: .normal)
            segmentButton.titleLabel?.font = .systemFont(ofSize: 13)
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            segmentButton.configuration = configuration
            segmentButton.backgroundColor = UIColor.secondarySystemFill
            segmentButton.layer.cornerRadius = 8
            segmentButton.addAction(
                UIAction { _ in
                    onSegmentPressed(segment)
                },
                for: .touchUpInside
            )
            row.addArrangedSubview(segmentButton)
        }
    }

}
