import SwiftUI

struct OverlandRootView: View {
    @State private var selection = 0
    @State private var tabBarHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pillSpace

    private let slideAnimation = Animation.spring(duration: 0.45, bounce: 0.08)

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                NavigationStack { TrackerView().tabBarClearance().environment(\.mapPageActive, selection == 0) }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .accessibilityHidden(selection != 0)
                    .allowsHitTesting(selection == 0)
                NavigationStack { TripView().tabBarClearance().environment(\.mapPageActive, selection == 1) }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .accessibilityHidden(selection != 1)
                    .allowsHitTesting(selection == 1)
                NavigationStack { SettingsView().tabBarClearance() }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .accessibilityHidden(selection != 2)
                    .allowsHitTesting(selection == 2)
            }
            .offset(x: -CGFloat(selection) * geo.size.width)
            .animation(reduceMotion ? nil : slideAnimation, value: selection)
        }
        .mask { Rectangle().ignoresSafeArea() }
        .overlay(alignment: .bottom) {
            tabBar
                .padding(.vertical, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tabBarHeight = $0 }
        }
        .environment(\.overlandTabBarHeight, tabBarHeight)
        .tint(.blue)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(0, "Tracker", "location.fill")
            tabButton(1, "Trip", "figure.walk")
            tabButton(2, "Settings", "gearshape.2.fill")
        }
        .padding(5)
        .frame(maxWidth: 340)
        .glassTabBarBackground()
        .padding(.horizontal, 48)
        .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button {
            guard selection != index else { return }
            selection = index
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background {
                if selection == index {
                    Capsule()
                        .fill(.quaternary.opacity(0.7))
                        .matchedGeometryEffect(id: "tabPill", in: pillSpace)
                }
            }
            .foregroundStyle(selection == index ? Color.blue : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == index ? [.isSelected] : [])
    }
}

extension View {
    @ViewBuilder
    func glassTabBarBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(Capsule().fill(.ultraThinMaterial))
        }
    }
}

final class OverlandRootHosting: NSObject {
    @objc static func makeRoot() -> UIViewController {
        UIHostingController(rootView: OverlandRootView())
    }
}

private struct OverlandTabBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var overlandTabBarHeight: CGFloat {
        get { self[OverlandTabBarHeightKey.self] }
        set { self[OverlandTabBarHeightKey.self] = newValue }
    }
}

private struct TabBarClearance: ViewModifier {
    @Environment(\.overlandTabBarHeight) private var height

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: height)
        }
    }
}

extension View {
    func tabBarClearance() -> some View {
        modifier(TabBarClearance())
    }
}
