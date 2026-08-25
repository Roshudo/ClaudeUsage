import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let coloredIconDefaultsKey = "MenuBarIconColored"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let colorToggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let viewModel: UsageViewModel

    private var isColoredIconEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.coloredIconDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.coloredIconDefaultsKey) }
    }

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init()
        configureStatusItem()
        configureMenu()
        configurePopover()
        observeViewModel()
        viewModel.start()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureMenu() {
        menu.delegate = self

        let refreshItem = NSMenuItem(
            title: String(localized: "Refresh"),
            action: #selector(refreshTapped),
            keyEquivalent: ""
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        colorToggleItem.title = String(localized: "Colored Menu Bar Icon")
        colorToggleItem.action = #selector(toggleColoredIconTapped)
        colorToggleItem.target = self
        colorToggleItem.state = isColoredIconEnabled ? .on : .off
        menu.addItem(colorToggleItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit"),
            action: #selector(quitTapped),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView().environment(viewModel)
        )
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    // NSStatusItem shows its `.menu` for any click once set, so the menu is
    // attached only for the right-click and detached again once it closes —
    // otherwise left clicks would show the menu too instead of the popover.
    private func showMenu() {
        statusItem.menu = menu
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func refreshTapped() {
        Task { await viewModel.refresh() }
    }

    @objc private func toggleColoredIconTapped() {
        isColoredIconEnabled.toggle()
        colorToggleItem.state = isColoredIconEnabled ? .on : .off
        updateStatusItemAppearance()
    }

    @objc private func quitTapped() {
        NSApplication.shared.terminate(nil)
    }

    private func observeViewModel() {
        withObservationTracking {
            _ = viewModel.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusItemAppearance()
                self?.observeViewModel()
            }
        }
        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        let active = activeWindow()
        let tint = isColoredIconEnabled ? tintColor(for: active?.window.utilization) : nil

        button.image = statusImage(systemName: active?.icon ?? "clock", tint: tint)

        guard let window = active?.window else {
            button.title = ""
            return
        }
        let title = " \(Int(window.utilization.rounded()))%"
        if let tint {
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: tint]
            )
        } else {
            button.title = title
        }
    }

    // Plain template images auto-adapt to the menu bar's light/dark
    // appearance. Warning colors need a non-template image with the color
    // baked in — NSStatusBarButton doesn't reliably apply contentTintColor.
    private func statusImage(systemName: String, tint: NSColor?) -> NSImage? {
        guard let baseImage = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return nil
        }
        guard let tint else {
            baseImage.isTemplate = true
            return baseImage
        }
        let configuration = NSImage.SymbolConfiguration(paletteColors: [tint])
        let coloredImage = baseImage.withSymbolConfiguration(configuration)
        coloredImage?.isTemplate = false
        return coloredImage
    }

    private func activeWindow() -> (icon: String, window: UsageWindow)? {
        guard case .loaded(let snapshot) = viewModel.state else { return nil }
        if snapshot.sevenDay.utilization > snapshot.fiveHour.utilization {
            return ("calendar", snapshot.sevenDay)
        } else {
            return ("clock", snapshot.fiveHour)
        }
    }

    // Derives from `UsageLevel`, the same source `UsagePopoverView` uses, so
    // threshold/color changes only need to happen in one place. `.normal`
    // stays untinted here so the icon keeps the default template appearance
    // when usage isn't a concern.
    private func tintColor(for utilization: Double?) -> NSColor? {
        guard let utilization else { return nil }
        let level = UsageLevel(utilization: utilization)
        guard level != .normal else { return nil }
        return NSColor(level.color)
    }
}
