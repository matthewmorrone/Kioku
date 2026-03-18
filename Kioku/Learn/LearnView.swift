import SwiftUI
import Combine

// Hosts the learning tab. Currently shows the interactive kana chart.
// Major sections: NavigationStack shell, KanaChartView content.
struct LearnView: View {
    var body: some View {
        NavigationStack {
            KanaChartView()
        }
        .toolbar(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView(selectedTab: .learn)
}
