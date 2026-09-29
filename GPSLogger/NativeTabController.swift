import SwiftUI
import UIKit

struct OverlandNativeTabs: UIViewControllerRepresentable {
    @Binding var selection: Int
    @Binding var panelTop: CGFloat?
    let map: AnyView
    let controls: AnyView
    let settings: AnyView
    var onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> OverlandNativeTabController {
        let controller = OverlandNativeTabController(
            map: map,
            controls: controls,
            settings: settings,
            selection: selection
        )
        controller.onUserSelection = { [weak coordinator = context.coordinator] index in
            coordinator?.userSelected(index)
        }
        controller.onPanelTopChange = { [weak coordinator = context.coordinator] top in
            coordinator?.panelTopChanged(top)
        }
        return controller
    }

    func updateUIViewController(_ controller: OverlandNativeTabController, context: Context) {
        context.coordinator.parent = self
        controller.update(
            map: map,
            controls: controls,
            settings: settings,
            selection: selection
        )
    }

    final class Coordinator {
        var parent: OverlandNativeTabs

        init(parent: OverlandNativeTabs) {
            self.parent = parent
        }

        func userSelected(_ index: Int) {
            parent.selection = index
            parent.onSelect(index)
        }

        func panelTopChanged(_ top: CGFloat) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if abs((parent.panelTop ?? -1) - top) > 0.5 { parent.panelTop = top }
            }
        }
    }
}

final class OverlandNativeTabController: UITabBarController, UITabBarControllerDelegate {
    var onUserSelection: ((Int) -> Void)?
    var onPanelTopChange: ((CGFloat) -> Void)? {
        didSet { controlsHost.refreshPanelTop() }
    }

    private let mapHost: UIHostingController<AnyView>
    private let controlsHost: MapControlPanelController
    private let settingsHost: UIHostingController<AnyView>
    private let mapModule: NativeMapModuleController
    private let trackerHost = NativeMapTabHostController()
    private let tripHost = NativeMapTabHostController()
    private var applyingSelection = false
    private var currentSelection = -1

    init(map: AnyView, controls: AnyView, settings: AnyView, selection: Int) {
        let mapHost = UIHostingController(rootView: map)
        let controlsHost = MapControlPanelController(controls: controls)
        let settingsHost = UIHostingController(rootView: settings)
        self.mapHost = mapHost
        self.controlsHost = controlsHost
        self.settingsHost = settingsHost
        mapModule = NativeMapModuleController(mapHost: mapHost, panel: controlsHost)
        super.init(nibName: nil, bundle: nil)

        controlsHost.onTopChange = { [weak self] top in self?.onPanelTopChange?(top) }

        configureTabs()
        applySelection(selection, notify: false)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(map: AnyView, controls: AnyView, settings: AnyView, selection: Int) {
        mapHost.rootView = map
        mapHost.view.invalidateIntrinsicContentSize()
        controlsHost.update(controls: controls)
        settingsHost.rootView = settings
        settingsHost.view.invalidateIntrinsicContentSize()
        applySelection(selection, notify: false)
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          didSelect viewController: UIViewController) {
        guard !applyingSelection else { return }
        if viewController === trackerHost {
            applySelection(0, notify: true)
        } else if viewController === tripHost {
            applySelection(1, notify: true)
        } else if viewController === settingsHost {
            applySelection(2, notify: true)
        }
    }

    @available(iOS 18.0, *)
    func tabBarController(_ tabBarController: UITabBarController,
                          didSelectTab selectedTab: UITab,
                          previousTab: UITab?) {
        guard !applyingSelection else { return }
        switch selectedTab.identifier {
        case "tracker": applySelection(0, notify: true)
        case "trip": applySelection(1, notify: true)
        case "settings": applySelection(2, notify: true)
        default: break
        }
    }

    private func configureTabs() {
        trackerHost.tabBarItem = UITabBarItem(
            title: "Tracker",
            image: UIImage(systemName: "location.fill"),
            selectedImage: UIImage(systemName: "location.fill")
        )
        tripHost.tabBarItem = UITabBarItem(
            title: "Trip",
            image: UIImage(systemName: "figure.walk"),
            selectedImage: UIImage(systemName: "figure.walk")
        )
        settingsHost.tabBarItem = UITabBarItem(
            title: "Settings",
            image: UIImage(systemName: "gearshape.2.fill"),
            selectedImage: UIImage(systemName: "gearshape.2.fill")
        )

        if #available(iOS 18.0, *) {
            mode = .tabBar
            customizationIdentifier = "overland-primary-tabs"
            let trackerTab = makeTab(
                title: "Tracker", image: "location.fill", identifier: "tracker", controller: trackerHost
            )
            let tripTab = makeTab(
                title: "Trip", image: "figure.walk", identifier: "trip", controller: tripHost
            )
            let settingsTab = makeTab(
                title: "Settings", image: "gearshape.2.fill", identifier: "settings", controller: settingsHost
            )
            compactTabIdentifiers = [trackerTab.identifier, tripTab.identifier, settingsTab.identifier]
            tabs = [trackerTab, tripTab, settingsTab]
        } else {
            viewControllers = [trackerHost, tripHost, settingsHost]
        }
    }

    @available(iOS 18.0, *)
    private func makeTab(
        title: String,
        image: String,
        identifier: String,
        controller: UIViewController
    ) -> UITab {
        let tab = UITab(title: title, image: UIImage(systemName: image), identifier: identifier) { _ in
            controller
        }
        tab.preferredPlacement = .fixed
        return tab
    }

    private func applySelection(_ requestedIndex: Int, notify: Bool) {
        let index = min(2, max(0, requestedIndex))
        let previousSelection = currentSelection
        let changed = previousSelection != index
        currentSelection = index

        switch index {
        case 0:
            trackerHost.install(mapModule)
            if notify || (previousSelection >= 0 && changed) { controlsHost.expand() }
        case 1:
            tripHost.install(mapModule)
            if notify || (previousSelection >= 0 && changed) { controlsHost.expand() }
        default:
            detachMapModule()
        }

        applyingSelection = true
        if #available(iOS 18.0, *) {
            let identifier = ["tracker", "trip", "settings"][index]
            if selectedTab?.identifier != identifier {
                selectedTab = tab(forIdentifier: identifier)
            }
        } else if selectedIndex != index {
            selectedIndex = index
        }
        applyingSelection = false

        if notify { onUserSelection?(index) }
    }

    private func detachMapModule() {
        guard mapModule.parent != nil else { return }
        mapModule.willMove(toParent: nil)
        mapModule.view.removeFromSuperview()
        mapModule.removeFromParent()
    }
}

private final class NativeMapTabHostController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }

    func install(_ controller: UIViewController) {
        guard controller.parent !== self else { return }
        if controller.parent != nil {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }

        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }
}

private final class NativeMapModuleController: UIViewController {
    private let mapHost: UIHostingController<AnyView>
    private let panel: MapControlPanelController

    init(mapHost: UIHostingController<AnyView>, panel: MapControlPanelController) {
        self.mapHost = mapHost
        self.panel = panel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        install(mapHost)
        install(panel)
    }

    private func install(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }
}
