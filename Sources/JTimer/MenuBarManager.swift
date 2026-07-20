import SwiftUI
import AppKit
import Combine

@MainActor
final class MenuBarManager: NSObject, ObservableObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var timerManager: TimerManager?
    private var jiraAPI: JiraAPI?
    private var notificationManager: NotificationManager?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    func setup(timerManager: TimerManager, jiraAPI: JiraAPI, notificationManager: NotificationManager) {
        guard statusItem == nil else { return }

        self.timerManager = timerManager
        self.jiraAPI = jiraAPI
        self.notificationManager = notificationManager
        setupMenuBar()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            updateMenuBarIcon(for: .idle)
            button.action = #selector(togglePopover)
            button.target = self
        }

        setupPopover()
        setupDismissalHandling()
        observeTimerChanges()
        observeNotificationChanges()
    }

    private func setupPopover() {
        guard let timerManager = timerManager, let jiraAPI = jiraAPI else { return }

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 400, height: 500)
        popover?.behavior = .transient
        popover?.delegate = self
        popover?.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(timerManager)
                .environmentObject(jiraAPI)
                .environmentObject(notificationManager!)
        )
    }

    func popoverWillClose(_ notification: Notification) {
        // Keep the hosting controller and all SwiftUI presentation state alive.
        // Reopening the menu-bar popover restores the exact sheet and draft that
        // was visible before the user clicked elsewhere.
    }

    private func setupDismissalHandling() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover?.isShown == true else { return event }
            let popoverWindow = self.popover?.contentViewController?.view.window
            let statusWindow = self.statusItem?.button?.window
            let isMenuWindow = event.window.map { String(describing: type(of: $0)).localizedCaseInsensitiveContains("menu") } ?? false
            if event.window !== popoverWindow && event.window !== statusWindow && !isMenuWindow {
                self.closePopover()
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }

        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.popover?.isShown == true {
                self?.closePopover()
                return nil
            }
            return event
        }
    }

    deinit {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        if let spaceChangeObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func observeTimerChanges() {
        guard let timerManager = timerManager else { return }

        timerManager.$currentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateMenuBarIcon(for: state)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func observeNotificationChanges() {
        guard let notificationManager else { return }
        notificationManager.$events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let timerManager = self.timerManager else { return }
                self.updateMenuBarIcon(for: timerManager.currentState)
            }
            .store(in: &cancellables)
    }

    private func updateMenuBarIcon(for state: TimerState) {
        guard let button = statusItem?.button else { return }

        // Get current ticket info from timer manager
        let ticketReference = getCurrentTicketReference()

        // Try to load the custom Jira icon first
        if let iconImage = loadMenuBarIcon() {
            // Create a colored icon based on state
            let coloredIcon = createColoredIcon(from: iconImage, for: state)
            button.image = coloredIcon

            // Show ticket reference when actively timing
            let titleText = getTitleText(for: state, ticketReference: ticketReference)
            let titleColor = getTitleColor(for: state)

            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: titleColor,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            ]

            button.attributedTitle = NSAttributedString(string: titleText, attributes: attributes)
        } else {
            // Fallback if icon file not found
            let icon: String
            let color: NSColor

            switch state {
            case .idle:
                icon = "⏱"
                color = .controlTextColor
            case .running:
                icon = ticketReference
                color = .systemRed
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            ]

            button.image = nil
            button.attributedTitle = NSAttributedString(string: icon, attributes: attributes)
        }

        // Adjust status item length to accommodate text
        switch state {
        case .idle:
            statusItem?.length = (notificationManager?.unreadCount ?? 0) > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        case .running:
            if !ticketReference.isEmpty {
                statusItem?.length = NSStatusItem.variableLength
            } else {
                statusItem?.length = NSStatusItem.squareLength
            }
        }
    }

    private func getCurrentTicketReference() -> String {
        guard let timerManager = timerManager,
              let currentIssue = timerManager.currentIssue else {
            return ""
        }
        return currentIssue.key
    }

    private func getTitleText(for state: TimerState, ticketReference: String) -> String {
        let unread = notificationManager?.unreadCount ?? 0
        let badge = unread > 0 ? " \(min(unread, 99))" : ""
        switch state {
        case .idle:
            return badge
        case .running:
            return ticketReference.isEmpty ? badge : " \(ticketReference)\(badge)"
        }
    }

    private func getTitleColor(for state: TimerState) -> NSColor {
        // Always use neutral color for ticket reference text
        // Only the icon changes color to indicate state
        return .controlTextColor
    }

    private func loadMenuBarIcon() -> NSImage? {
        // Try to load from bundle resources
        if let iconPath = Bundle.main.path(forResource: "menubar-icon", ofType: "png") {
            return NSImage(contentsOfFile: iconPath)
        }

        // Fallback: try to load from app bundle
        let appPath = Bundle.main.bundlePath
        let iconPath = "\(appPath)/Contents/Resources/menubar-icon.png"
        if FileManager.default.fileExists(atPath: iconPath) {
            return NSImage(contentsOfFile: iconPath)
        }

        return nil
    }

    private func resizeImageForMenuBar(_ image: NSImage) -> NSImage {
        let targetSize = NSSize(width: 18, height: 18)
        let resizedImage = NSImage(size: targetSize)

        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        resizedImage.unlockFocus()

        return resizedImage
    }

    private func createColoredIcon(from image: NSImage, for state: TimerState) -> NSImage {
        let resizedImage = resizeImageForMenuBar(image)

        switch state {
        case .idle:
            // Use template image for normal menu bar appearance
            resizedImage.isTemplate = true
            return resizedImage
        case .running:
            // Create red tinted version
            return tintImage(resizedImage, with: .systemRed)
        }
    }

    private func tintImage(_ image: NSImage, with color: NSColor) -> NSImage {
        let tintedImage = NSImage(size: image.size)

        tintedImage.lockFocus()

        // Draw the original image
        image.draw(in: NSRect(origin: .zero, size: image.size))

        // Apply color overlay
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)

        tintedImage.unlockFocus()

        // Don't make it a template - we want to keep our custom color
        tintedImage.isTemplate = false

        return tintedImage
    }

    @objc private func togglePopover() {
        guard let popover = popover else { return }

        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let popover = popover,
              let button = statusItem?.button,
              button.window != nil else { return }

        // Let AppKit derive the correct screen and anchor from the status-item
        // button. Manual positioning can retain stale multi-display geometry.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover() {
        popover?.close()
    }
}
