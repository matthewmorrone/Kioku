import UIKit
import AVFoundation

// Presents a native UIKit popover anchored to tapped segment rects in the read-mode text view.
final class SegmentLookupSheet: NSObject, UIPopoverPresentationControllerDelegate, UIAdaptivePresentationControllerDelegate, UISheetPresentationControllerDelegate {
    static let shared = SegmentLookupSheet()
    // Key for retaining the tap handler via associated objects (gesture recognizer holds weak ref).
    static var tapHandlerKey: UInt8 = 0
    // Key for retaining the speech synthesizer so it lives long enough to finish speaking.
    static var speechSynthesizerKey: UInt8 = 0

    private weak var presentedController: UIViewController?
    // Reusable popover content views + live provider closures, populated by reallyPresentPopover
    // and mutated in place by updatePresentedPopoverContent when switching between words while a
    // popover is already showing. Button actions read through these (not captured closure
    // parameters) so they always call the CURRENT word's providers even after reuse — see
    // presentPopover's comment for why dismiss+present must be avoided for that case.
    private weak var popoverStarButton: UIButton?
    private weak var popoverWordButton: UIButton?
    private weak var popoverDefinitionLabel: UILabel?
    private var popoverIsSavedProvider: (() -> Bool)?
    private var popoverIsSavedElsewhereProvider: (() -> Bool)?
    private var popoverOnSaveToggle: (() -> Void)?
    // Powers the star's long-press learned-state menu, mirroring the Words tab's star.
    private var popoverLearnedStateProvider: (() -> LearnedState)?
    private var popoverOnSetLearnedState: ((LearnedState) -> Void)?
    private var popoverOnEscalate: (() -> Void)?
    private var popoverSurface: String = ""
    private static let popoverHorizontalInset: CGFloat = 10
    private static let popoverTopInset: CGFloat = 4
    private static let popoverBottomInset: CGFloat = 8
    private static let popoverInterItemSpacing: CGFloat = 8
    // Apple HIG minimum tappable target — the star/arrow icons themselves stay small (rendered
    // at the default SF Symbol point size), this just pads their tap area.
    private static let popoverActionButtonSize: CGFloat = 44
    private static let popoverMinWordTapWidth: CGFloat = 44
    weak var presentedSheetController: UIViewController?
    // True once the app's frequency maps have finished loading. The split readout shows a loading
    // state (not misleading zeros) until this flips; ReadView sets it at present time and on resource-ready.
    var frequencyResourcesReady = false
    private var isPreparingSheetDismissal = false
    // Incremented on every refresh request. The deferred main-actor block captures the generation
    // it was scheduled at and only writes `currentSheet*` properties when the captured
    // value still matches — this is how a fast second tap throws away the first tap's
    // results instead of letting them overwrite the now-correct sheet.
    var refreshGeneration: Int = 0
    var onDismiss: (() -> Void)?
    var onWillDismiss: ((@escaping () -> Void) -> Void)?
    var onReadingSelected: ((String) -> Void)?
    // Called when the user taps the reset button to clear the current reading override.
    var onReadingReset: (() -> Void)?
    var onSheetSelectPrevious: (() -> Void)?
    var onSheetSelectNext: (() -> Void)?
    var sheetReadingsProvider: (() -> [String])?
    var sheetSublatticeProvider: (() -> [LatticeEdge])?
    var segmentRangeProvider: (() -> NSRange?)?
    var sheetLexiconDebugProvider: (() -> String)?
    var sheetFrequencyProvider: (() -> [String: FrequencyData]?)?
    // Provides lemma and inflection chain when the current surface is an inflected form distinct from its base.
    var sheetLemmaInfoProvider: (() -> (lemma: String, chain: [String])?)?
    // Provides a per-reading map of lemma + dictionary entry. The arrow controls cycle through
    // currentSheetUniqueReadings; when the user lands on a reading that belongs to a different
    // admitted lemma (e.g. cycling between さわる/触る and ふれる/触れる for 触れられない), the sheet
    // uses this map to refresh currentSheetLemmaInfo and currentSheetDictionaryEntry so the lemma
    // label and gloss panel follow the selected reading.
    var sheetLemmaInfoByReadingProvider: (() -> [String: (lemma: String, chain: [String], entry: DictionaryEntry?)])?
    // Returns the currently persisted reading override for the selected segment, if any.
    var activeReadingOverrideProvider: (() -> String?)?
    // Looks up frequency data for any surface in the note — used to annotate sublattice paths.
    var pathSegmentFrequencyProvider: ((String) -> [String: FrequencyData]?)?
    // Provides the minimal dictionary entry needed to render visible senses for the current segment.
    var sheetDictionaryEntryProvider: (() -> DictionaryEntry?)?
    var currentSheetDictionaryEntry: DictionaryEntry? = nil
    // Returns true when the current segment's resolved lemma is already saved.
    var sheetIsSavedProvider: (() -> Bool)?
    // Returns true when the lemma is saved but attributed only to OTHER notes — the
    // hollow-yellow star state, mirroring the extract-words list (shape = saved for this
    // note, color = saved anywhere).
    var sheetIsSavedElsewhereProvider: (() -> Bool)?
    // Toggles the saved state for the current segment's resolved lemma.
    var sheetSaveToggle: (() -> Void)?
    // Powers the save button's long-press learned-state menu, mirroring the Words tab's star.
    var sheetLearnedStateProvider: (() -> LearnedState)?
    var sheetSetLearnedState: ((LearnedState) -> Void)?
    // Opens the word detail screen for the current segment's resolved lemma.
    var sheetOpenWordDetail: (() -> Void)?
    // Provides tappable word components: (surface, first gloss) pairs.
    var sheetWordComponentsProvider: (() -> [(surface: String, gloss: String?)]?)?
    var currentSheetWordComponents: [(surface: String, gloss: String?)] = []
    // Provides compound verb component lemmas: (lemma, first gloss) pairs.
    var sheetCompoundComponentsProvider: (() -> [(lemma: String, gloss: String?)]?)?
    var currentSheetCompoundComponents: [(lemma: String, gloss: String?)] = []
    // Called when the user taps a compound component row to drill into that lemma.
    // ReadView installs this to present a nested full-chrome lookup sheet.
    // Falls back to the legacy minimal popover when nil.
    var onCompoundComponentTapped: ((_ lemma: String, _ gloss: String?) -> Void)?
    var currentSheetUniqueReadings: [String] = []
    var currentSheetSublatticeEdges: [LatticeEdge] = []
    var currentSheetLexiconDebugInfo: String = ""
    var currentSheetFrequencyByReading: [String: FrequencyData]? = nil
    var currentSheetLemmaInfo: (lemma: String, chain: [String])? = nil
    var currentSheetLemmaInfoByReading: [String: (lemma: String, chain: [String], entry: DictionaryEntry?)] = [:]
    var updatePresentedSheetSelection: ((
        String,
        String?,
        String?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        ((Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> [String])?,
        (() -> [LatticeEdge])?,
        (() -> NSRange?)?,
        (() -> String)?,
        (() -> [String: FrequencyData]?)?,
        (() -> Void)?
    ) -> Void)?

    // The shared singleton coordinates the primary segment-anchored popover/sheet. Nested
    // lookups (e.g. tapping a compound component) build their own instances so their state
    // doesn't clobber the parent sheet sitting underneath them.
    override init() {
        super.init()
    }

    private var hasActivePresentedSheetController: Bool {
        guard let presentedSheetController else {
            return false
        }

        return presentedSheetController.isBeingDismissed == false
            && (presentedSheetController.presentingViewController != nil || presentedSheetController.viewIfLoaded?.window != nil)
    }

    private var hasActivePresentedPopoverController: Bool {
        guard let presentedController else {
            return false
        }

        return presentedController.isBeingDismissed == false
            && (presentedController.presentingViewController != nil || presentedController.viewIfLoaded?.window != nil)
    }

    // Presents the current definition in a UIKit popover anchored to the tapped segment rectangle.
    // Row layout: star (favorite toggle) — word (tap to speak) — definition — chevron (escalate
    // to the full sheet). isSavedProvider/isSavedElsewhereProvider/onSaveToggle mirror the same
    // three-state star contract presentSheet's action-bar save button uses, so the popover and the
    // full sheet can never disagree about a word's saved state.
    //
    // onEscalate, not a self-built presentSurfaceSheet call: the popover has no access to the
    // rich provider set (readings, sublattice, frequency, lemma info, ...) that only ReadView can
    // build — an earlier version of this method tried to read those off `self.sheetReadingsProvider`
    // etc., which are only ever populated by presentSheet's own full call, so the escalated sheet
    // rendered empty. The caller supplies onEscalate to open the SAME full sheet the direct-tap
    // path already knows how to build correctly.
    func presentPopover(
        definition: String,
        surface: String,
        isSavedProvider: (() -> Bool)? = nil,
        isSavedElsewhereProvider: (() -> Bool)? = nil,
        onSaveToggle: (() -> Void)? = nil,
        learnedStateProvider: (() -> LearnedState)? = nil,
        onSetLearnedState: ((LearnedState) -> Void)? = nil,
        onEscalate: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        sourceView: UIView,
        sourceRect: CGRect
    ) {
        self.onDismiss = onDismiss

        // Reusing an already-presented popover in place skips UIKit's dismiss+present transitions
        // entirely for the common case of tapping a different word while one is already showing.
        // Measured via TapDiagnostics: dismiss(animated: false) does NOT skip its transition
        // duration for .popover-style presentations (~280ms even unanimated), and the replacement
        // present(animated: true) adds another ~500ms on top — the better part of a second per
        // switch. Updating content + sourceRect on the same view controller avoids both costs.
        if hasActivePresentedPopoverController, let presentedController {
            TapDiagnostics.mark("presentPopover: reusing already-presented popover in place")
            updatePresentedPopoverContent(
                viewController: presentedController,
                definition: definition,
                surface: surface,
                isSavedProvider: isSavedProvider,
                isSavedElsewhereProvider: isSavedElsewhereProvider,
                onSaveToggle: onSaveToggle,
                learnedStateProvider: learnedStateProvider,
                onSetLearnedState: onSetLearnedState,
                onEscalate: onEscalate,
                sourceView: sourceView,
                sourceRect: sourceRect
            )
            return
        }

        // dismissPopover's own dismiss(animated:) is asynchronous — presenting a new popover
        // before that animation completes gets silently dropped by UIKit (it ignores a present()
        // call issued while the presenting controller is still mid-transition), which is why
        // tapping a second word while a popover is up needed 2-3 taps before anything appeared.
        // Deferring the rest of this method to the dismissal's completion closes that gap. (No
        // active popover to reuse here, so this only runs dismissSheet's own — usually instant —
        // cleanup before the fresh build.)
        TapDiagnostics.mark("presentPopover entered, dismissing any prior popover")
        dismissPopover(notifyDismissal: false, animated: false) { [weak self] in
            TapDiagnostics.mark("presentPopover: prior dismiss completed, calling reallyPresentPopover")
            self?.reallyPresentPopover(
                definition: definition,
                surface: surface,
                isSavedProvider: isSavedProvider,
                isSavedElsewhereProvider: isSavedElsewhereProvider,
                onSaveToggle: onSaveToggle,
                learnedStateProvider: learnedStateProvider,
                onSetLearnedState: onSetLearnedState,
                onEscalate: onEscalate,
                sourceView: sourceView,
                sourceRect: sourceRect
            )
        }
    }

    // Updates an already-presented popover's content and anchor in place — see presentPopover.
    private func updatePresentedPopoverContent(
        viewController: UIViewController,
        definition: String,
        surface: String,
        isSavedProvider: (() -> Bool)?,
        isSavedElsewhereProvider: (() -> Bool)?,
        onSaveToggle: (() -> Void)?,
        learnedStateProvider: (() -> LearnedState)?,
        onSetLearnedState: ((LearnedState) -> Void)?,
        onEscalate: (() -> Void)?,
        sourceView: UIView,
        sourceRect: CGRect
    ) {
        popoverSurface = surface
        popoverIsSavedProvider = isSavedProvider
        popoverIsSavedElsewhereProvider = isSavedElsewhereProvider
        popoverOnSaveToggle = onSaveToggle
        popoverLearnedStateProvider = learnedStateProvider
        popoverOnSetLearnedState = onSetLearnedState
        popoverOnEscalate = onEscalate

        applyPopoverWordButtonAppearance(surface: surface)
        popoverDefinitionLabel?.text = definition
        refreshPopoverStarAppearance()

        viewController.preferredContentSize = preferredPopoverSize(
            for: definition,
            word: DictionarySettings.showJapaneseInPopover ? surface : "",
            horizontalInset: Self.popoverHorizontalInset,
            topInset: Self.popoverTopInset,
            bottomInset: Self.popoverBottomInset,
            interItemSpacing: Self.popoverInterItemSpacing,
            actionButtonWidth: Self.popoverActionButtonSize,
            actionButtonHeight: Self.popoverActionButtonSize,
            minWordTapWidth: Self.popoverMinWordTapWidth
        )

        // Documented behavior: changing sourceRect/sourceView on an already-presented
        // UIPopoverPresentationController repositions the arrow to match.
        if let popoverPresentationController = viewController.popoverPresentationController {
            popoverPresentationController.sourceView = sourceView
            popoverPresentationController.sourceRect = sourceRect
        }
        TapDiagnostics.mark("updatePresentedPopoverContent: content + anchor updated in place")
    }

    // Refreshes the star's icon/tint/accessibility label from the live saved state — shared by
    // the initial render and every post-toggle/post-switch refresh so they can't drift apart,
    // mirroring SurfaceSheetViewController.updateSaveButtonAppearance().
    private func refreshPopoverStarAppearance() {
        let isSaved = popoverIsSavedProvider?() ?? false
        let isSavedElsewhere = isSaved == false && (popoverIsSavedElsewhereProvider?() ?? false)
        let learnedState = popoverLearnedStateProvider?() ?? .unmarked
        let icon: String
        switch learnedState {
        case .learned:    icon = "checkmark"
        case .notLearned: icon = "questionmark"
        case .unmarked:   icon = isSaved ? "star.fill" : "star"
        }
        popoverStarButton?.setImage(UIImage(systemName: icon), for: .normal)
        popoverStarButton?.tintColor = (learnedState != .unmarked || isSaved || isSavedElsewhere) ? .systemYellow : .secondaryLabel
        popoverStarButton?.accessibilityLabel = isSaved ? "Unsave" : (isSavedElsewhere ? "Save to This Note" : "Save")
        // Rebuilt on every refresh (not set once) so the menu's setState closure always targets
        // the currently-shown word — see the class-level comment on why this popover is reused
        // in place rather than torn down and rebuilt when the user switches words.
        if let onSetLearnedState = popoverOnSetLearnedState {
            // The mark is applied (and the glyph refreshed) on the next runloop rather than inline:
            // a synchronous write lands while UIKit is still tearing the menu down, which delays the
            // resulting icon change by a beat — same reasoning as learnedStateSetter.
            popoverStarButton?.menu = learnedStateUIMenu(currentState: learnedState) { [weak self] state in
                DispatchQueue.main.async {
                    onSetLearnedState(state)
                    self?.refreshPopoverStarAppearance()
                }
            }
            popoverStarButton?.showsMenuAsPrimaryAction = false
        } else {
            popoverStarButton?.menu = nil
        }
    }

    // Renders the word button per the "Show Japanese in Popover" setting — either the surface
    // text (current default) or a plain speaker icon, so users who don't want the word spoiled
    // can still tap to hear it. Shared by the fresh-build and update-in-place paths so they can't
    // drift apart.
    private func applyPopoverWordButtonAppearance(surface: String) {
        guard let popoverWordButton else { return }
        popoverWordButton.accessibilityLabel = "Speak \(surface)"
        if DictionarySettings.showJapaneseInPopover {
            popoverWordButton.setImage(nil, for: .normal)
            popoverWordButton.setAttributedTitle(
                NSAttributedString(
                    string: surface,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: UIColor.label,
                    ]
                ),
                for: .normal
            )
        } else {
            popoverWordButton.setAttributedTitle(NSAttributedString(string: ""), for: .normal)
            popoverWordButton.setImage(UIImage(systemName: "speaker.wave.2"), for: .normal)
            popoverWordButton.tintColor = .secondaryLabel
        }
    }

    // The actual popover construction + presentation, deferred until any prior popover has
    // fully finished dismissing (see presentPopover's comment).
    private func reallyPresentPopover(
        definition: String,
        surface: String,
        isSavedProvider: (() -> Bool)?,
        isSavedElsewhereProvider: (() -> Bool)?,
        onSaveToggle: (() -> Void)?,
        learnedStateProvider: (() -> LearnedState)?,
        onSetLearnedState: ((LearnedState) -> Void)?,
        onEscalate: (() -> Void)?,
        sourceView: UIView,
        sourceRect: CGRect
    ) {
        guard let presentingController = topPresentingController() else {
            TapDiagnostics.mark("reallyPresentPopover: topPresentingController() returned nil — BAILING")
            return
        }
        TapDiagnostics.mark("reallyPresentPopover: presentingController resolved, building popover view")

        popoverSurface = surface
        popoverIsSavedProvider = isSavedProvider
        popoverIsSavedElsewhereProvider = isSavedElsewhereProvider
        popoverOnSaveToggle = onSaveToggle
        popoverLearnedStateProvider = learnedStateProvider
        popoverOnSetLearnedState = onSetLearnedState
        popoverOnEscalate = onEscalate

        let viewController = UIViewController()
        viewController.view.backgroundColor = .systemBackground

        let starButton = UIButton(type: .system)
        starButton.translatesAutoresizingMaskIntoConstraints = false
        starButton.contentVerticalAlignment = .center
        starButton.contentHorizontalAlignment = .center
        popoverStarButton = starButton
        refreshPopoverStarAppearance()
        starButton.addAction(
            UIAction { [weak self] _ in
                self?.popoverOnSaveToggle?()
                self?.refreshPopoverStarAppearance()
            },
            for: .touchUpInside
        )

        let wordButton = UIButton(type: .system)
        wordButton.translatesAutoresizingMaskIntoConstraints = false
        wordButton.setTitleColor(.label, for: .normal)
        wordButton.contentHorizontalAlignment = .leading
        popoverWordButton = wordButton
        // Dotted underline signals "tap to hear this" without adding a separate icon. Font must
        // be an attribute here, not set via titleLabel?.font — that's ignored once an attributed
        // title is in play, which previously let the button fall back to a different font than
        // preferredPopoverSize measured, under-sizing the popover and forcing definitionLabel to
        // wrap character-by-character.
        applyPopoverWordButtonAppearance(surface: surface)
        // Reads popoverSurface (not a captured `surface` snapshot) so a reused, in-place-updated
        // popover always speaks the currently-shown word, not whichever word first built this button.
        wordButton.addAction(
            UIAction { [weak self, weak wordButton] _ in
                guard let self else { return }
                let synthesizer = AVSpeechSynthesizer()
                objc_setAssociatedObject(wordButton as Any, &SegmentLookupSheet.speechSynthesizerKey, synthesizer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                let utterance = AVSpeechUtterance(string: self.popoverSurface)
                utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
                synthesizer.speak(utterance)
            },
            for: .touchUpInside
        )

        let definitionLabel = UILabel()
        definitionLabel.translatesAutoresizingMaskIntoConstraints = false
        definitionLabel.numberOfLines = 2
        definitionLabel.lineBreakMode = .byTruncatingTail
        definitionLabel.textColor = .label
        definitionLabel.font = .systemFont(ofSize: 16)
        definitionLabel.text = definition
        popoverDefinitionLabel = definitionLabel

        let detailsButton = UIButton(type: .system)
        detailsButton.translatesAutoresizingMaskIntoConstraints = false
        detailsButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        detailsButton.tintColor = .secondaryLabel
        detailsButton.contentVerticalAlignment = .center
        detailsButton.contentHorizontalAlignment = .center
        detailsButton.accessibilityLabel = "Open Full Lookup"
        detailsButton.addAction(
            UIAction { [weak self] _ in
                guard let self else {
                    return
                }
                // Dismiss first (matching presentSheet's own dismiss-before-fresh-present
                // pattern), then hand off to the caller, which builds and presents the full
                // sheet with its complete provider set.
                self.dismissPopover(notifyDismissal: false) { [weak self] in
                    self?.popoverOnEscalate?()
                }
            },
            for: .touchUpInside
        )

        viewController.view.addSubview(starButton)
        viewController.view.addSubview(wordButton)
        viewController.view.addSubview(definitionLabel)
        viewController.view.addSubview(detailsButton)
        NSLayoutConstraint.activate([
            starButton.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor, constant: Self.popoverHorizontalInset),
            starButton.centerYAnchor.constraint(equalTo: definitionLabel.centerYAnchor),
            starButton.widthAnchor.constraint(equalToConstant: Self.popoverActionButtonSize),
            starButton.heightAnchor.constraint(equalToConstant: Self.popoverActionButtonSize),

            wordButton.leadingAnchor.constraint(equalTo: starButton.trailingAnchor, constant: Self.popoverInterItemSpacing),
            wordButton.centerYAnchor.constraint(equalTo: definitionLabel.centerYAnchor),
            wordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.popoverMinWordTapWidth),
            wordButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.popoverActionButtonSize),

            definitionLabel.topAnchor.constraint(equalTo: viewController.view.topAnchor, constant: Self.popoverTopInset),
            definitionLabel.leadingAnchor.constraint(equalTo: wordButton.trailingAnchor, constant: Self.popoverInterItemSpacing),
            definitionLabel.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor, constant: -Self.popoverBottomInset),

            detailsButton.leadingAnchor.constraint(equalTo: definitionLabel.trailingAnchor, constant: Self.popoverInterItemSpacing),
            detailsButton.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor, constant: -Self.popoverHorizontalInset),
            detailsButton.centerYAnchor.constraint(equalTo: definitionLabel.centerYAnchor),
            detailsButton.widthAnchor.constraint(equalToConstant: Self.popoverActionButtonSize),
            detailsButton.heightAnchor.constraint(equalToConstant: Self.popoverActionButtonSize),
        ])

        viewController.modalPresentationStyle = .popover
        viewController.preferredContentSize = preferredPopoverSize(
            for: definition,
            word: DictionarySettings.showJapaneseInPopover ? surface : "",
            horizontalInset: Self.popoverHorizontalInset,
            topInset: Self.popoverTopInset,
            bottomInset: Self.popoverBottomInset,
            interItemSpacing: Self.popoverInterItemSpacing,
            actionButtonWidth: Self.popoverActionButtonSize,
            actionButtonHeight: Self.popoverActionButtonSize,
            minWordTapWidth: Self.popoverMinWordTapWidth
        )

        guard let popoverPresentationController = viewController.popoverPresentationController else {
            TapDiagnostics.mark("reallyPresentPopover: viewController.popoverPresentationController is nil — BAILING")
            return
        }

        popoverPresentationController.delegate = self
        popoverPresentationController.sourceView = sourceView
        popoverPresentationController.sourceRect = sourceRect
        popoverPresentationController.permittedArrowDirections = [.up, .down]
        // Without this, UIKit's own outside-tap-to-dismiss overlay swallows the first tap on a
        // different word — the CoreText view's tap gesture recognizer never sees it, so the
        // popover just dismisses and the second tap is what actually opens the new word's
        // popover. Exempting the source view from that overlay lets taps reach the gesture
        // recognizer directly, so handleReadModeSegmentTap runs immediately and this same
        // presentPopover call switches straight to the new word.
        popoverPresentationController.passthroughViews = [sourceView]

        TapDiagnostics.mark("reallyPresentPopover: calling presentingController.present(...)")
        presentingController.present(viewController, animated: true) {
            TapDiagnostics.mark("reallyPresentPopover: present(...) completion fired — popover is now on screen")
        }
        presentedController = viewController
    }

    // Presents the segment action sheet directly without first showing a popover.
    func presentSheet(
        surface: String,
        leftNeighborSurface: String?,
        rightNeighborSurface: String?,
        onSelectPrevious: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onSelectNext: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onMergeLeft: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onMergeRight: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onSplitApply: ((Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        sheetReadingsProvider: (() -> [String])? = nil,
        sheetSublatticeProvider: (() -> [LatticeEdge])? = nil,
        segmentRangeProvider: (() -> NSRange?)? = nil,
        sheetLexiconDebugProvider: (() -> String)? = nil,
        sheetFrequencyProvider: (() -> [String: FrequencyData]?)? = nil,
        sheetLemmaInfoProvider: (() -> (lemma: String, chain: [String])?)? = nil,
        sheetLemmaInfoByReadingProvider: (() -> [String: (lemma: String, chain: [String], entry: DictionaryEntry?)])? = nil,
        onReadingSelected: ((String) -> Void)? = nil,
        onReadingReset: (() -> Void)? = nil,
        activeReadingOverrideProvider: (() -> String?)? = nil,
        pathSegmentFrequencyProvider: ((String) -> [String: FrequencyData]?)? = nil,
        sheetDictionaryEntryProvider: (() -> DictionaryEntry?)? = nil,
        sheetIsSavedProvider: (() -> Bool)? = nil,
        sheetIsSavedElsewhereProvider: (() -> Bool)? = nil,
        sheetSaveToggle: (() -> Void)? = nil,
        sheetLearnedStateProvider: (() -> LearnedState)? = nil,
        sheetSetLearnedState: ((LearnedState) -> Void)? = nil,
        sheetOpenWordDetail: (() -> Void)? = nil,
        sheetWordComponentsProvider: (() -> [(surface: String, gloss: String?)]?)? = nil,
        sheetCompoundComponentsProvider: (() -> [(lemma: String, gloss: String?)]?)? = nil,
        onWillDismiss: ((@escaping () -> Void) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        TapDiagnostics.mark("presentSheet entered (hasActive=\(hasActivePresentedSheetController), hasUpdater=\(updatePresentedSheetSelection != nil))")
        if hasActivePresentedSheetController == false, updatePresentedSheetSelection != nil {
            presentedSheetController = nil
            isPreparingSheetDismissal = false
            updatePresentedSheetSelection = nil
        }

        // Always update the reading callbacks so re-taps on a different segment get the right closures.
        self.onWillDismiss = onWillDismiss
        self.onReadingSelected = onReadingSelected
        self.onReadingReset = onReadingReset
        self.activeReadingOverrideProvider = activeReadingOverrideProvider
        self.pathSegmentFrequencyProvider = pathSegmentFrequencyProvider
        self.sheetLemmaInfoProvider = sheetLemmaInfoProvider
        self.sheetLemmaInfoByReadingProvider = sheetLemmaInfoByReadingProvider
        self.sheetDictionaryEntryProvider = sheetDictionaryEntryProvider
        self.sheetIsSavedProvider = sheetIsSavedProvider
        self.sheetIsSavedElsewhereProvider = sheetIsSavedElsewhereProvider
        self.sheetSaveToggle = sheetSaveToggle
        self.sheetLearnedStateProvider = sheetLearnedStateProvider
        self.sheetSetLearnedState = sheetSetLearnedState
        self.sheetOpenWordDetail = sheetOpenWordDetail
        self.sheetWordComponentsProvider = sheetWordComponentsProvider
        self.sheetCompoundComponentsProvider = sheetCompoundComponentsProvider
        if let updatePresentedSheetSelection, hasActivePresentedSheetController {
            TapDiagnostics.mark("presentSheet: taking IN-PLACE update path")
            self.onDismiss = onDismiss
            self.onWillDismiss = onWillDismiss
            updatePresentedSheetSelection(
                surface,
                leftNeighborSurface,
                rightNeighborSurface,
                onSelectPrevious,
                onSelectNext,
                onMergeLeft,
                onMergeRight,
                onSplitApply,
                sheetReadingsProvider,
                sheetSublatticeProvider,
                segmentRangeProvider,
                sheetLexiconDebugProvider,
                sheetFrequencyProvider,
                onDismiss
            )
            TapDiagnostics.mark("presentSheet: in-place update returned")
            return
        }

        TapDiagnostics.mark("presentSheet: taking FRESH-PRESENT path (this is normal on first tap)")
        self.onDismiss = onDismiss
        presentSurfaceSheet(
            surface: surface,
            leftNeighborSurface: leftNeighborSurface,
            rightNeighborSurface: rightNeighborSurface,
            onSelectPrevious: onSelectPrevious,
            onSelectNext: onSelectNext,
            onMergeLeft: onMergeLeft,
            onMergeRight: onMergeRight,
            onSplitApply: onSplitApply,
            sheetReadingsProvider: sheetReadingsProvider,
            sheetSublatticeProvider: sheetSublatticeProvider,
            segmentRangeProvider: segmentRangeProvider,
            sheetLexiconDebugProvider: sheetLexiconDebugProvider,
            sheetFrequencyProvider: sheetFrequencyProvider,
            onDismiss: onDismiss
        )
    }

    // Dismisses any active segment presentation (sheet/popover), used when selection clears.
    func dismissPopover(notifyDismissal: Bool = true, animated: Bool = true, completion: (() -> Void)? = nil) {
        TapDiagnostics.mark("dismissPopover entered, calling dismissSheet")
        dismissSheet { [weak self] in
            TapDiagnostics.mark("dismissPopover: dismissSheet completed")
            guard let self else {
                completion?()
                return
            }

            guard let presentedController else {
                TapDiagnostics.mark("dismissPopover: presentedController is nil, nothing to dismiss")
                if notifyDismissal {
                    self.fireOnDismissIfNeeded()
                }
                completion?()
                return
            }

            TapDiagnostics.mark("dismissPopover: calling presentedController.dismiss(animated: \(animated))")
            presentedController.dismiss(animated: animated) {
                TapDiagnostics.mark("dismissPopover: presentedController.dismiss(...) completion fired")
                if notifyDismissal {
                    self.fireOnDismissIfNeeded()
                }
                completion?()
            }
            self.presentedController = nil
        }
    }

    // Clears all sheet-specific provider closures and cached data so a new segment can be configured cleanly.
    private func resetSheetPresentationState() {
        isPreparingSheetDismissal = false
        onWillDismiss = nil
        onSheetSelectPrevious = nil
        onSheetSelectNext = nil
        onReadingSelected = nil
        onReadingReset = nil
        sheetReadingsProvider = nil
        sheetSublatticeProvider = nil
        segmentRangeProvider = nil
        sheetLexiconDebugProvider = nil
        sheetFrequencyProvider = nil
        sheetLemmaInfoProvider = nil
        sheetLemmaInfoByReadingProvider = nil
        activeReadingOverrideProvider = nil
        pathSegmentFrequencyProvider = nil
        sheetDictionaryEntryProvider = nil
        sheetIsSavedProvider = nil
        sheetIsSavedElsewhereProvider = nil
        sheetSaveToggle = nil
        sheetLearnedStateProvider = nil
        sheetSetLearnedState = nil
        sheetOpenWordDetail = nil
        sheetWordComponentsProvider = nil
        sheetCompoundComponentsProvider = nil
        currentSheetCompoundComponents = []
        // Note: onCompoundComponentTapped is intentionally NOT reset — it's installed once by
        // ReadView and represents how the app drills into a compound component, regardless of
        // which segment is currently presented.
        currentSheetUniqueReadings = []
        currentSheetSublatticeEdges = []
        currentSheetLexiconDebugInfo = ""
        currentSheetFrequencyByReading = nil
        currentSheetLemmaInfo = nil
        currentSheetLemmaInfoByReading = [:]
        currentSheetDictionaryEntry = nil
        currentSheetWordComponents = []
        currentSheetCompoundComponents = []
        updatePresentedSheetSelection = nil
    }

    // Dismisses the currently presented action sheet if one is active.
    private func dismissSheet(completion: (() -> Void)? = nil) {
        guard let presentedSheetController, hasActivePresentedSheetController else {
            TapDiagnostics.mark("dismissSheet: fast bail (no active presentedSheetController)")
            self.presentedSheetController = nil
            resetSheetPresentationState()
            completion?()
            return
        }

        if isPreparingSheetDismissal == false, let onWillDismiss {
            TapDiagnostics.mark("dismissSheet: SLOW PATH — deferring to onWillDismiss")
            isPreparingSheetDismissal = true
            onWillDismiss { [weak self] in
                self?.dismissSheet(completion: completion)
            }
            return
        }

        TapDiagnostics.mark("dismissSheet: SLOW PATH — calling presentedSheetController.dismiss(animated: true)")
        presentedSheetController.dismiss(animated: true) { [weak self] in
            guard let self else {
                completion?()
                return
            }

            self.presentedSheetController = nil
            self.resetSheetPresentationState()
            completion?()
        }
    }

    // Intercepts system-initiated sheet dismissal so the onWillDismiss hook runs before the sheet disappears.
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        guard presentedSheetController === presentationController.presentedViewController else {
            return true
        }

        guard isPreparingSheetDismissal == false, let onWillDismiss else {
            return true
        }

        isPreparingSheetDismissal = true
        onWillDismiss { [weak self] in
            self?.presentedSheetController?.dismiss(animated: true)
        }
        return false
    }

    // Clears tracked presentation references when users dismiss controllers interactively.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentedController === presentationController.presentedViewController {
            presentedController = nil
            fireOnDismissIfNeeded()
        }

        if presentedSheetController === presentationController.presentedViewController {
            presentedSheetController = nil
            resetSheetPresentationState()
            fireOnDismissIfNeeded()
        } else if updatePresentedSheetSelection != nil {
            presentedSheetController = nil
            resetSheetPresentationState()
            fireOnDismissIfNeeded()
        }
    }

    // Keeps popover style in compact environments so segment-anchored callouts retain the pointer arrow.
    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        return .none
    }

    // Computes a bounded content size for the star/word/definition/arrow row. Content-hugging:
    // a short word + short definition doesn't leave dead space, while a long definition wraps
    // to multiple lines once the row hits maxContentWidth rather than growing unbounded.
    private func preferredPopoverSize(
        for definition: String,
        word: String,
        horizontalInset: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        interItemSpacing: CGFloat,
        actionButtonWidth: CGFloat,
        actionButtonHeight: CGFloat,
        minWordTapWidth: CGFloat
    ) -> CGSize {
        let minContentWidth: CGFloat = 120
        let maxContentWidth: CGFloat = 320
        let definitionFont = UIFont.systemFont(ofSize: 16)
        let wordFont = UIFont.systemFont(ofSize: 17, weight: .semibold)

        let wordMeasurementLabel = UILabel()
        wordMeasurementLabel.font = wordFont
        wordMeasurementLabel.text = word
        // Must match wordButton's own greaterThanOrEqualToConstant(minWordTapWidth) constraint —
        // otherwise a short word (single kanji) is measured narrower than the button actually
        // renders, under-sizing the popover the same way the missing font attribute once did.
        let wordWidth = max(ceil(wordMeasurementLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ).width), minWordTapWidth)

        // Fixed-width elements: left/right insets, star, word, arrow, and the two inter-item
        // gaps between (star, word) and (word, definition) — definition's own leading gap to
        // the arrow is accounted for separately below.
        let fixedWidth = (horizontalInset * 2) + actionButtonWidth + interItemSpacing
            + wordWidth + interItemSpacing + interItemSpacing + actionButtonWidth

        let definitionMeasurementLabel = UILabel()
        definitionMeasurementLabel.numberOfLines = 0
        definitionMeasurementLabel.font = definitionFont
        definitionMeasurementLabel.text = definition

        let unconstrainedDefinitionSize = definitionMeasurementLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )

        let desiredContentWidth = ceil(unconstrainedDefinitionSize.width) + fixedWidth
        let constrainedContentWidth = min(max(desiredContentWidth, minContentWidth), maxContentWidth)
        let constrainedDefinitionWidth = constrainedContentWidth - fixedWidth
        let constrainedDefinitionSize = definitionMeasurementLabel.sizeThatFits(
            CGSize(width: max(constrainedDefinitionWidth, 1), height: CGFloat.greatestFiniteMagnitude)
        )

        let contentTextHeight = max(ceil(constrainedDefinitionSize.height), ceil(wordMeasurementLabel.sizeThatFits(
            CGSize(width: wordWidth, height: CGFloat.greatestFiniteMagnitude)
        ).height))
        let contentHeight = max(contentTextHeight, actionButtonHeight) + topInset + bottomInset
        return CGSize(width: constrainedContentWidth, height: max(56, min(contentHeight, 260)))
    }


    // Resolves the active screen bounds without relying on deprecated global UIScreen access.
    func activeScreenBounds() -> CGRect {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return CGRect(x: 0, y: 0, width: 390, height: 844)
        }

        return windowScene.screen.bounds
    }

    // Resolves the top-most view controller so popovers present from the active screen context.
    func topPresentingController() -> UIViewController? {
        guard
            let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else {
            return nil
        }

        var topController = rootViewController
        while let presentedController = topController.presentedViewController {
            topController = presentedController
        }

        return topController
    }

    // Formats one dictionary sense as "pos — gloss1; gloss2" for compact inline display.
    func formatSense(_ sense: DictionaryEntrySense) -> String {
        var parts: [String] = []
        if let pos = sense.pos, pos.isEmpty == false { parts.append(JMdictTagExpander.expand(pos)) }
        parts.append(sense.glosses.joined(separator: "; "))
        return parts.joined(separator: " — ")
    }
}
