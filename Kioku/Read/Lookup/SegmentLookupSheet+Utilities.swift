import UIKit

extension SegmentLookupSheet {
    // Refreshes all supplemental data for the current sheet from its registered providers.
    func refreshSheetSupplementalData() {
        currentSheetUniqueReadings = sheetReadingsProvider?() ?? []
        currentSheetSublatticeEdges = sheetSublatticeProvider?() ?? []
        currentSheetFrequencyByReading = sheetFrequencyProvider?()
        currentSheetLemmaInfo = sheetLemmaInfoProvider?()
        currentSheetDictionaryEntry = sheetDictionaryEntryProvider?()
        currentSheetLexiconDebugInfo = ""
        currentSheetWordComponents = []
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
