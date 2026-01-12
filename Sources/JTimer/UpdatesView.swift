import SwiftUI

struct UpdatesView: View {
    @Binding var issues: [JiraIssue]
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
                    Text("Issues assigned to you or mentioning you updated in the last 3 days will appear here")
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
                            UpdateRowView(issue: issue) {
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
    let onSelect: () -> Void

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(issue.key)
                        .font(.caption.bold())
                        .foregroundColor(.blue)

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
