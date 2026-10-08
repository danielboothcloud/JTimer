import AppKit
import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var events: [JiraNotificationEvent] = []
    @Published private(set) var isRefreshing = false

    var unreadCount: Int { events.lazy.filter { !$0.isRead }.count }

    private let defaults = UserDefaults.standard
    private let storageKey = "JTimer.notificationEvents.v1"
    private let initializedKey = "JTimer.notificationsInitialized.v1"
    private let watermarkKey = "JTimer.notificationWatermark.v1"
    private static let maxStoredEvents = 250
    /// Never banner events older than this, even if they look new. Guards
    /// against re-delivering history if persisted state is ever reset.
    private static let maxDeliveryAge: TimeInterval = 60 * 60
    private var pollingTask: Task<Void, Never>?
    private weak var jiraAPI: JiraAPI?
    private let pollInterval: UInt64 = 5 * 60 * 1_000_000_000

    override init() {
        super.init()
        load()
        UNUserNotificationCenter.current().delegate = self
    }

    func start(jiraAPI: JiraAPI) {
        self.jiraAPI = jiraAPI
        guard pollingTask == nil else { return }

        Task { await requestNativeNotificationPermission() }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: self?.pollInterval ?? 300_000_000_000)
            }
        }
    }

    func refresh() async {
        guard !isRefreshing, let jiraAPI, jiraAPI.isAuthenticated,
              let currentUser = jiraAPI.currentUser else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let issues = try await jiraAPI.fetchNotificationCandidates()
            let candidates = extractEvents(from: issues, currentUser: currentUser)
            let isFirstSync = !defaults.bool(forKey: initializedKey)

            // Candidates include the FULL comment/changelog history of every
            // issue touched in the fetch window, but the store keeps only the
            // newest maxStoredEvents. ID-only dedup would therefore classify
            // evicted history as "new" on every poll and re-deliver it forever.
            // The watermark — the newest date we have ever seen — is what
            // decides freshness; anything at or before it is old history.
            let watermark = currentWatermark()
            let knownIDs = Set(events.map(\.id))
            let freshEvents = NotificationFilter.freshEvents(
                candidates: candidates,
                knownIDs: knownIDs,
                watermark: watermark
            )

            if isFirstSync {
                events = candidates.map { event in
                    var event = event
                    event.isRead = true
                    return event
                }
                defaults.set(true, forKey: initializedKey)
            } else if !freshEvents.isEmpty {
                events = (freshEvents + events)
                    .sorted { $0.date > $1.date }
                    .prefix(Self.maxStoredEvents)
                    .map { $0 }
                let deliverable = freshEvents.filter {
                    $0.date > Date().addingTimeInterval(-Self.maxDeliveryAge)
                }
                for event in deliverable.prefix(5) {
                    await deliverNativeNotification(for: event)
                }
            }
            save()
            advanceWatermark(for: candidates)
        } catch {
            print("Failed to refresh notifications: \(error)")
        }
    }

    func markRead(_ id: String) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].isRead = true
        save()
    }

    func markAllRead() {
        for index in events.indices { events[index].isRead = true }
        save()
    }

    func removeAll() {
        events.removeAll()
        save()
    }

    func issueURL(for issueKey: String) -> URL? {
        JiraURLBuilder.issueURL(domain: AppSettings().jiraDomain, issueKey: issueKey)
    }

    private func extractEvents(from issues: [JiraIssue], currentUser: JiraUser) -> [JiraNotificationEvent] {
        var result: [JiraNotificationEvent] = []
        for issue in issues {
            for comment in issue.comments where comment.author.accountId != currentUser.accountId {
                let mentioned = comment.body?.mentions(accountId: currentUser.accountId) == true
                let text = comment.body?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                result.append(JiraNotificationEvent(
                    id: "comment:\(comment.id)", issueKey: issue.key, issueSummary: issue.summary,
                    kind: mentioned ? .mention : .comment,
                    message: text.isEmpty ? "Commented on \(issue.key)" : String(text.prefix(180)),
                    authorName: comment.author.displayName, date: parseJiraDate(comment.created) ?? issue.updated ?? Date(),
                    isRead: false
                ))
            }

            for history in issue.changelog?.histories ?? [] where history.author.accountId != currentUser.accountId {
                let date = parseJiraDate(history.created) ?? issue.updated ?? Date()
                for (index, item) in history.items.enumerated() {
                    let kind: JiraNotificationKind
                    let message: String
                    if item.field.lowercased() == "assignee",
                       item.toString?.localizedCaseInsensitiveCompare(currentUser.displayName) == .orderedSame {
                        kind = .assigned
                        message = "Assigned \(issue.key) to you"
                    } else if item.field.lowercased() == "status" {
                        kind = .status
                        message = "\(item.fromString ?? "Unknown") → \(item.toString ?? "Unknown")"
                    } else {
                        continue
                    }
                    result.append(JiraNotificationEvent(
                        id: "change:\(history.id):\(index)", issueKey: issue.key, issueSummary: issue.summary,
                        kind: kind, message: message, authorName: history.author.displayName, date: date, isRead: false
                    ))
                }
            }
        }
        return result.sorted { $0.date > $1.date }
    }

    private func parseJiraDate(_ value: String) -> Date? {
        JiraDate.parse(value)
    }

    private func requestNativeNotificationPermission() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            print("Unable to request notification permission: \(error)")
        }
    }

    private func deliverNativeNotification(for event: JiraNotificationEvent) async {
        let content = UNMutableNotificationContent()
        content.title = "\(event.kind.title) · \(event.issueKey)"
        content.subtitle = event.issueSummary
        content.body = "\(event.authorName): \(event.message)"
        content.sound = .default
        content.userInfo = ["issueKey": event.issueKey]
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
            )
        } catch {
            print("Unable to deliver notification: \(error)")
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func currentWatermark() -> Date {
        if let stored = defaults.object(forKey: watermarkKey) as? Date { return stored }
        // Migration for installs predating the watermark: seed it from the
        // newest stored event so months-old history is never re-delivered.
        let newest = events.map(\.date).max() ?? .distantPast
        defaults.set(newest, forKey: watermarkKey)
        return newest
    }

    private func advanceWatermark(for candidates: [JiraNotificationEvent]) {
        guard let newest = candidates.map(\.date).max() else { return }
        let stored = defaults.object(forKey: watermarkKey) as? Date ?? .distantPast
        if newest > stored {
            defaults.set(newest, forKey: watermarkKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([JiraNotificationEvent].self, from: data) else { return }
        events = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// Pure freshness logic, extracted for unit testing.
enum NotificationFilter {
    /// Candidates that are genuinely new: strictly newer than the watermark
    /// and not already in the store. Events at or before the watermark are
    /// old history re-fetched with their issue and must never be delivered,
    /// even when the maxStoredEvents cap has evicted them from the store.
    static func freshEvents(
        candidates: [JiraNotificationEvent],
        knownIDs: Set<String>,
        watermark: Date
    ) -> [JiraNotificationEvent] {
        candidates.filter { event in
            event.date > watermark && !knownIDs.contains(event.id)
        }
    }
}
