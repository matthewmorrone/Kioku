import SwiftUI

// Reserves the words tab container for dictionary and saved-word workflows.
struct WordsView: View {
    var body: some View {
        NavigationStack {
            
        }
        .toolbar(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView(selectedTab: .words)
}
