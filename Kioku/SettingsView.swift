import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            
        }
        .toolbar(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView(selectedTab: .settings)
}
