import SwiftUI

// The menu of which kinds of word get a meaning (LyricWordMeaningFilter), shared by the lyrics
// card's Bubbles menu and the full-screen word view's Meanings menu. Particles, Katakana and
// Vocalizations are the filters shared with the Breakdown's Show menu; English Words is the lyrics
// views' own. Layout: four toggles, as the items of the caller's Menu.
struct LyricWordFilterMenuItems: View {
    @AppStorage(BreakdownListenSettings.showParticlesKey) private var showsParticles = BreakdownListenSettings.defaultShowParticles
    @AppStorage(LyricsPopupSettings.showLoanwordBubblesKey) private var showsLoanwords = LyricsPopupSettings.defaultShowLoanwordBubbles
    @AppStorage(BreakdownListenSettings.showKatakanaKey) private var showsKatakana = BreakdownListenSettings.defaultShowKatakana
    @AppStorage(BreakdownListenSettings.showVocalizationsKey) private var showsVocalizations = BreakdownListenSettings.defaultShowVocalizations

    var body: some View {
        Toggle("Particles", isOn: $showsParticles)
        Toggle("English Words", isOn: $showsLoanwords)
        Toggle("Katakana", isOn: $showsKatakana)
        Toggle("Vocalizations", isOn: $showsVocalizations)
    }
}
