import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let coloredIconDefaultsKey = "MenuBarIconColored"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let colorToggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let percentMetricItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let paceMetricItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
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

        let metricItem = NSMenuItem(title: String(localized: "Menu Bar Metric"), action: nil, keyEquivalent: "")
        let metricSubmenu = NSMenu()

        percentMetricItem.title = String(localized: MenuBarMetric.percent.title)
        percentMetricItem.action = #selector(selectPercentMetricTapped)
        percentMetricItem.target = self
        metricSubmenu.addItem(percentMetricItem)

        paceMetricItem.title = String(localized: MenuBarMetric.pace.title)
        paceMetricItem.action = #selector(selectPaceMetricTapped)
        paceMetricItem.target = self
        metricSubmenu.addItem(paceMetricItem)

        metricItem.submenu = metricSubmenu
        menu.addItem(metricItem)

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

    // Checkmarks reflect state that can change from outside the menu item
    // actions themselves (there is none right now besides these items, but
    // this keeps the menu honest if that changes), so they're refreshed
    // right before the menu is shown rather than only when toggled.
    func menuWillOpen(_ menu: NSMenu) {
        colorToggleItem.state = isColoredIconEnabled ? .on : .off
        percentMetricItem.state = viewModel.menuBarMetric == .percent ? .on : .off
        paceMetricItem.state = viewModel.menuBarMetric == .pace ? .on : .off
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

    @objc private func selectPercentMetricTapped() {
        viewModel.menuBarMetric = .percent
        updateStatusItemAppearance()
    }

    @objc private func selectPaceMetricTapped() {
        viewModel.menuBarMetric = .pace
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
        let level = displayLevel(for: active)
        let tint = isColoredIconEnabled ? tintColor(for: level) : nil

        button.image = statusImage(tint: tint)

        guard let active else {
            button.title = ""
            return
        }
        let valueText = metricText(for: active.window, duration: active.duration)
        let title: String
        if let resetsAt = active.window.resetsAt {
            title = " " + valueText + "·" + compactResetText(until: resetsAt)
        } else {
            title = " " + valueText
        }
        // Number and icon share the same tint, including staying neutral at
        // "normal"/green — under 50% (or under pace) isn't concerning yet,
        // so drawing less attention to it is the right call.
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
    private func statusImage(tint: NSColor?) -> NSImage? {
        guard let baseImage = NSImage(named: "MenuBarLogo") else { return nil }
        guard let tint else {
            baseImage.isTemplate = true
            return baseImage
        }
        return tintedImage(baseImage, color: tint)
    }

    // Manual tint since this is a bitmap template image, not an SF Symbol —
    // `NSImage.SymbolConfiguration` only applies to symbol images.
    private func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = image.copy() as! NSImage
        tinted.lockFocus()
        color.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    // Coarsest single unit only, so the menu bar title stays short — e.g.
    // "5d" for the weekly limit, "4h" or "45m" for the 5-hour limit, never
    // a combined "4h 30m". `Duration`'s narrow-width units style already
    // localizes the unit letter itself (e.g. "5T" in German), so no manual
    // translation is needed here.
    private func compactResetText(until date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return String(localized: "now") }
        return Duration.seconds(Int(interval.rounded()))
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 1, zeroValueUnits: .show(length: 1)))
    }

    // Picks whichever window is more pressing, in whichever unit the
    // selected metric measures pressure with — the highest percentage when
    // showing percent, the highest pace when showing pace. Also returns
    // that window's fixed duration, since pace needs it and percent alone
    // can't tell a 5-hour window from a weekly one.
    private func activeWindow() -> (window: UsageWindow, duration: TimeInterval)? {
        guard case .loaded(let snapshot) = viewModel.state else { return nil }
        let five = (window: snapshot.fiveHour, duration: UsageSnapshot.fiveHourDuration)
        let seven = (window: snapshot.sevenDay, duration: UsageSnapshot.sevenDayDuration)

        switch viewModel.menuBarMetric {
        case .percent:
            return seven.window.utilization > five.window.utilization ? seven : five
        case .pace:
            let fivePace = five.window.pace(windowDuration: five.duration)
            let sevenPace = seven.window.pace(windowDuration: seven.duration)
            switch (fivePace, sevenPace) {
            case let (fivePace?, sevenPace?):
                return sevenPace > fivePace ? seven : five
            case (nil, .some):
                return seven
            case (.some, nil):
                return five
            case (nil, nil):
                // Neither window has a usable pace (e.g. just reset) — fall
                // back to percent so the menu bar still shows something sensible.
                return seven.window.utilization > five.window.utilization ? seven : five
            }
        }
    }

    private func metricText(for window: UsageWindow, duration: TimeInterval) -> String {
        switch viewModel.menuBarMetric {
        case .percent:
            return percentText(window.utilization)
        case .pace:
            guard let pace = window.pace(windowDuration: duration) else {
                return percentText(window.utilization)
            }
            return paceText(pace)
        }
    }

    // Some locales (e.g. German) insert a space before "%", which is too
    // wide for the menu bar — strip it to keep the compact "28%" form.
    private func percentText(_ utilization: Double) -> String {
        (utilization / 100)
            .formatted(.percent.precision(.fractionLength(0)))
            .components(separatedBy: .whitespaces)
            .joined()
    }

    private func paceText(_ pace: Double) -> String {
        pace.formatted(.number.precision(.fractionLength(1))) + "×"
    }

    // Derives from `UsageLevel`, the same source `UsagePopoverView` uses, so
    // threshold/color changes only need to happen in one place. `.normal`
    // stays untinted here so the icon keeps the default template appearance
    // when usage isn't a concern.
    private func displayLevel(for active: (window: UsageWindow, duration: TimeInterval)?) -> UsageLevel? {
        guard let active else { return nil }
        switch viewModel.menuBarMetric {
        case .percent:
            return UsageLevel(utilization: active.window.utilization)
        case .pace:
            guard let pace = active.window.pace(windowDuration: active.duration) else {
                return UsageLevel(utilization: active.window.utilization)
            }
            return UsageLevel(pace: pace)
        }
    }

    private func tintColor(for level: UsageLevel?) -> NSColor? {
        guard let level, level != .normal else { return nil }
        return NSColor(level.color)
    }
}
