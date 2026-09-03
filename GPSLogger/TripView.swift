import SwiftUI

struct TripView: View {
    @State private var bridge = GLManagerBridge.shared
    let modes: [(String, String)] = [
        ("walk", "figure.walk"), ("run", "figure.run"), ("bicycle", "bicycle"), ("car", "car.fill"),
        ("taxi", "car.side"), ("bus", "bus.fill"), ("train", "tram.fill"), ("plane", "airplane"),
        ("boat", "sailboat.fill"), ("scooter", "scooter"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                tripCard
                if !bridge.tripInProgress {
                    Text("Choose how you're traveling, then start the trip. Points are logged against the trip until you stop it or the app notices you've been still.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90)), GridItem(.adaptive(minimum: 90)), GridItem(.adaptive(minimum: 90))], spacing: 12) {
                    ForEach(modes, id: \.0) { mode, icon in
                        Button {
                            GLManager.shared().currentTripMode = mode
                            bridge.refresh()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: icon).font(.title2)
                                Text(mode).font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background {
                                if #available(iOS 26.0, *) {
                                    RoundedRectangle(cornerRadius: 18).fill(.clear).glassEffect(.regular.interactive())
                                } else {
                                    RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)
                                }
                            }
                            .overlay {
                                if GLManager.shared().currentTripMode == mode {
                                    RoundedRectangle(cornerRadius: 18).strokeBorder(.tint, lineWidth: 2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(bridge.tripInProgress)
                    }
                }
                .padding(.horizontal)
                if !bridge.tripInProgress {
                    Button("Trip Settings") { presentTripSettings() }
                        .glassButtonStyle(tint: .blue)
                }
            }
            .padding(.top)
        }
        .navigationTitle("Trip")
        .onAppear { bridge.refresh() }
    }

    private var tripCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bridge.tripInProgress ? "Trip in progress" : "Start a trip?")
                    .font(.headline)
                Text(bridge.tripInProgress ? "Tap stop when you arrive" : "Points are batched separately while a trip runs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                bridge.tripInProgress ? GLManager.shared().endTrip() : GLManager.shared().startTrip()
                bridge.refresh()
            } label: {
                Text(bridge.tripInProgress ? "Stop" : "Start")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .glassButtonStyle(prominent: true, tint: bridge.tripInProgress ? .red : .green)
        }
        .padding(16)
        .background {
            if #available(iOS 26.0, *) {
                RoundedRectangle(cornerRadius: 24).fill(.clear).glassEffect(.regular.interactive())
            } else {
                RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial)
            }
        }
        .padding(.horizontal)
    }

    private func presentTripSettings() {
        let vc = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "TripSettingsViewController")
        (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first(where: \.isKeyWindow)?.rootViewController)?
            .present(UINavigationController(rootViewController: vc), animated: true)
    }
}
