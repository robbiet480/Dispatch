import DispatchKit
import SwiftData
import SwiftUI

@main
struct DispatchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(try! ModelContainer(for: Schema(DispatchStore.allModels)))
    }
}
