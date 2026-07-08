import DispatchKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Query private var reports: [Report]

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 64))
            Text("Dispatch")
                .font(.title)
            Text("\(reports.count) reports")
                .font(.subheadline)
        }
    }
}
