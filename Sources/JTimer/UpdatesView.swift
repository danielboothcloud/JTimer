import SwiftUI

struct UpdatesView: View {
    @ObservedObject var notificationManager: NotificationManager
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications").font(.headline)
                    Text("\(notificationManager.unreadCount) unread")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if notificationManager.isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await notificationManager.refresh() } }
                    .controlSize(.small)
                Button("Mark All Read") { notificationManager.markAllRead() }
                    .controlSize(.small)
                    .disabled(notificationManager.unreadCount == 0)
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding()

            Divider()

            if notificationManager.events.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 48)).foregroundColor(.secondary)
                    Text("No notifications").font(.headline).foregroundColor(.secondary)
                    Text("Comments, mentions, assignments and status changes will appear here.")
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(notificationManager.events) { event in
                            NotificationEventRow(event: event) {
                                notificationManager.markRead(event.id)
                                if let url = notificationManager.issueURL(for: event.issueKey) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 400, height: 500)
        .background(VisualEffectView())
    }
}

private struct NotificationEventRow: View {
    let event: JiraNotificationEvent
    let action: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: event.kind.systemImage)
                    .frame(width: 22)
                    .foregroundColor(color)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(event.kind.title).font(.caption.bold())
                        Text("· \(event.issueKey)").font(.caption.bold()).foregroundColor(.blue)
                        Spacer()
                        Text(Self.relativeFormatter.localizedString(for: event.date, relativeTo: Date()))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Text(event.issueSummary).font(.caption).lineLimit(1)
                    Text(event.message).font(.caption).foregroundColor(.secondary).lineLimit(3)
                    Text(event.authorName).font(.caption2).foregroundColor(.secondary)
                }
                if !event.isRead {
                    Circle().fill(Color.blue).frame(width: 8, height: 8).padding(.top, 4)
                }
            }
            .padding(10)
            .background(event.isRead ? Color.secondary.opacity(0.05) : Color.blue.opacity(0.10))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch event.kind {
        case .mention: return .red
        case .comment: return .orange
        case .assigned: return .blue
        case .status: return .purple
        case .updated: return .secondary
        }
    }
}
