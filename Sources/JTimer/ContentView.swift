import SwiftUI
import AppKit

struct TimerResult: Identifiable, Codable {
    let id: UUID
    let issue: JiraIssue
    let startTime: Date
    let duration: TimeInterval
    let worklogID: String?

    init(id: UUID = UUID(), issue: JiraIssue, startTime: Date, duration: TimeInterval, worklogID: String? = nil) {
        self.id = id
        self.issue = issue
        self.startTime = startTime
        self.duration = duration
        self.worklogID = worklogID
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var timerManager: TimerManager
    @EnvironmentObject var jiraAPI: JiraAPI
    @EnvironmentObject var notificationManager: NotificationManager
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
    @State private var showingUpdates = false
    @State private var customJQLTemplates: [JQLTemplate] = []
    @State private var isSubmittingWorklog = false
    @State private var worklogError: String?
    @State private var issueLoadTask: Task<Void, Never>?
    private let pendingWorklogKey = "JTimer.pendingWorklog.v1"

    var allTemplates: [JQLTemplate] {
        JQLTemplate.commonTemplates + customJQLTemplates
    }

    var body: some View {
        Group {
            if let result = pendingTimerResult {
                LogConfirmationView(
                    timerResult: result,
                    jiraDomain: AppSettings().jiraDomain,
                    initialDescription: pendingDescription,
                    isSubmitting: isSubmittingWorklog,
                    errorMessage: worklogError,
                    onConfirm: { adjustedDuration, description, alsoAddAsComment in
                        Task {
                            let succeeded = await logWorkToJira(
                                issue: result.issue,
                                worklogID: result.worklogID,
                                startTime: result.startTime,
                                duration: adjustedDuration,
                                comment: description,
                                alsoAddAsComment: alsoAddAsComment
                            )
                            if succeeded {
                                pendingTimerResult = nil
                                pendingDescription = ""
                                clearPendingWorklog()
                            }
                        }
                    },
                    onCancel: {
                        pendingTimerResult = nil
                        pendingDescription = ""
                        clearPendingWorklog()
                    }
                )
            } else if showingUpdates {
                UpdatesView(notificationManager: notificationManager) {
                    showingUpdates = false
                }
            } else if showingHistory {
                LogHistoryView(
                    logs: $timeLogHistory,
                    onEditLog: editLog,
                    onClose: { showingHistory = false }
                )
            } else if showingSettings {
                SettingsView(onClose: { showingSettings = false })
                    .environmentObject(jiraAPI)
            } else {
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
            }
        }
        .onAppear {
            loadIssuesIfNeeded()
            loadLogHistory()
            loadCustomTemplates()
            restorePendingWorklog()
        }
        .onDisappear { issueLoadTask?.cancel() }
        .onChange(of: jiraAPI.isAuthenticated) { authenticated in
            if authenticated { startIssueLoad() }
        }
    }

    private var headerView: some View {
        HStack {
            Text("JTimer")
                .font(.headline)
                .foregroundColor(.primary)

            Spacer()

            if case .running(let startTime, let currentIssue) = timerManager.currentState {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(currentIssue.key)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(TimerManager.formattedElapsedTime(since: startTime, now: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.primary)
                    }
                }
            }

            Button(action: {
                showingUpdates = true
                Task { await notificationManager.refresh() }
            }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: notificationManager.unreadCount > 0 ? "bell.fill" : "bell")
                    if notificationManager.unreadCount > 0 {
                        Text("\(min(notificationManager.unreadCount, 99))")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(2)
                            .background(Color.red)
                            .clipShape(Circle())
                            .offset(x: 7, y: -7)
                    }
                }
            }
            .buttonStyle(.borderless)
            .help("View recent updates")

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
    }

    private func editLog(_ log: TimeLogEntry) {
        showingHistory = false
        pendingDescription = log.description
        let issue = issues.first(where: { $0.key == log.issueKey }) ?? JiraIssue(
            id: log.issueKey, key: log.issueKey, summary: log.issueSummary
        )
        pendingTimerResult = TimerResult(
                issue: issue,
                startTime: log.startTime,
                duration: log.duration,
                worklogID: log.worklogID
            )
        savePendingWorklog()
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
                    startIssueLoad(jql: customJQL.isEmpty ? nil : customJQL)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.top, 4)

            HStack {
                Menu {
                    ForEach(allTemplates, id: \.id) { template in
                        Button(action: {
                            customJQL = template.query
                            startIssueLoad(jql: template.query)
                        }) {
                            Text(template.name)
                                .font(.caption)
                        }
                    }

                    Divider()

                    Button("Clear Query") {
                        customJQL = ""
                        startIssueLoad()
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
                        startIssueLoad(jql: customJQL)
                    }

                Button("Apply") {
                    startIssueLoad(jql: customJQL)
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
                        startIssueLoad()
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
                            startIssueLoad(jql: "assignee = currentUser()")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Recent Issues") {
                            startIssueLoad(jql: "assignee = currentUser() ORDER BY updated DESC")
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
                            onSelect: { selectedIssue = issue },
                            onStatusChanged: {
                                startIssueLoad(jql: currentQuery.isEmpty ? nil : currentQuery)
                            }
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
                if timerManager.isRunning {
                    let alert = NSAlert()
                    alert.messageText = "A timer is still running"
                    alert.informativeText = "JTimer will restore it next time you open the app."
                    alert.addButton(withTitle: "Quit and Restore Later")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
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
        if jiraAPI.isAuthenticated {
            if issues.isEmpty {
                startIssueLoad()
            }
            Task {
                await notificationManager.refresh()
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
            "assignee = currentUser() AND status NOT IN (Done, Complete, Completed, Resolved, Closed)",
            "assignee = currentUser() AND status != Done",
            "assignee = currentUser()",
            "assignee = currentUser() ORDER BY updated DESC"
        ]

        let queriesToTry = jql != nil ? [jql!] : fallbackQueries

        for (index, queryJQL) in queriesToTry.enumerated() {
            guard !Task.isCancelled else { return }
            do {
                print("🔍 JTimer: Trying JQL query: \(queryJQL)")

                let fetchedIssues = try await jiraAPI.searchIssues(jql: queryJQL)
                guard !Task.isCancelled else { return }

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

    private func startIssueLoad(jql: String? = nil) {
        issueLoadTask?.cancel()
        issueLoadTask = Task { await loadIssues(jql: jql) }
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
            savePendingWorklog()
        }
    }

    private func logWorkToJira(issue: JiraIssue, worklogID: String?, startTime: Date, duration: TimeInterval, comment: String? = nil, alsoAddAsComment: Bool = false) async -> Bool {
        guard duration >= 1 else {
            worklogError = "Duration must be at least one second."
            return false
        }
        isSubmittingWorklog = true
        worklogError = nil
        defer { isSubmittingWorklog = false }
        do {
            let timeInSeconds = Int(duration)
            print("⏱️ JTimer: Logging \(timeInSeconds) seconds (\(timeInSeconds/60) minutes) to \(issue.key)")

            if let worklogID {
                try await jiraAPI.updateWorklog(issueKey: issue.key, worklogID: worklogID,
                                                timeSpentSeconds: timeInSeconds, startTime: startTime, comment: comment)
            } else {
                try await jiraAPI.logWork(issueKey: issue.key, timeSpentSeconds: timeInSeconds,
                                          startTime: startTime, comment: comment)
            }

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
            return true
        } catch {
            print("Failed to log work: \(error)")
            worklogError = "Couldn’t save this worklog: \(error.localizedDescription). Your entry has been kept so you can retry."
            return false
        }
    }

    private struct PendingWorklog: Codable {
        let result: TimerResult
        let description: String
    }

    private func savePendingWorklog() {
        guard let pendingTimerResult,
              let data = try? JSONEncoder().encode(PendingWorklog(result: pendingTimerResult, description: pendingDescription)) else { return }
        UserDefaults.standard.set(data, forKey: pendingWorklogKey)
    }

    private func restorePendingWorklog() {
        guard pendingTimerResult == nil,
              let data = UserDefaults.standard.data(forKey: pendingWorklogKey),
              let pending = try? JSONDecoder().decode(PendingWorklog.self, from: data) else { return }
        pendingTimerResult = pending.result
        pendingDescription = pending.description
    }

    private func clearPendingWorklog() {
        UserDefaults.standard.removeObject(forKey: pendingWorklogKey)
    }

    private func loadCustomTemplates() {
        customJQLTemplates = AppSettings().customJQLTemplates
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
    let onStatusChanged: () -> Void

    private var issueURL: URL? {
        JiraURLBuilder.issueURL(domain: AppSettings().jiraDomain, issueKey: issue.key)
    }

    var body: some View {
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
                        IssueStatusMenu(issue: issue, onStatusChanged: onStatusChanged)
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
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
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

private struct IssueStatusMenu: View {
    @EnvironmentObject var jiraAPI: JiraAPI
    let issue: JiraIssue
    let onStatusChanged: () -> Void

    @State private var transitions: [JiraTransition] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Menu {
            if isLoading {
                Text("Loading available statuses…")
            } else if let errorMessage {
                Text(errorMessage)
                Button("Retry") { loadTransitions() }
            } else if transitions.isEmpty {
                Text("No workflow transitions available")
                Button("Reload") { loadTransitions() }
            } else {
                ForEach(transitions) { transition in
                    Button(transition.to.name) {
                        apply(transition)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(issue.status).fontWeight(.medium)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .font(.caption2)
            .foregroundColor(statusColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.16))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(statusColor.opacity(0.40), lineWidth: 1))
        .onAppear {
            if transitions.isEmpty { loadTransitions() }
        }
        .help("Change status for \(issue.key)")
    }

    private func loadTransitions() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                transitions = try await jiraAPI.getTransitions(issueKey: issue.key)
            } catch {
                errorMessage = "Couldn’t load statuses"
            }
            isLoading = false
        }
    }

    private func apply(_ transition: JiraTransition) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await jiraAPI.transitionIssue(issueKey: issue.key, transitionID: transition.id)
                transitions = []
                onStatusChanged()
            } catch {
                errorMessage = "Status change failed"
            }
            isLoading = false
        }
    }

    private var statusColor: Color {
        switch issue.statusCategory?.lowercased() {
        case "done": return .green
        case "indeterminate": return .blue
        case "new": return .purple
        default: return .orange
        }
    }

}

struct LogConfirmationView: View {
    let timerResult: TimerResult
    let jiraDomain: String
    let isSubmitting: Bool
    let errorMessage: String?
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
         isSubmitting: Bool = false,
         errorMessage: String? = nil,
         onConfirm: @escaping (TimeInterval, String, Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.timerResult = timerResult
        self.jiraDomain = jiraDomain
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
        self.onConfirm = onConfirm
        self.onCancel = onCancel

        let totalSeconds = Int(timerResult.duration)
        _hours = State(initialValue: totalSeconds / 3600)
        _minutes = State(initialValue: (totalSeconds % 3600) / 60)
        _seconds = State(initialValue: totalSeconds % 60)
        _workDescription = State(initialValue: initialDescription)
    }

    private var issueURL: URL? {
        JiraURLBuilder.issueURL(domain: jiraDomain, issueKey: timerResult.issue.key)
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

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(6)
                    }

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
                .disabled(isSubmitting)

                Spacer()

                Button(timerResult.worklogID == nil ? "Log Time" : "Update Time") {
                    onConfirm(adjustedDuration, workDescription, alsoAddAsComment)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || adjustedDuration < 1 || minutes < 0 || minutes > 59 || seconds < 0 || seconds > 59 || hours < 0)
                .overlay {
                    if isSubmitting { ProgressView().controlSize(.small) }
                }
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
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Time Log History")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    onClose()
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
        .frame(width: 400, height: 500)
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
