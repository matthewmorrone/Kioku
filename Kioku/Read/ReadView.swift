import SwiftUI
import UIKit

// Provides the primary reading and editing surface for an active note.
struct ReadView: View {
    @Binding var selectedNote: Note?
    @EnvironmentObject var notesStore: NotesStore
    let segmenter: Segmenter
    let dictionaryStore: DictionaryStore?
    let readingBySurface: [String: String]
    let readingCandidatesBySurface: [String: [String]]
    let segmenterRevision: Int
    let readResourcesReady: Bool
    var onActiveNoteChanged: ((UUID) -> Void)? = nil

    @AppStorage(TypographySettings.textSizeKey)
    private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey) 
    private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey) 
    private var kerning = TypographySettings.defaultKerning
    @AppStorage("kioku.settings.showFurigana")
    private var isFuriganaVisible = true
    @AppStorage("kioku.settings.colorAlternation")
    private var isColorAlternationEnabled = true
    @AppStorage("kioku.settings.highlightUnknown")
    private var isHighlightUnknownEnabled = false
    @AppStorage("kioku.settings.applyGlobally")
    var shouldApplyChangesGlobally = false
    @AppStorage("kioku.settings.lineWrapping")
    private var isLineWrappingEnabled = true

    @State var customTitle = ""
    @State var fallbackTitle = ""
    @State private var titleDraft = ""
    @State private var isShowingTitleAlert = false
    @State var text = ""
    @State var segmentationEdges: [LatticeEdge] = []
    @State var segmentationRanges: [Range<String.Index>] = []
    @State var selectedSegmentLocation: Int?
    @State var selectedHighlightRangeOverride: NSRange?
    @State var selectedMergedEdgeBounds: ClosedRange<Int>?
    @State var tokenRanges: [TokenRange]?
    @State var furiganaBySegmentLocation: [Int: String] = [:]
    @State var furiganaLengthBySegmentLocation: [Int: Int] = [:]
    @State var furiganaComputationTask: Task<Void, Never>?
    @State var pendingPersistenceTask: Task<Void, Never>?
    @State var activeNoteID: UUID?
    @State var isLoadingSelectedNote = false
    @State var isEditMode = false
    @State var sharedScrollOffsetY: CGFloat = 0
    @State private var isShowingTokenList = false
    @State private var isShowingDisplayOptions = false
    @State var illegalMergeBoundaryLocation: Int?
    @State var illegalMergeFlashTask: Task<Void, Never>?

    // Initializes the read screen with the active note selection and shared read resources.
    init(
        selectedNote: Binding<Note?>,
        segmenter: Segmenter,
        dictionaryStore: DictionaryStore?,
        readingBySurface: [String: String],
        readingCandidatesBySurface: [String: [String]],
        segmenterRevision: Int,
        readResourcesReady: Bool,
        onActiveNoteChanged: ((UUID) -> Void)? = nil
    ) {
        _selectedNote = selectedNote
        self.segmenter = segmenter
        self.dictionaryStore = dictionaryStore
        self.readingBySurface = readingBySurface
        self.readingCandidatesBySurface = readingCandidatesBySurface
        self.segmenterRevision = segmenterRevision
        self.readResourcesReady = readResourcesReady
        self.onActiveNoteChanged = onActiveNoteChanged
    }

    let prefersSheetDirectSegmentActions = true

    var body: some View {
        NavigationStack {
            titleView
            VStack(spacing: 10) {
                editorView
                toolbarButtons
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .toolbar(.visible, for: .tabBar)
        .sheet(isPresented: $isShowingTokenList) {
            TokenListView(
                text: text,
                edges: segmentationEdges,
                sourceNoteID: activeNoteID,
                onMergeLeft: { edgeIndex in
                    mergeSegmentFromTokenList(at: edgeIndex, isMergingLeft: true)
                },
                onMergeRight: { edgeIndex in
                    mergeSegmentFromTokenList(at: edgeIndex, isMergingLeft: false)
                },
                onSplit: { edgeIndex, splitOffset in
                    splitSegmentFromTokenList(at: edgeIndex, offsetUTF16: splitOffset)
                },
                onReset: {
                    resetTokenSegmentationToComputed()
                }
            )
        }
        .onAppear {
            // Syncs editor state when this screen first appears.
            loadSelectedNoteIfNeeded()
        }
        .onChange(of: selectedNote?.id) { _, _ in
            // Syncs editor state when Notes tab selects a different note.
            loadSelectedNoteIfNeeded()
        }
        .onChange(of: text) { _, _ in
            // Persists edits as content changes.
            scheduleCurrentNotePersistenceIfNeeded()
            if isEditMode {
                tokenRanges = nil
                illegalMergeBoundaryLocation = nil
                illegalMergeFlashTask?.cancel()
                // Clears stale range state while editing so view-mode reactivation never reads mismatched ranges.
                furiganaComputationTask?.cancel()
                segmentationEdges = []
                segmentationRanges = []
                selectedSegmentLocation = nil
                selectedHighlightRangeOverride = nil
                selectedMergedEdgeBounds = nil
                SegmentDefinitionPopoverPresenter.shared.dismissPopover()
                furiganaBySegmentLocation = [:]
                furiganaLengthBySegmentLocation = [:]
                return
            }
            // Recomputes segments only after full read resources are ready.
            if readResourcesReady && isEditMode == false {
                refreshSegmentationRanges()
            }
        }
        .onChange(of: isEditMode) { _, editing in
            if editing {
                // Suspends furigana computation while editing text.
                illegalMergeBoundaryLocation = nil
                illegalMergeFlashTask?.cancel()
                furiganaComputationTask?.cancel()
                segmentationEdges = []
                segmentationRanges = []
                selectedSegmentLocation = nil
                selectedHighlightRangeOverride = nil
                selectedMergedEdgeBounds = nil
                SegmentDefinitionPopoverPresenter.shared.dismissPopover()
                furiganaBySegmentLocation = [:]
                furiganaLengthBySegmentLocation = [:]
            } else if readResourcesReady {
                flushPendingNotePersistenceIfNeeded()
                // Recomputes once when returning to view mode so furigana matches latest text.
                refreshSegmentationRanges()
            }
        }
        .onChange(of: segmenterRevision) { _, _ in
            // Recomputes segmentation after background dictionary loading completes.
            refreshSegmentationRanges()
        }
        .onDisappear {
            // Flushes any pending edit persistence before leaving the read screen.
            flushPendingNotePersistenceIfNeeded()
        }
    }

    // Displays the editable note title at the top of the reading screen.
    private var titleView: some View {
        Text(displayTitle)
            .font(.system(size: 24, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
            .onTapGesture {
                titleDraft = resolvedTitle
                isShowingTitleAlert = true
            }
            .alert("Edit Title", isPresented: $isShowingTitleAlert) {
                TextField("Title", text: $titleDraft)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    customTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    flushPendingNotePersistenceIfNeeded()
                }
            }
    }

    // Keeps both read and edit renderers mounted so mode toggles are instant.
    private var editorView: some View {
        ZStack {
            FuriganaTextRenderer(
                isActive: isEditMode == false,
                text: text,
                isLineWrappingEnabled: isLineWrappingEnabled,
                segmentationRanges: readResourcesReady ? segmentationRanges : [],
                selectedSegmentLocation: selectedSegmentLocation,
                selectedHighlightRangeOverride: selectedHighlightRangeOverride,
                illegalMergeBoundaryLocation: illegalMergeBoundaryLocation,
                furiganaBySegmentLocation: readResourcesReady && isFuriganaVisible ? furiganaBySegmentLocation : [:],
                furiganaLengthBySegmentLocation: readResourcesReady && isFuriganaVisible ? furiganaLengthBySegmentLocation : [:],
                isVisualEnhancementsEnabled: readResourcesReady,
                isColorAlternationEnabled: isColorAlternationEnabled,
                isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                segmenter: segmenter,
                externalContentOffsetY: sharedScrollOffsetY,
                onScrollOffsetYChanged: { newOffsetY in
                    sharedScrollOffsetY = newOffsetY
                },
                onSegmentTapped: { tappedSegmentLocation, tappedSegmentRect, sourceView in
                    handleReadModeSegmentTap(
                        tappedSegmentLocation,
                        tappedSegmentRect: tappedSegmentRect,
                        sourceView: sourceView
                    )
                },
                textSize: $textSize,
                lineSpacing: lineSpacing,
                kerning: kerning
            )
            .opacity(isEditMode ? 0 : 1)
            .allowsHitTesting(isEditMode == false)

            RichTextEditor(
                text: $text,
                isLineWrappingEnabled: isLineWrappingEnabled,
                segmentationRanges: readResourcesReady ? segmentationRanges : [],
                furiganaBySegmentLocation: readResourcesReady && isFuriganaVisible ? furiganaBySegmentLocation : [:],
                furiganaLengthBySegmentLocation: readResourcesReady && isFuriganaVisible ? furiganaLengthBySegmentLocation : [:],
                isVisualEnhancementsEnabled: readResourcesReady,
                isColorAlternationEnabled: isColorAlternationEnabled,
                isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                segmenter: segmenter,
                isEditMode: isEditMode,
                externalContentOffsetY: sharedScrollOffsetY,
                onScrollOffsetYChanged: { newOffsetY in
                    sharedScrollOffsetY = newOffsetY
                },
                textSize: $textSize,
                lineSpacing: lineSpacing,
                kerning: kerning
            )
            .opacity(isEditMode ? 1 : 0)
            .allowsHitTesting(isEditMode)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isEditMode ? Color(.systemBackground) : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isEditMode ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.3),
                    lineWidth: isEditMode ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 8)
    }

    // Renders action buttons for segmentation and display controls.
    private var toolbarButtons: some View {
        HStack {
            Spacer()
            resetButton
            tokenListButton
            furiganaButton
            editModeButton
        }
        .padding(.horizontal, 8)
    }

    // Resets custom token segmentation back to computed segmentation.
    private var resetButton: some View {
        Button {
            resetTokenSegmentationToComputed()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tokenRanges == nil ? Color.secondary.opacity(0.5) : Color.secondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(tokenRanges == nil || isEditMode)
        .opacity(tokenRanges == nil || isEditMode ? 0.5 : 0.7)
        .accessibilityLabel("Reset Token Segmentation")
    }

    // Opens the token list screen for split/merge actions synced to the paste area.
    private var tokenListButton: some View {
        Button {
            isShowingTokenList = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    isEditMode ? Color.secondary.opacity(0.5) : Color.secondary
                )
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isEditMode)
        .opacity(isEditMode ? 0.5 : 0.7)
        .accessibilityLabel("Show Token List")
    }

    // Toggles whether furigana annotations render in the main paste area.
    private var furiganaButton: some View {
        furiganaButtonLabel
        .contentShape(Circle())
        .onTapGesture {
            guard isEditMode == false else {
                return
            }

            isFuriganaVisible.toggle()
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            guard isEditMode == false else {
                return
            }

            isShowingDisplayOptions = true
        }
        .disabled(isEditMode)
        .opacity(isEditMode ? 0.5 : 0.8)
        .accessibilityLabel(isFuriganaVisible ? "Hide Furigana" : "Show Furigana")
        .accessibilityHint("Long press for display options")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $isShowingDisplayOptions, arrowEdge: .bottom) {
            displayOptionsPopover
                .presentationCompactAdaptation(.popover)
        }
    }

    // Renders the tappable furigana icon that also exposes display options on long press.
    private var furiganaButtonLabel: some View {
        Image(isFuriganaVisible ? "furigana.on" : "furigana.off")
            .renderingMode(.template)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isFuriganaVisible ? Color.accentColor : Color.secondary)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(Color(.tertiarySystemFill))
            )
    }

    // Presents display option toggles with persistent enabled-state styling.
    private var displayOptionsPopover: some View {
        VStack(spacing: 10) {
            displayOptionRow(
                title: "Apply Changes Globally",
                systemImage: "arrow.triangle.branch",
                isEnabled: shouldApplyChangesGlobally
            ) {
                shouldApplyChangesGlobally.toggle()
            }

            displayOptionRow(
                title: "Highlight Unknown",
                systemImage: isHighlightUnknownEnabled ? "questionmark.circle.fill" : "questionmark.circle",
                isEnabled: isHighlightUnknownEnabled
            ) {
                isHighlightUnknownEnabled.toggle()
            }

            displayOptionRow(
                title: "Segment Colors",
                systemImage: isColorAlternationEnabled ? "paintpalette.fill" : "paintpalette",
                isEnabled: isColorAlternationEnabled
            ) {
                isColorAlternationEnabled.toggle()
            }

            displayOptionRow(
                title: "Line Wrapping",
                systemImage: isLineWrappingEnabled ? "text.alignleft" : "arrow.right.to.line.compact",
                isEnabled: isLineWrappingEnabled
            ) {
                isLineWrappingEnabled.toggle()
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(Color(.systemBackground))
    }

    // Renders one display-option row with a highlighted background while its toggle is enabled.
    private func displayOptionRow(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.primary)

                Spacer(minLength: 0)

                if isEnabled {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isEnabled ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
    }

    // Uses one icon button whose visual treatment reflects active edit state.
    private var editModeButton: some View {
        Button {
            isEditMode.toggle()
        } label: {
            Image(systemName: "character.cursor.ibeam.ja")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isEditMode ? Color.white : Color.secondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(isEditMode ? Color.accentColor : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(isEditMode ? 1 : 0.7)
        .accessibilityLabel(isEditMode ? "Disable Edit Mode" : "Enable Edit Mode")
    }

}

#Preview {
    ReadView(selectedNote: .constant(nil), segmenter: Segmenter(trie: DictionaryTrie()), dictionaryStore: nil, readingBySurface: [:], readingCandidatesBySurface: [:], segmenterRevision: 0, readResourcesReady: false)
        .environmentObject(NotesStore())
}
