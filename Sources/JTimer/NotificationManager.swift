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
            let knownIDs = Set(events.map(\.id))
            let newEvents = candidates.filter { !knownIDs.contains($0.id) }
            let isFirstSync = !defaults.bool(forKey: initializedKey)

            if isFirstSync {
                events = candidates.map { event in
                    var event = event
                    event.isRead = true
                    return event
                }
                defaults.set(true, forKey: initializedKey)
            } else if !newEvents.isEmpty {
                events = (newEvents + events)
                    .sorted { $0.date > $1.date }
                    .prefix(250)
                    .map { $0 }
                for event in newEvents.prefix(5) {
                    await deliverNativeNotification(for: event)
                }
            }
            save()
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
        let domain = AppSettings().jiraDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let root: String
        if domain.hasPrefix("https://") || domain.hasPrefix("http://") {
            root = domain
        } else if domain.contains("atlassian.net") || domain.contains("atlassian.com") {
            root = "https://\(domain)"
        } else {
            root = "https://\(domain).atlassian.net"
        }
        return URL(string: "\(root)/browse/\(issueKey)")
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
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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
