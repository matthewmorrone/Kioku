import SwiftUI

// Live dictionary content for one flashcard, fetched asynchronously from DictionaryStore.
// `meanings` carries one entry per selected sense so the back face can render them stacked;
// it falls back to the entry's first sense when the saved word has no explicit selection.
private struct FlashcardLiveContent {
    let surface: String
    let kanji: String?
    let kana: String?
    let meanings: [String]
}

// Swipe vs. flip gesture disambiguation state for a card drag.
private enum FlashcardGestureMode {
    case undecided
    case swipe
    case flip
}

// Which physical face of the card is showing.
private enum FlashcardCardFace {
    case front
    case back
}

// Renders one card in the stack with 3D flip and swipe-to-grade gestures.
// Major sections: card face (front/back with lighting gradients), gesture handler, swipe-out animation.
struct FlashcardCard: View {
    let word: SavedWord
    let dictionaryStore: DictionaryStore?
    let isTop: Bool
    let direction: StudyDirection
    let japaneseForm: StudyJapaneseForm
    let preferredNoteID: UUID?
    @Binding var showBack: Bool
    @Binding var dragOffset: CGSize
    @Binding var isSwipingOut: Bool
    @Binding var swipeDirection: Int
    let onKnow: () -> Void
    let onAgain: () -> Void

    @EnvironmentObject private var notesStore: NotesStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Opt-in Japanese theme: when off, every styled element below falls back to its original look.
    @AppStorage(Theme.storageKey) private var japaneseTheme = false

    @State private var liveContent: FlashcardLiveContent?
    @State private var gestureMode: FlashcardGestureMode = .undecided
    @State private var flipAngleDegrees: Double = 0
    @State private var flipStartAngleDegrees: Double = 0

    private let maxRotationDegrees: CGFloat = 10
    private let dismissDistance: CGFloat = 120
    private let dismissPredictedDistance: CGFloat = 180
    private let flipDistance: CGFloat = 110
    private let flipPredictedDistance: CGFloat = 160
    private let flipDragDistance: CGFloat = 220

    var body: some View {
        cardContent
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 320)
            .contentShape(Rectangle())
            .offset(x: isTop ? dragOffset.width : 0, y: isTop ? dragOffset.height : 0)
            .rotationEffect(.degrees(isTop ? currentRotationDegrees : 0))
            .scaleEffect(isTop && dragOffset != .zero ? 1.03 : 1)
            .shadow(
                color: Color.black.opacity(isTop ? currentShadowOpacity : 0.08),
                radius: isTop ? (8 + 10 * dragProgress) : 8,
                x: 0,
                y: isTop ? (4 + 10 * dragProgress) : 4
            )
            .overlay(actionOverlays)
            .zIndex(isTop ? 10 : 0)
            .allowsHitTesting(isTop)
            .gesture(dragGesture)
            .onAppear {
                if isTop { flipAngleDegrees = showBack ? 180 : 0 }
            }
            .onChange(of: isTop) { _, newValue in
                if newValue { flipAngleDegrees = showBack ? 180 : 0 }
            }
            .onChange(of: showBack) { _, newValue in
                guard isTop, gestureMode != .flip else { return }
                flipAngleDegrees = newValue ? 180 : 0
            }
            // Task id includes both selection arrays so the lookup re-fires whenever the user
            // toggles a sense or a gloss from the word detail view.
            .task(id: liveContentTaskID) {
                liveContent = await resolveLiveContent()
            }
    }

    // Stable identity for the task that resolves liveContent — entry id followed by every
    // selected-sense id and every selected gloss ref. Recomputing fires .task again.
    private var liveContentTaskID: [Int64] {
        var key: [Int64] = [word.canonicalEntryID]
        key.append(contentsOf: word.selectedSenseIDs)
        for ref in word.selectedGlosses {
            key.append(ref.senseID)
            key.append(Int64(ref.glossIndex))
        }
        return key
    }

    // Resolves kana + glosses for this card's word directly from the dictionary store.
    // Each card owns its own fetch so display state cannot drift from any sibling-keyed cache.
    // The meanings list combines whole-sense selections (use sense's first gloss) with
    // gloss-level selections (use that exact gloss text); duplicates are dropped so a sense
    // selected and one of its glosses pinned doesn't render the same phrase twice.
    private func resolveLiveContent() async -> FlashcardLiveContent? {
        guard let store = dictionaryStore else { return nil }
        let entryID = word.canonicalEntryID
        let surface = word.surface
        let selectedSenseIDs = word.selectedSenseIDs
        let selectedGlosses = word.selectedGlosses
        return await Task.detached(priority: .utility) {
            guard let data = try? store.fetchWordDisplayData(entryID: entryID, surface: surface) else {
                return nil
            }
            // Pick the reading that fits the user's selected senses — JMdict stagr restricts
            // some senses to specific kana forms (e.g. 黄昏's "dusk;twilight" sense is restricted
            // to たそがれ even though the alphabetically-first kana form is こうこん).
            let senseRestrictions = (try? store.fetchSenseRestrictions(entryID: entryID)) ?? []
            let kana = data.entry.preferredKana(
                selectedSenseIDs: selectedSenseIDs,
                selectedGlosses: selectedGlosses,
                senseRestrictions: senseRestrictions
            )
            // Dictionary kanji headword (most common written form) for the 漢字 study form.
            let kanji = data.entry.kanjiForms.first?.text

            var sensesByID: [Int64: DictionaryEntrySense] = [:]
            for sense in data.entry.senses { sensesByID[sense.senseID] = sense }

            var meanings: [String] = []
            var seen: Set<String> = []

            // Adds a meaning to the running list after trimming and de-duplicating.
            func append(_ raw: String) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false, seen.insert(trimmed).inserted else { return }
                meanings.append(trimmed)
            }

            for senseID in selectedSenseIDs {
                if let first = sensesByID[senseID]?.glosses.first { append(first) }
            }
            for ref in selectedGlosses {
                if let sense = sensesByID[ref.senseID],
                   ref.glossIndex >= 0, ref.glossIndex < sense.glosses.count {
                    append(sense.glosses[ref.glossIndex])
                }
            }

            // Fallback: nothing selected (or selections didn't survive a dictionary rebuild)
            // — show the entry's first sense's first gloss, matching the original behavior.
            if meanings.isEmpty, let first = data.entry.senses.first?.glosses.first {
                append(first)
            }

            return FlashcardLiveContent(surface: surface, kanji: kanji, kana: kana, meanings: meanings)
        }.value
    }

    private var dragProgress: CGFloat {
        guard isTop else { return 0 }
        return min(1, abs(dragOffset.width) / 140)
    }

    private var currentRotationDegrees: Double {
        guard isTop else { return 0 }
        return Double(max(-maxRotationDegrees, min(maxRotationDegrees, dragOffset.width / 22)))
    }

    private var currentShadowOpacity: Double { 0.14 + Double(0.18 * dragProgress) }

    @ViewBuilder
    private var cardContent: some View {
        let angle = isTop ? flipAngleDegrees : 0
        let radians = angle * .pi / 180
        let isFrontVisible = cos(radians) >= 0
        let tilt = abs(sin(radians))
        let perspective: CGFloat = reduceMotion ? 1 / 650 : 1 / 320
        let roll = reduceMotion ? 0.0 : (6 * tilt)

        ZStack {
            cardFace(flipAngle: angle, face: .front) { frontFace }
                .opacity(isFrontVisible ? 1 : 0)
                .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: perspective)
                .rotation3DEffect(.degrees(roll), axis: (x: 0, y: 1, z: 0), perspective: perspective)

            cardFace(flipAngle: angle, face: .back) { backFace }
                .opacity(isFrontVisible ? 0 : 1)
                .rotation3DEffect(.degrees(angle - 180), axis: (x: 1, y: 0, z: 0), perspective: perspective)
                .rotation3DEffect(.degrees(-roll), axis: (x: 0, y: 1, z: 0), perspective: perspective)
        }
    }

    // Applies lighting gradients to simulate a physical card flipping in light.
    private func cardFace<Content: View>(
        flipAngle: Double,
        face: FlashcardCardFace,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let radians = flipAngle * .pi / 180
        let tilt = abs(sin(radians))
        let glossStrength = reduceMotion ? 0.0 : (0.03 + 0.10 * tilt)
        let highlightFromTop = face == .front

        return ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(japaneseTheme ? Theme.surface : Color(UIColor.secondarySystemBackground))
                // Warm vermilion masthead rule along the top edge — only in the themed look.
                .overlay(alignment: .top) {
                    if japaneseTheme {
                        Theme.accent.opacity(0.85).frame(height: 4)
                    }
                }
                .overlay {
                    LinearGradient(
                        colors: [Color.white.opacity(0.02 + 0.07 * tilt), Color.clear],
                        startPoint: highlightFromTop ? .top : .bottom,
                        endPoint: .center
                    )
                }
                .overlay {
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.03 + 0.12 * tilt)],
                        startPoint: .center,
                        endPoint: highlightFromTop ? .bottom : .top
                    )
                }
                .overlay {
                    RadialGradient(
                        colors: [Color.white.opacity(glossStrength), Color.clear],
                        center: face == .front ? .topLeading : .topTrailing,
                        startRadius: 0, endRadius: 180
                    )
                    .blendMode(.screen)
                }
                .overlay {
                    RadialGradient(
                        colors: [Color.black.opacity(0.05 + 0.07 * tilt), Color.clear],
                        center: face == .front ? .bottomTrailing : .bottomLeading,
                        startRadius: 0, endRadius: 220
                    )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            japaneseTheme ? Theme.hairline : Color.white.opacity(0.06 + 0.10 * tilt),
                            lineWidth: 1
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))

            content()
                .padding(24)
                .padding(.top, japaneseTheme ? 8 : 0)
                .frame(maxWidth: .infinity, maxHeight: 320)
        }
    }

    // One face's content. The Japanese cases carry the chosen written form (原文/漢字/かな);
    // the `answer` variant adds the kana reading beneath the headword ("inclusion of both").
    // Defined once so the front (prompt) and back (answer) share `faceView`.
    private enum FlashcardFaceContent {
        case english
        case japanesePrompt(StudyJapaneseForm)
        case japaneseAnswer(StudyJapaneseForm)
    }

    // Maps the (direction, form) pair to the front (prompt) and back (answer) content. `.mixed` is
    // resolved per card from the entry id so a card doesn't swap its sides between re-renders.
    private var faces: (front: FlashcardFaceContent, back: FlashcardFaceContent) {
        switch direction.resolved(seed: word.canonicalEntryID) {
        case .japaneseToEnglish, .mixed:
            return (.japanesePrompt(japaneseForm), .english)
        case .englishToJapanese:
            return (.english, .japaneseAnswer(japaneseForm))
        }
    }

    private var frontFace: some View { faceView(faces.front) }
    private var backFace: some View { faceView(faces.back) }

    // The Japanese string for a written form, falling back to the encountered surface when the
    // dictionary kanji headword / reading isn't available.
    private func japaneseText(for form: StudyJapaneseForm, displaySurface: String, displayKana: String?) -> String {
        switch form {
        case .original: return displaySurface
        case .kanji: return liveContent?.kanji ?? displaySurface
        case .kana: return displayKana ?? displaySurface
        }
    }

    // Renders one face's content, shared by both the front (prompt) and back (answer) so each
    // direction's wording is defined once in `faces`.
    @ViewBuilder
    private func faceView(_ content: FlashcardFaceContent) -> some View {
        let displaySurface = displaySurfaceForCard()
        let displayKana = displayKanaForCard(displaySurface: displaySurface)
        VStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 0)
            switch content {
            case .english:
                let meanings = liveContent?.meanings ?? []
                if meanings.isEmpty == false {
                    VStack(spacing: 8) {
                        ForEach(meanings, id: \.self) { meaning in
                            Text(meaning)
                                .font(japaneseTheme ? .system(.title2, design: .serif).weight(.semibold) : .title2.weight(.semibold))
                                .multilineTextAlignment(.center)
                        }
                    }
                } else {
                    Text("—")
                        .font(japaneseTheme ? .system(.title2, design: .serif).weight(.semibold) : .title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            case .japanesePrompt(let form):
                // Single line. For the kana form, hold off the kanji fallback while the reading is
                // still loading so a kana prompt doesn't flash the kanji.
                if form == .kana, displayKana == nil, isKanaOnly(displaySurface) == false, liveContent == nil {
                    EmptyView()
                } else {
                    headword(japaneseText(for: form, displaySurface: displaySurface, displayKana: displayKana))
                }
            case .japaneseAnswer(let form):
                let text = japaneseText(for: form, displaySurface: displaySurface, displayKana: displayKana)
                headword(text)
                // Reading beneath the headword, except when the form already IS the reading.
                if form != .kana, let displayKana, displayKana.isEmpty == false, isKanaOnly(text) == false {
                    Text(displayKana)
                        .font(japaneseTheme ? .custom("HiraMinProN-W3", size: 20) : .title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // The large centered headword styling shared by every Japanese face. Hiragino Mincho in the
    // themed look; the original bold large-title otherwise.
    private func headword(_ text: String) -> some View {
        Text(text)
            .font(japaneseTheme ? .custom("HiraMinProN-W6", size: 44) : .largeTitle.weight(.bold))
            .minimumScaleFactor(japaneseTheme ? 0.6 : 1)
            .multilineTextAlignment(.center)
    }

    // Prefers showing the form that appears in the source note to give reading context.
    // Falls back to the SavedWord's stored surface so the card always shows something
    // immediately, even before the dictionary lookup resolves.
    private func displaySurfaceForCard() -> String {
        let liveSurface = liveContent?.surface.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let surface = liveSurface.isEmpty ? word.surface : liveSurface
        guard surface.isEmpty == false else { return word.surface }

        let noteID = preferredNoteID ?? word.sourceNoteIDs.first
        guard let noteID,
              let noteText = notesStore.notes.first(where: { $0.id == noteID })?.content,
              noteText.isEmpty == false
        else { return surface }

        if noteText.contains(surface) { return surface }
        if let kana = liveContent?.kana?.trimmingCharacters(in: .whitespacesAndNewlines),
           kana.isEmpty == false,
           noteContains(noteText, candidate: kana) {
            return kana
        }
        return surface
    }

    // Returns the kana reading to show below the headword on a card, or nil when the surface is already pure kana.
    private func displayKanaForCard(displaySurface: String) -> String? {
        if let kana = liveContent?.kana?.trimmingCharacters(in: .whitespacesAndNewlines),
           kana.isEmpty == false { return kana }
        return isKanaOnly(displaySurface) ? displaySurface : nil
    }

    // Checks containment after folding katakana → hiragana so variant kana spellings match.
    private func noteContains(_ noteText: String, candidate: String) -> Bool {
        if noteText.contains(candidate) { return true }
        let folded = noteText.applyingTransform(.hiraganaToKatakana, reverse: true) ?? noteText
        let foldedCandidate = candidate.applyingTransform(.hiraganaToKatakana, reverse: true) ?? candidate
        return folded.contains(foldedCandidate)
    }

    // Determines whether a surface form is composed entirely of kana so a redundant reading line is suppressed.
    private func isKanaOnly(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.isEmpty == false else { return false }
        return t.unicodeScalars.allSatisfy(ScriptClassifier.isKanaScalar)
    }

    @ViewBuilder
    private var actionOverlays: some View {
        if isTop {
            if japaneseTheme {
                themedActionOverlays
            } else {
                Group {
                    Text("Again").font(.headline).padding(8)
                        .background(Color.red.opacity(0.2)).cornerRadius(8)
                        .opacity(max(0, min(1, -dragOffset.width / 100)))
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    Text("Know").font(.headline).padding(8)
                        .background(Color.green.opacity(0.2)).cornerRadius(8)
                        .opacity(max(0, min(1, dragOffset.width / 100)))
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
    }

    // Hanko (判子) stamp-style swipe indicators for the themed look: a tilted kanji inside a
    // rectangular ink border, echoing the approval stamps used on Japanese documents.
    @ViewBuilder
    private var themedActionOverlays: some View {
        let againRed = Color(red: 0.78, green: 0.21, blue: 0.23)
        let knowBlue = Color(red: 0.18, green: 0.31, blue: 0.55)
        Group {
            Text("また")
                .font(.custom("HiraMinProN-W6", size: 26))
                .foregroundColor(againRed)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(Rectangle().stroke(againRed, lineWidth: 2.5))
                .rotationEffect(.degrees(-15))
                .opacity(max(0, min(1, -dragOffset.width / 80)))
                .padding(.leading, 20)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Text("知")
                .font(.custom("HiraMinProN-W6", size: 26))
                .foregroundColor(knowBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .overlay(Rectangle().stroke(knowBlue, lineWidth: 2.5))
                .rotationEffect(.degrees(15))
                .opacity(max(0, min(1, dragOffset.width / 80)))
                .padding(.trailing, 20)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard isTop else { return }
                if gestureMode == .undecided {
                    let t = value.translation
                    if abs(t.width) > 12 || abs(t.height) > 12 {
                        gestureMode = abs(t.width) >= abs(t.height) ? .swipe : .flip
                        if gestureMode == .flip { flipStartAngleDegrees = flipAngleDegrees }
                    }
                }
                switch gestureMode {
                case .swipe, .undecided:
                    dragOffset = value.translation
                case .flip:
                    dragOffset = CGSize(width: 0, height: value.translation.height * 0.08)
                    let delta = (-value.translation.height / flipDragDistance) * 180
                    flipAngleDegrees = flipStartAngleDegrees + Double(delta)
                }
            }
            .onEnded { value in
                guard isTop else { return }
                switch gestureMode {
                case .flip:
                    finishFlip(translation: value.translation, predicted: value.predictedEndTranslation)
                case .swipe, .undecided:
                    handleDragEnd(translation: value.translation, predicted: value.predictedEndTranslation)
                }
                gestureMode = .undecided
            }
    }

    // Decides whether a horizontal drag should dismiss the card and in which direction, or spring it back.
    private func handleDragEnd(translation: CGSize, predicted: CGSize) {
        let dx = translation.width
        let predictedDx = predicted.width
        guard abs(dx) > dismissDistance || abs(predictedDx) > dismissPredictedDistance else {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) { dragOffset = .zero }
            return
        }
        let dir: Int = (predictedDx != 0 ? predictedDx > 0 : dx > 0) ? 1 : -1
        swipeOut(direction: dir) { dir > 0 ? onKnow() : onAgain() }
    }

    // Commits or cancels a vertical flip gesture, snapping the card to the nearest face.
    private func finishFlip(translation: CGSize, predicted: CGSize) {
        let dy = translation.height
        let predictedDy = predicted.height
        let shouldCommit = abs(dy) > flipDistance || abs(predictedDy) > flipPredictedDistance
        let directionStep: Int = ((predictedDy != 0 ? predictedDy : dy) < 0) ? 1 : -1
        let startIndex = Int((flipStartAngleDegrees / 180).rounded())
        let targetIndex = shouldCommit ? (startIndex + directionStep) : startIndex
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) {
            flipAngleDegrees = Double(targetIndex) * 180
            dragOffset = .zero
        }
        showBack = (abs(targetIndex) % 2) == 1
    }

    // Animates the card flying off screen, then fires the completion callback to update session state.
    // The post-flight state swap (advance session, reset dragOffset) runs inside an animation-less
    // Transaction so SwiftUI cannot interpolate dragOffset back to center — that interpolation was
    // the visual "revert" between the dismissed card and the next card.
    private func swipeOut(direction dir: Int, completion: @escaping () -> Void) {
        let offX: CGFloat = CGFloat(dir) * 720
        let remaining = abs(offX - dragOffset.width)
        let duration = reduceMotion ? 0.01 : min(0.50, max(0.28, Double(remaining / 1600)))
        isSwipingOut = true; swipeDirection = dir
        withAnimation(.easeOut(duration: duration)) {
            dragOffset = CGSize(width: offX, height: dragOffset.height * 0.2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withTransaction(Transaction(animation: nil)) {
                completion()
                showBack = false
                dragOffset = .zero
            }
            isSwipingOut = false
            swipeDirection = 0
        }
    }
}
