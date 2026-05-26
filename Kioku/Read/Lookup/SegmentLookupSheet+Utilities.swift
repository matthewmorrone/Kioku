import UIKit

// Wraps a non-Sendable provider closure so it can ride into a @Sendable dispatch block.
// The closure stays PRIVATE to the box and is only invoked through the typed `call()` method,
// so the non-Sendable closure type never escapes the class — only its (Sendable) return value
// does. Swift 6 strict mode flagged the previous design (`let value: T` read directly with
// `box.value?()`) because reading the property re-exposed the non-Sendable closure type to
// the @Sendable closure that was reading it. This shape side-steps that check entirely.
//
// The providers themselves are constructed on MainActor (capturing MainActor state) but only
// read from nonisolated DictionaryStore / Lexicon, so invoking them on `providerQueue` is
// safe at runtime — the @unchecked Sendable annotation reflects that runtime safety.
nonisolated private final class ProviderBox<R>: @unchecked Sendable {
    private let closure: (() -> R)?
    init(_ closure: (() -> R)?) { self.closure = closure }
    // Returns the closure's result, or nil if the provider was nil. Never exposes the
    // closure itself, so the non-Sendable type doesn't cross the @Sendable boundary.
    func call() -> R? { closure?() }
}

extension SegmentLookupSheet {
    // Runs every supplemental provider on a background queue, applies the results on main,
    // then calls `completion` on main. The providers are synchronous and each can take many
    // hundreds of ms (full deinflection traversal + dictionary index hits), so blocking the
    // main thread on all six produced the multi-second pre-sheet stalls we observed in the
    // TAP instrumentation. Stale results from a superseded tap are dropped via the
    // generation counter, so the sheet never flashes back to old content after the user
    // already moved to a new word.
    func refreshSheetSupplementalDataAsync(completion: @escaping @MainActor @Sendable () -> Void) {
        refreshGeneration += 1
        let generation = refreshGeneration
        let readingsProvider = ProviderBox(sheetReadingsProvider)
        let sublatticeProvider = ProviderBox(sheetSublatticeProvider)
        let frequencyProvider = ProviderBox(sheetFrequencyProvider)
        let lemmaInfoProvider = ProviderBox(sheetLemmaInfoProvider)
        let lemmaInfoByReadingProvider = ProviderBox(sheetLemmaInfoByReadingProvider)
        let dictionaryEntryProvider = ProviderBox(sheetDictionaryEntryProvider)
        let compoundComponentsProvider = ProviderBox(sheetCompoundComponentsProvider)

        TapDiagnostics.mark("refreshSheetSupplementalDataAsync dispatched (gen=\(generation))")
        providerQueue.async { [weak self] in
            let readings = readingsProvider.call() ?? []
            let sublattice = sublatticeProvider.call() ?? []
            let frequency = frequencyProvider.call() ?? nil
            let lemmaInfo = lemmaInfoProvider.call() ?? nil
            let lemmaInfoByReading = lemmaInfoByReadingProvider.call() ?? [:]
            let dictionaryEntry = dictionaryEntryProvider.call() ?? nil
            // Double-coalesce: compoundComponentsProvider's closure itself returns `[(...)]?`,
            // and call() wraps that in another optional, so we need to flatten twice. Parens
            // force left-to-right associativity — `??` is right-associative by default.
            let compoundComponents = (compoundComponentsProvider.call() ?? nil) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.refreshGeneration == generation else {
                        TapDiagnostics.mark("refresh: gen=\(generation) discarded as stale (current=\(self.refreshGeneration))")
                        return
                    }
                    self.currentSheetUniqueReadings = readings
                    self.currentSheetSublatticeEdges = sublattice
                    self.currentSheetFrequencyByReading = frequency
                    self.currentSheetLemmaInfo = lemmaInfo
                    self.currentSheetLemmaInfoByReading = lemmaInfoByReading
                    self.currentSheetDictionaryEntry = dictionaryEntry
                    self.currentSheetLexiconDebugInfo = ""
                    self.currentSheetWordComponents = []
                    self.currentSheetCompoundComponents = compoundComponents
                    TapDiagnostics.mark("refresh: applied to main (gen=\(generation))")
                    completion()
                }
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
        currentSheetDictionaryEntry = sheetDictionaryEntryProvider?()
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
