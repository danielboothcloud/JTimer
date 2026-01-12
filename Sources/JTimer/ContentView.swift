import SwiftUI
import AppKit

struct TimerResult: Identifiable {
    let id = UUID()
    let issue: JiraIssue
    let startTime: Date
    let duration: TimeInterval
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var timerManager: TimerManager
    @EnvironmentObject var jiraAPI: JiraAPI
    @State private var issues: [JiraIssue] = []
    @State private var filteredIssues: [JiraIssue] = []
    @State private var searchText = ""
    @State private var customJQL = ""
    @State private var isLoadingIssues = false
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var selectedIssue: JiraIssue?
    @State private var lastError: String?
    @State private var currentQuery = ""
    @State private var lastResultCount = 0
    @State private var pendingTimerResult: TimerResult?
    @State private var pendingDescription: String = ""
    @State private var timeLogHistory: [TimeLogEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if jiraAPI.isAuthenticated {
                mainContent
            } else {
                authenticationPrompt
            }
        }
        .frame(width: 400, height: 500)
        .onAppear {
            loadIssuesIfNeeded()
            loadLogHistory()
        }
        .sheet(item: $pendingTimerResult) { result in
            LogConfirmationView(
                timerResult: result,
                jiraDomain: AppSettings().jiraDomain,
                initialDescription: pendingDescription,
                onConfirm: { adjustedDuration, description, alsoAddAsComment in
                    Task {
                        await logWorkToJira(
                            issue: result.issue,
                            startTime: result.startTime,
                            duration: adjustedDuration,
                            comment: description,
                            alsoAddAsComment: alsoAddAsComment
                        )
                    }
                    pendingTimerResult = nil
                    pendingDescription = ""
                },
                onCancel: {
                    pendingTimerResult = nil
                    pendingDescription = ""
                }
            )
        }
    }

    private var headerView: some View {
        HStack {
            Text("JTimer")
                .font(.headline)
                .foregroundColor(.primary)

            Spacer()

            if let currentIssue = timerManager.currentIssue {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(currentIssue.key)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(timerManager.formattedElapsedTime())
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.primary)
                }
            }

            Button(action: { showingHistory = true }) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .help("View time log history")

            Button(action: { showingSettings = true }) {
                Image(systemName: "gear")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding()
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(jiraAPI)
        }
        .sheet(isPresented: $showingHistory) {
            LogHistoryView(
                logs: $timeLogHistory,
                onEditLog: { log in
                    showingHistory = false
                    pendingDescription = log.description
                    // Create a timer result from the log entry
                    if let issue = issues.first(where: { $0.key == log.issueKey }) {
                        pendingTimerResult = TimerResult(
                            issue: issue,
                            startTime: log.startTime,
                            duration: log.duration
                        )
                    }
                }
            )
        }
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            searchAndFilterSection

            // Status info bar
            if !currentQuery.isEmpty || lastResultCount > 0 {
                HStack {
                    Text("Query: \(currentQuery.isEmpty ? "Default" : currentQuery)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if !isLoadingIssues {
                        Text("\(lastResultCount) result\(lastResultCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }

            if isLoadingIssues {
                ProgressView("Loading issues...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                issueList
            }

            Divider()
            timerControls

            Divider()
            quitSection
        }
        .padding(.horizontal)
    }

    private var searchAndFilterSection: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search issues...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: searchText) { _ in
                        filterIssues()
                    }

                Button("Refresh") {
                    Task {
                        await loadIssues()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.top, 4)

            HStack {
                Menu {
                    ForEach(JQLTemplate.commonTemplates, id: \.name) { template in
                        Button(action: {
                            customJQL = template.query
                            Task {
                                await loadIssues(jql: template.query)
                            }
                        }) {
                            VStack(alignment: .leading) {
                                Text(template.name)
                                    .font(.caption)
                                Text(template.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Divider()

                    Button("Clear Query") {
                        customJQL = ""
                        Task {
                            await loadIssues()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "list.bullet")
                        Text("Templates")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                TextField("Custom JQL", text: $customJQL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task {
                            await loadIssues(jql: customJQL)
                        }
                    }

                Button("Apply") {
                    Task {
                        await loadIssues(jql: customJQL)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var issueList: some View {
        ScrollView {
            if isLoadingIssues {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading issues...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if let error = lastError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.orange)

                    Text("Error Loading Issues")
                        .font(.headline)

                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Retry") {
                        Task {
                            await loadIssues()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if filteredIssues.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)

                    Text("No Issues Found")
                        .font(.headline)

                    if !currentQuery.isEmpty {
                        Text("Query: \(currentQuery)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }

                    VStack(spacing: 8) {
                        Text("Try these suggestions:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("All My Issues") {
                            Task {
                                await loadIssues(jql: "assignee = currentUser()")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Recent Issues") {
                            Task {
                                await loadIssues(jql: "assignee = currentUser() ORDER BY updated DESC")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(filteredIssues) { issue in
                        IssueRowView(
                            issue: issue,
                            isSelected: selectedIssue?.id == issue.id,
                            onSelect: { selectedIssue = issue }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var timerControls: some View {
        HStack {
            Spacer()

            if timerManager.isRunning {
                Button("Stop & Log") {
                    Task {
                        await stopAndLogTime()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button("Start Timer") {
                    if let issue = selectedIssue {
                        timerManager.startTimer(for: issue)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIssue == nil)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var quitSection: some View {
        HStack {
            Spacer()
            Button("Quit JTimer") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.top, 4)
        .padding(.bottom)
    }

    private var authenticationPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key.fill")
                .font(.largeTitle)
                .foregroundColor(.secondary)

            Text("Configure Jira Connection")
                .font(.headline)

            Text("Go to Settings to configure your Jira domain and API token")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Button("Open Settings") {
                showingSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func loadIssuesIfNeeded() {
        if jiraAPI.isAuthenticated && issues.isEmpty {
            Task {
                await loadIssues()
            }
        }
    }

    private func loadIssues(jql: String? = nil) async {
        await MainActor.run {
            isLoadingIssues = true
            lastError = nil
        }

        defer {
            Task { @MainActor in
                isLoadingIssues = false
            }
        }

        // Define fallback queries to try if no custom JQL provided
        let fallbackQueries = [
            "assignee = currentUser() AND status NOT IN (Done, Complete, Resolved, Closed)",
            "assignee = currentUser() AND status != Done",
            "assignee = currentUser()",
            "assignee = currentUser() ORDER BY updated DESC"
        ]

        let queriesToTry = jql != nil ? [jql!] : fallbackQueries

        for (index, queryJQL) in queriesToTry.enumerated() {
            do {
                print("🔍 JTimer: Trying JQL query: \(queryJQL)")

                let fetchedIssues = try await jiraAPI.searchIssues(jql: queryJQL)

                await MainActor.run {
                    issues = fetchedIssues
                    currentQuery = queryJQL
                    lastResultCount = fetchedIssues.count
                    lastError = nil
                    filterIssues()
                }

                print("✅ JTimer: Found \(fetchedIssues.count) issues with query: \(queryJQL)")

                // If we found issues or this was a custom query, stop trying
                if !fetchedIssues.isEmpty || jql != nil {
                    return
                }

                // If no issues found but this wasn't the last fallback, continue
                if index < queriesToTry.count - 1 {
                    print("⚠️ JTimer: No issues found, trying next query...")
                    continue
                }

            } catch {
                print("🚨 JTimer: Query failed: \(error)")

                await MainActor.run {
                    currentQuery = queryJQL
                    lastError = error.localizedDescription

                    // If this was a custom query or the last fallback, show the error
                    if jql != nil || index == queriesToTry.count - 1 {
                        issues = []
                        filteredIssues = []
                        return
                    }
                }

                // Try next fallback query
                continue
            }
        }
    }

    private func filterIssues() {
        if searchText.isEmpty {
            filteredIssues = issues
        } else {
            filteredIssues = issues.filter { issue in
                issue.key.localizedCaseInsensitiveContains(searchText) ||
                issue.summary.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private func stopAndLogTime() async {
        guard let timerResult = timerManager.stopTimer() else { return }

        await MainActor.run {
            pendingTimerResult = TimerResult(
                issue: timerResult.issue,
                startTime: timerResult.startTime,
                duration: timerResult.duration
            )
        }
    }

    private func logWorkToJira(issue: JiraIssue, startTime: Date, duration: TimeInterval, comment: String? = nil, alsoAddAsComment: Bool = false) async {
        do {
            let timeInSeconds = Int(duration)
            print("⏱️ JTimer: Logging \(timeInSeconds) seconds (\(timeInSeconds/60) minutes) to \(issue.key)")

            try await jiraAPI.logWork(
                issueKey: issue.key,
                timeSpentSeconds: timeInSeconds,
                startTime: startTime,
                comment: comment
            )

            print("✅ JTimer: Work logged successfully")

            // Also add as comment if checkbox is checked and there's a comment
            if alsoAddAsComment, let commentText = comment, !commentText.isEmpty {
                print("💬 JTimer: Adding comment to \(issue.key)...")
                try await jiraAPI.postComment(
                    issueKey: issue.key,
                    comment: commentText
                )
            }

            // Refresh history from Jira
            loadLogHistory()
        } catch {
            print("Failed to log work: \(error)")
        }
    }

    private func saveLogHistory() {
        // No longer needed - we fetch from Jira
    }

    private func loadLogHistory() {
        Task {
            do {
                let worklogs = try await jiraAPI.fetchRecentWorklogs()
                await MainActor.run {
                    timeLogHistory = worklogs
                }
            } catch {
                print("Failed to load worklogs: \(error)")
            }
        }
    }
}

struct IssueRowView: View {
    let issue: JiraIssue
    let isSelected: Bool
    let onSelect: () -> Void

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

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(issue.key)
                            .font(.caption.bold())
                            .foregroundColor(.blue)

                        Text(issue.issueType)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)

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
                    }

                    Text(issue.summary)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.primary)

                    HStack {
                        Text(issue.status)
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Spacer()

                        if let assignee = issue.assignee {
                            Text(assignee)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding(8)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
        )
    }
}

struct LogConfirmationView: View {
    let timerResult: TimerResult
    let jiraDomain: String
    let onConfirm: (TimeInterval, String, Bool) -> Void
    let onCancel: () -> Void

    @State private var hours: Int
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var workDescription: String = ""
    @State private var alsoAddAsComment: Bool = false

    init(timerResult: TimerResult,
         jiraDomain: String,
         initialDescription: String = "",
         onConfirm: @escaping (TimeInterval, String, Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.timerResult = timerResult
        self.jiraDomain = jiraDomain
        self.onConfirm = onConfirm
        self.onCancel = onCancel

        let totalSeconds = Int(timerResult.duration)
        _hours = State(initialValue: totalSeconds / 3600)
        _minutes = State(initialValue: (totalSeconds % 3600) / 60)
        _seconds = State(initialValue: totalSeconds % 60)
        _workDescription = State(initialValue: initialDescription)
    }

    private var issueURL: URL? {
        let domain = jiraDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL: String

        if domain.contains("atlassian.net") || domain.contains("atlassian.com") {
            baseURL = "https://\(domain)"
        } else if domain.hasPrefix("https://") || domain.hasPrefix("http://") {
            baseURL = domain
        } else {
            baseURL = "https://\(domain).atlassian.net"
        }

        return URL(string: "\(baseURL)/browse/\(timerResult.issue.key)")
    }

    private var endTime: Date {
        timerResult.startTime.addingTimeInterval(timerResult.duration)
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private var adjustedDuration: TimeInterval {
        TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Confirm Time Log")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    // Issue info
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button(action: {
                                if let url = issueURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }) {
                                Text(timerResult.issue.key)
                                    .font(.caption.bold())
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Open in browser")

                            Text(timerResult.issue.issueType)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }

                        Text(timerResult.issue.summary)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.blue, lineWidth: 1)
                    )

                    // Time details
                    VStack(spacing: 8) {
                        HStack {
                            Text("Started:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(dateFormatter.string(from: timerResult.startTime))
                                .font(.caption.monospacedDigit())
                        }

                        HStack {
                            Text("Ended:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(dateFormatter.string(from: endTime))
                                .font(.caption.monospacedDigit())
                        }

                        Divider()

                        HStack {
                            Text("Total:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatDuration(adjustedDuration))
                                .font(.caption.monospacedDigit())
                                .fontWeight(.semibold)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(6)

                    // Duration editor
                    VStack(spacing: 8) {
                        Text("Adjust Duration")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 12) {
                            VStack(spacing: 4) {
                                Text("Hours")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                TextField("", value: $hours, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 50)
                            }

                            Text(":")
                                .font(.title2)
                                .foregroundColor(.secondary)
                                .padding(.top, 16)

                            VStack(spacing: 4) {
                                Text("Minutes")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                TextField("", value: $minutes, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 50)
                            }

                            Text(":")
                                .font(.title2)
                                .foregroundColor(.secondary)
                                .padding(.top, 16)

                            VStack(spacing: 4) {
                                Text("Seconds")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                TextField("", value: $seconds, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 50)
                            }
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(6)
                    }

                    // Description field
                    VStack(spacing: 8) {
                        Text("Work Description (optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(NSColor.textBackgroundColor))

                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)

                            TextEditor(text: $workDescription)
                                .font(.caption)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .padding(4)
                        }
                        .frame(height: 60)

                        Toggle("Also add as comment on ticket", isOn: $alsoAddAsComment)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal)
                .padding(.top)
                .padding(.bottom, 8)
            }

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Log Time") {
                    onConfirm(adjustedDuration, workDescription, alsoAddAsComment)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 480)
        .background(VisualEffectView())
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

struct LogHistoryView: View {
    @Binding var logs: [TimeLogEntry]
    let onEditLog: (TimeLogEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Time Log History")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if logs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No time logs yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Your logged time entries will appear here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(logs) { log in
                            LogHistoryRowView(log: log, onEdit: {
                                onEditLog(log)
                            })
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 500, height: 400)
        .background(VisualEffectView())
    }
}

struct LogHistoryRowView: View {
    let log: TimeLogEntry
    let onEdit: () -> Void

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(log.issueKey)
                    .font(.caption.bold())
                    .foregroundColor(.blue)

                Spacer()

                Text(formatDuration(log.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.primary)
            }

            Text(log.issueSummary)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            if !log.description.isEmpty {
                Text(log.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }

            HStack {
                Text(dateFormatter.string(from: log.loggedAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Edit") {
                    onEdit()
                }
                .buttonStyle(.borderless)
                .font(.caption)
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
}