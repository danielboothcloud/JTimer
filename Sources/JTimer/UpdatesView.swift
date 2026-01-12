import SwiftUI

struct UpdatesView: View {
    @Binding var issues: [JiraIssue]
    let currentUser: JiraUser?
    let onSelect: (JiraIssue) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Recent Updates")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if issues.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No recent updates")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Issues assigned to you or mentioning you updated by others will appear here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(issues) { issue in
                            UpdateRowView(issue: issue, currentUser: currentUser) {
                                onSelect(issue)
                                dismiss()
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

struct UpdateRowView: View {
    let issue: JiraIssue
    let currentUser: JiraUser?
    let onSelect: () -> Void

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }
    
    private var issueURL: URL? {
        let settings = AppSettings()
        let domain = settings.jiraDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL: String

        if domain.contains("atlassian.net") || domain.contains("atlassian.com") {
            baseURL = "https://\(domain)"
        } else if domain.hasPrefix("https://") || domain.hasPrefix("http://") {
            baseURL = domain
        } else {
            baseURL = "https://\(domain).atlassian.net"
        }

        return URL(string: "\(baseURL)/browse/\(issue.key)")
    }
    
    private var contextInfo: (text: String, icon: String, color: Color) {
        // 1. Check for new comments first (highest priority)
        if let lastComment = issue.comments.last {
            if let user = currentUser, lastComment.author.accountId != user.accountId {
                return ("Comment by \(lastComment.author.displayName)", "bubble.left.fill", .orange)
            }
        }
        
        // 2. Check changelog for status or assignment changes
        if let changelog = issue.changelog, let latestHistory = changelog.histories.last {
            // Only show if it's not by current user
            if let user = currentUser, latestHistory.author.accountId != user.accountId {
                // Find most interesting item (prefer status)
                let items = latestHistory.items
                if let statusItem = items.first(where: { $0.field == "status" }) {
                    return ("Status: \(statusItem.toString ?? "Updated")", "arrow.left.arrow.right", .purple)
                }
                
                if let assigneeItem = items.first(where: { $0.field == "assignee" }) {
                    if let toString = assigneeItem.toString, toString == user.displayName {
                        return ("Assigned to you", "person.badge.plus", .blue)
                    }
                    return ("Reassigned", "person.2.fill", .secondary)
                }
                
                if items.contains(where: { $0.field == "description" }) {
                    return ("Description updated", "doc.text.fill", .secondary)
                }
                
                if items.contains(where: { $0.field == "summary" }) {
                    return ("Title updated", "pencil.and.outline", .secondary)
                }
                
                if let anyItem = items.first {
                    return ("\(anyItem.field.capitalized) updated", "pencil", .secondary)
                }
            }
        }
        
        // 3. Fallback to assigned logic (if no changelog match)
        if let assignee = issue.assignee, let user = currentUser, assignee == user.displayName {
             // If created recently (less than 3 days), it's a new ticket
             if let created = issue.created, Date().timeIntervalSince(created) < 86400 * 3 {
                 return ("New Ticket", "sparkles", .green)
             }
             // Otherwise, it's an update on a ticket assigned to you
             return ("Assigned to you", "person.fill.checkmark", .blue)
        }
        
        // 4. Default
        return ("Updated", "pencil", .secondary)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(issue.key)
                        .font(.caption.bold())
                        .foregroundColor(.blue)

                    Button(action: {
                        if let url = issueURL {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(issue.key) in browser")

                    Spacer()

                    if let updated = issue.updated {
                        Text(dateFormatter.string(from: updated))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Text(issue.summary)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                // Context Row
                HStack(spacing: 4) {
                    Image(systemName: contextInfo.icon)
                        .font(.caption2)
                        .foregroundColor(contextInfo.color)
                    Text(contextInfo.text)
                        .font(.caption2)
                        .foregroundColor(contextInfo.color)
                    
                    Spacer()
                }
                .padding(.vertical, 2)

                HStack {
                    Text(issue.status)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if let assignee = issue.assignee {
                         Text(assignee)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
