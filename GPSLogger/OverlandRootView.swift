import SwiftUI

struct OverlandRootView: View {
    var body: some View {
        TabView {
            NavigationStack { TrackerView() }
                .tabItem { Label("Tracker", systemImage: "location.fill") }
            NavigationStack { TripView() }
                .tabItem { Label("Trip", systemImage: "figure.walk") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.2.fill") }
        }
    }
}

final class OverlandRootHosting: NSObject {
    @objc static func makeRoot() -> UIViewController {
        UIHostingController(rootView: OverlandRootView())
    }
}
