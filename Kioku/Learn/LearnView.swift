import SwiftUI

// Reserves the learning tab container for study-related features.
struct LearnView: View {
    var body: some View {
        NavigationStack {
            
        }
        .toolbar(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView(selectedTab: .learn)
}
