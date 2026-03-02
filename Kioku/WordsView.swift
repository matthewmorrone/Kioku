import SwiftUI

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
