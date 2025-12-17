import SwiftUI
import AppKit
import Combine

class MenuBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var timerManager: TimerManager?
    private var jiraAPI: JiraAPI?
    private var eventMonitor: Any?

    func setup(timerManager: TimerManager, jiraAPI: JiraAPI) {
        self.timerManager = timerManager
        self.jiraAPI = jiraAPI
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
        observeTimerChanges()
    }

    private func setupPopover() {
        guard let timerManager = timerManager, let jiraAPI = jiraAPI else { return }

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 400, height: 500)
        popover?.behavior = .semitransient
        popover?.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(timerManager)
                .environmentObject(jiraAPI)
        )
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
            statusItem?.length = NSStatusItem.squareLength
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
        switch state {
        case .idle:
            return ""
        case .running:
            return ticketReference.isEmpty ? "" : " \(ticketReference)"
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
              let button = statusItem?.button else { return }

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Install event monitor to detect clicks outside popover
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)

        // Remove event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        statusItem = nil
    }
}