import SwiftUI
import UIKit

final class MapControlPanelController: UIViewController, UIGestureRecognizerDelegate {
    var onTopChange: ((CGFloat) -> Void)?
    enum Position: String {
        case collapsed = "Collapsed"
        case expanded = "Expanded"
    }

    private let effectView: UIVisualEffectView
    private let grabber = AdjustablePanelGrabber(frame: .zero)
    private let grabberMark = UIView(frame: .zero)
    private let scrollView = UIScrollView(frame: .zero)
    private let reservedTabRegion = UIView(frame: .zero)
    private let controlsHost: UIHostingController<AnyView>
    private var panelBottomConstraint: NSLayoutConstraint!
    private var panelHeightConstraint: NSLayoutConstraint!
    private var panelWidthConstraint: NSLayoutConstraint!
    private var controlsHeightConstraint: NSLayoutConstraint!
    private var controlsWidthConstraint: NSLayoutConstraint!
    private var reservedHeightConstraint: NSLayoutConstraint!
    private var settleAnimator: UIViewPropertyAnimator?
    private var topDisplayLink: CADisplayLink?
    private var measurementScheduled = false
    private var animationGeneration = 0
    private var dragOriginHeight: CGFloat = 0
    private var isDragging = false
    private var position = Position.expanded
    private var measuredContentHeight: CGFloat = 0
    private var lastLayoutDiagnostic: String?
    private var lastReportedTop: CGFloat = -.greatestFiniteMagnitude

    private let grabberHeight: CGFloat = 28
    private let minimumTopClearance: CGFloat = 24
    private let compactPanelTargetWidth: CGFloat = 272
    private let nativeBarOverlap: CGFloat = 9
    private let maximumExpandedWidth: CGFloat = 620
    private let viewportMargin: CGFloat = 12
    private let maximumBottomInset: CGFloat = 18
    private let contentTopPadding: CGFloat = 8
    private let contentBottomPadding: CGFloat = 14

    init(controls: AnyView) {
        controlsHost = UIHostingController(rootView: controls)
        if #available(iOS 26.0, *) {
            effectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = PanelPassthroughView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configurePanel()
        configureControlsHost()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateMeasuredContentHeight()
        updatePanelMetrics(preservePresentedHeight: isDragging || settleAnimator?.state == .active)
        reportPanelTop()
    }

    deinit {
        topDisplayLink?.invalidate()
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        guard container === controlsHost else { return }
        scheduleMeasurement()
    }

    func update(controls: AnyView) {
        loadViewIfNeeded()
        controlsHost.rootView = controls
        controlsHost.view.invalidateIntrinsicContentSize()
        scheduleMeasurement()
    }

    func refreshPanelTop() {
        lastReportedTop = -.greatestFiniteMagnitude
        if isViewLoaded { reportPanelTop() }
    }

    func expand() {
        loadViewIfNeeded()
        guard position != .expanded || settleAnimator != nil || isDragging else { return }
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            position = .expanded
            grabber.accessibilityValue = position.rawValue
            return
        }
        settle(to: .expanded)
    }

    private func configurePanel() {
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.clipsToBounds = true
        effectView.layer.cornerCurve = .continuous
        view.addSubview(effectView)

        panelBottomConstraint = effectView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        panelHeightConstraint = effectView.heightAnchor.constraint(equalToConstant: 300)
        panelWidthConstraint = effectView.widthAnchor.constraint(equalToConstant: compactPanelTargetWidth)
        NSLayoutConstraint.activate([
            effectView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panelBottomConstraint,
            panelHeightConstraint,
            panelWidthConstraint,
        ])

        let content = effectView.contentView
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.isAccessibilityElement = true
        grabber.accessibilityLabel = "Controls panel"
        grabber.accessibilityHint = "Swipe up or down to resize."
        grabber.accessibilityIdentifier = "overland.panel.grabber"
        grabber.accessibilityTraits = [.adjustable, .button]
        grabber.accessibilityValue = position.rawValue
        grabber.onIncrement = { [weak self] in self?.settle(to: .expanded) }
        grabber.onDecrement = { [weak self] in self?.settle(to: .collapsed) }
        grabber.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .touchUpInside)
        content.addSubview(grabber)

        grabberMark.translatesAutoresizingMaskIntoConstraints = false
        grabberMark.backgroundColor = .tertiaryLabel
        grabberMark.layer.cornerRadius = 2.5
        grabberMark.isUserInteractionEnabled = false
        grabber.addSubview(grabberMark)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = true
        content.addSubview(scrollView)

        reservedTabRegion.translatesAutoresizingMaskIntoConstraints = false
        reservedTabRegion.isUserInteractionEnabled = false
        content.addSubview(reservedTabRegion)

        controlsHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        reservedHeightConstraint = reservedTabRegion.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            grabber.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grabber.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            grabber.topAnchor.constraint(equalTo: content.topAnchor),
            grabber.heightAnchor.constraint(equalToConstant: grabberHeight),

            grabberMark.centerXAnchor.constraint(equalTo: grabber.centerXAnchor),
            grabberMark.centerYAnchor.constraint(equalTo: grabber.topAnchor, constant: 8.5),
            grabberMark.widthAnchor.constraint(equalToConstant: 42),
            grabberMark.heightAnchor.constraint(equalToConstant: 5),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: grabber.bottomAnchor),
            controlsHeightConstraint,

            reservedTabRegion.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            reservedTabRegion.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            reservedTabRegion.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            reservedTabRegion.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            reservedHeightConstraint,
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        grabber.addGestureRecognizer(pan)
    }

    private func configureControlsHost() {
        controlsHost.safeAreaRegions = []
        addChild(controlsHost)
        controlsHost.view.translatesAutoresizingMaskIntoConstraints = false
        controlsHost.view.backgroundColor = .clear
        controlsHost.view.isOpaque = false
        controlsHost.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        scrollView.addSubview(controlsHost.view)
        controlsWidthConstraint = controlsHost.view.widthAnchor.constraint(equalToConstant: maximumExpandedWidth)
        NSLayoutConstraint.activate([
            controlsHost.view.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            controlsHost.view.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: contentTopPadding
            ),
            controlsHost.view.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -(contentBottomPadding + nativeBarOverlap)
            ),
            controlsWidthConstraint,
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        controlsHost.didMove(toParent: self)
    }

    private func scheduleMeasurement() {
        guard !measurementScheduled else { return }
        measurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            measurementScheduled = false
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    private func updateMeasuredContentHeight() {
        guard view.bounds.width > 0 else { return }
        let fittingWidth = expandedWidth()
        controlsWidthConstraint.constant = fittingWidth
        let fitting = controlsHost.sizeThatFits(
            in: CGSize(width: fittingWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let height = ceil(fitting.height + contentTopPadding + contentBottomPadding + nativeBarOverlap)
        guard height.isFinite, abs(height - measuredContentHeight) > 0.5 else { return }
        measuredContentHeight = height
    }

    private func windowBottomInset() -> CGFloat {
        view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
    }

    private func panelBottomInset() -> CGFloat {
        min(maximumBottomInset, windowBottomInset())
    }

    private func nativeTabReservedHeight() -> CGFloat {
        let safeBottom = windowBottomInset()
        if #available(iOS 26.0, *), let tabs = tabBarController {
            let frame = tabs.contentLayoutGuide.layoutFrame
            if frame.width > 0, frame.height > 0, frame.maxY > 0 {
                let surface = max(0, tabs.view.bounds.maxY - safeBottom - frame.maxY)
                return surface + safeBottom
            }
            return max(max(tabs.tabBar.bounds.height, safeBottom), 49)
        }

        let inheritedBottom = view.safeAreaInsets.bottom
        let tabSurface = max(0, inheritedBottom - safeBottom)
        if tabSurface > 0 { return tabSurface + safeBottom }
        return max(tabBarController?.tabBar.bounds.height ?? 49, safeBottom)
    }

    private func panelTabRegionHeight() -> CGFloat {
        max(0, nativeTabReservedHeight() - panelBottomInset() - nativeBarOverlap)
    }

    private func detents() -> (collapsed: CGFloat, expanded: CGFloat, content: CGFloat) {
        let collapsed = grabberHeight + panelTabRegionHeight()
        let availableBottom = view.bounds.height - panelBottomInset()
        let capacity = max(
            0,
            availableBottom - view.safeAreaInsets.top - minimumTopClearance - collapsed
        )
        let content = min(measuredContentHeight, capacity)
        return (collapsed, collapsed + content, content)
    }

    private func updatePanelMetrics(preservePresentedHeight: Bool) {
        guard view.bounds.width > 0, panelHeightConstraint != nil else { return }
        let values = detents()
        let bottomInset = panelBottomInset()
        let reserved = panelTabRegionHeight()
        panelBottomConstraint.constant = -bottomInset
        reservedHeightConstraint.constant = reserved
        controlsWidthConstraint.constant = expandedWidth()
        controlsHeightConstraint.constant = preservePresentedHeight
            ? min(values.content, max(0, panelHeightConstraint.constant - values.collapsed))
            : (position == .expanded ? values.content : 0)

        let overflow = measuredContentHeight > values.content + 0.5
        scrollView.isScrollEnabled = position == .expanded && overflow
        scrollView.accessibilityElementsHidden = position == .collapsed
        scrollView.isUserInteractionEnabled = position == .expanded

        let targetHeight = position == .expanded ? values.expanded : values.collapsed
        if !preservePresentedHeight { panelHeightConstraint.constant = targetHeight }
        panelWidthConstraint.constant = width(for: panelHeightConstraint.constant, detents: values)
        effectView.layer.cornerRadius = cornerRadius(for: panelHeightConstraint.constant, detents: values)

        let diagnostic = String(
            format: "position=%@ panel=%.1fx%.1f bottom=%.1f tabRegion=%.1f measured=%.1f visible=%.1f scroll=%@",
            position.rawValue, panelWidthConstraint.constant, panelHeightConstraint.constant,
            bottomInset, reserved, measuredContentHeight, values.content, overflow ? "yes" : "no"
        )
        if !preservePresentedHeight, diagnostic != lastLayoutDiagnostic {
            lastLayoutDiagnostic = diagnostic
            NSLog("Overland panel %@", diagnostic)
        }
    }

    private func compactWidth() -> CGFloat {
        max(1, min(compactPanelTargetWidth, view.bounds.width - viewportMargin * 2))
    }

    private func expandedWidth() -> CGFloat {
        max(compactWidth(), max(1, min(maximumExpandedWidth, view.bounds.width - viewportMargin * 2)))
    }

    private func width(for height: CGFloat,
                       detents: (collapsed: CGFloat, expanded: CGFloat, content: CGFloat)) -> CGFloat {
        let travel = max(1, detents.expanded - detents.collapsed)
        let progress = min(1, max(0, (height - detents.collapsed) / travel))
        return compactWidth() + (expandedWidth() - compactWidth()) * progress
    }

    private func cornerRadius(for height: CGFloat,
                              detents: (collapsed: CGFloat, expanded: CGFloat, content: CGFloat)) -> CGFloat {
        let collapsedRadius = min(detents.collapsed / 2, compactWidth() / 2)
        let travel = max(1, detents.expanded - detents.collapsed)
        let progress = min(1, max(0, (height - detents.collapsed) / travel))
        return collapsedRadius + (30 - collapsedRadius) * progress
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let values = detents()
        switch gesture.state {
        case .began:
            animationGeneration += 1
            isDragging = true
            let displayed = freezePresentationGeometry()
            dragOriginHeight = min(values.expanded, max(values.collapsed, displayed))
            applyInteractiveHeight(dragOriginHeight, detents: values)
        case .changed:
            let proposed = dragOriginHeight - gesture.translation(in: view).y
            applyInteractiveHeight(min(values.expanded, max(values.collapsed, proposed)), detents: values)
        case .ended, .cancelled, .failed:
            isDragging = false
            let midpoint = (values.collapsed + values.expanded) / 2
            settle(
                to: panelHeightConstraint.constant >= midpoint ? .expanded : .collapsed,
                force: true
            )
        default:
            break
        }
    }

    private func applyInteractiveHeight(
        _ height: CGFloat,
        detents: (collapsed: CGFloat, expanded: CGFloat, content: CGFloat)
    ) {
        UIView.performWithoutAnimation {
            panelHeightConstraint.constant = height
            panelWidthConstraint.constant = width(for: height, detents: detents)
            controlsHeightConstraint.constant = min(detents.content, max(0, height - detents.collapsed))
            effectView.layer.cornerRadius = cornerRadius(for: height, detents: detents)
            view.layoutIfNeeded()
        }
        reportPanelTop()
    }

    private func toggle() {
        settle(to: position == .collapsed ? .expanded : .collapsed)
    }

    private func settle(to newPosition: Position, force: Bool = false) {
        guard force || newPosition != position || settleAnimator != nil || isDragging else { return }
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            position = newPosition
            grabber.accessibilityValue = position.rawValue
            return
        }
        animationGeneration += 1
        let generation = animationGeneration
        _ = freezePresentationGeometry()
        position = newPosition
        scrollView.accessibilityElementsHidden = newPosition == .collapsed
        scrollView.isUserInteractionEnabled = newPosition == .expanded

        let values = detents()
        let targetHeight = newPosition == .expanded ? values.expanded : values.collapsed
        let updates = { [self] in
            panelHeightConstraint.constant = targetHeight
            panelWidthConstraint.constant = width(for: targetHeight, detents: values)
            controlsHeightConstraint.constant = newPosition == .expanded ? values.content : 0
            effectView.layer.cornerRadius = cornerRadius(for: targetHeight, detents: values)
            view.layoutIfNeeded()
        }

        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(updates)
            finishSettle(generation: generation)
            return
        }

        let animator = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.86, animations: updates)
        animator.addCompletion { [weak self] _ in self?.finishSettle(generation: generation) }
        settleAnimator = animator
        startTrackingTop()
        animator.startAnimation()
    }

    private func freezePresentationGeometry() -> CGFloat {
        let displayedHeight = effectView.layer.presentation()?.bounds.height ?? effectView.bounds.height
        let displayedWidth = effectView.layer.presentation()?.bounds.width ?? effectView.bounds.width
        let values = detents()
        settleAnimator?.stopAnimation(true)
        settleAnimator = nil
        stopTrackingTop()

        let wasDragging = isDragging
        isDragging = true
        UIView.performWithoutAnimation {
            panelBottomConstraint.constant = -panelBottomInset()
            panelHeightConstraint.constant = displayedHeight
            panelWidthConstraint.constant = displayedWidth
            reservedHeightConstraint.constant = panelTabRegionHeight()
            controlsHeightConstraint.constant = min(
                values.content,
                max(0, displayedHeight - values.collapsed)
            )
            effectView.layer.cornerRadius = cornerRadius(for: displayedHeight, detents: values)
            view.layoutIfNeeded()
        }
        isDragging = wasDragging
        return displayedHeight
    }

    private func finishSettle(generation: Int) {
        guard generation == animationGeneration else { return }
        settleAnimator = nil
        stopTrackingTop()
        updatePanelMetrics(preservePresentedHeight: false)
        reportPanelTop()
        grabber.accessibilityValue = position.rawValue
        UIAccessibility.post(notification: .layoutChanged, argument: grabber)
    }

    private func startTrackingTop() {
        guard topDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(reportPanelTop))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        topDisplayLink = link
    }

    private func stopTrackingTop() {
        topDisplayLink?.invalidate()
        topDisplayLink = nil
    }

    @objc private func reportPanelTop() {
        guard view.bounds.height > 0, panelHeightConstraint != nil else { return }
        let modelTop = view.bounds.height + panelBottomConstraint.constant - panelHeightConstraint.constant
        let top: CGFloat
        if settleAnimator != nil, let presentationTop = effectView.layer.presentation()?.frame.minY,
           presentationTop > 0 {
            top = presentationTop
        } else {
            top = modelTop
        }
        guard top.isFinite, top > 0, abs(top - lastReportedTop) > 0.5 else { return }
        lastReportedTop = top
        onTopChange?(top)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }
}

private final class PanelPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

private final class AdjustablePanelGrabber: UIControl {
    var onIncrement: (() -> Void)?
    var onDecrement: (() -> Void)?

    override func accessibilityIncrement() {
        onIncrement?()
    }

    override func accessibilityDecrement() {
        onDecrement?()
    }
}
