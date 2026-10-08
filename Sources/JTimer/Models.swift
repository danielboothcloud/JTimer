import Foundation

struct JiraIssue: Codable, Identifiable, Hashable {
    let id: String
    let key: String
    let summary: String
    let status: String
    let statusCategory: String?
    let assignee: String?
    let issueType: String
    let project: String
    let updated: Date?
    let created: Date?
    let comments: [JiraComment]
    let changelog: JiraChangelog?

    init(id: String, key: String, summary: String, status: String = "Unknown",
         statusCategory: String? = nil, assignee: String? = nil,
         issueType: String = "Issue", project: String = "",
         updated: Date? = nil, created: Date? = nil,
         comments: [JiraComment] = [], changelog: JiraChangelog? = nil) {
        self.id = id
        self.key = key
        self.summary = summary
        self.status = status
        self.statusCategory = statusCategory
        self.assignee = assignee
        self.issueType = issueType
        self.project = project
        self.updated = updated
        self.created = created
        self.comments = comments
        self.changelog = changelog
    }

    enum CodingKeys: String, CodingKey {
        case id, key, changelog
        case fields
    }

    enum FieldKeys: String, CodingKey {
        case summary, status, assignee, issuetype, project, updated, created, comment
    }

    enum CommentKeys: String, CodingKey {
        case comments
    }

    enum StatusKeys: String, CodingKey {
        case name, statusCategory
    }

    enum StatusCategoryKeys: String, CodingKey {
        case key
    }

    enum AssigneeKeys: String, CodingKey {
        case displayName
    }

    enum IssueTypeKeys: String, CodingKey {
        case name
    }

    enum ProjectKeys: String, CodingKey {
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        changelog = try container.decodeIfPresent(JiraChangelog.self, forKey: .changelog)

        let fields = try container.nestedContainer(keyedBy: FieldKeys.self, forKey: .fields)
        summary = try fields.decodeIfPresent(String.self, forKey: .summary) ?? "Untitled issue"

        let statusContainer = try? fields.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        status = try statusContainer?.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        if let statusContainer, let categoryContainer = try? statusContainer.nestedContainer(
            keyedBy: StatusCategoryKeys.self,
            forKey: .statusCategory
        ) {
            statusCategory = try categoryContainer.decodeIfPresent(String.self, forKey: .key)
        } else {
            statusCategory = nil
        }

        if let assigneeContainer = try? fields.nestedContainer(keyedBy: AssigneeKeys.self, forKey: .assignee) {
            assignee = try assigneeContainer.decodeIfPresent(String.self, forKey: .displayName)
        } else {
            assignee = nil
        }

        let issueTypeContainer = try? fields.nestedContainer(keyedBy: IssueTypeKeys.self, forKey: .issuetype)
        issueType = try issueTypeContainer?.decodeIfPresent(String.self, forKey: .name) ?? "Issue"

        let projectContainer = try? fields.nestedContainer(keyedBy: ProjectKeys.self, forKey: .project)
        project = try projectContainer?.decodeIfPresent(String.self, forKey: .name) ?? ""

        // Parse dates
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let updatedString = try? fields.decode(String.self, forKey: .updated) {
            updated = dateFormatter.date(from: updatedString)
        } else {
            updated = nil
        }

        if let createdString = try? fields.decode(String.self, forKey: .created) {
            created = dateFormatter.date(from: createdString)
        } else {
            created = nil
        }

        // Parse comments
        if let commentContainer = try? fields.nestedContainer(keyedBy: CommentKeys.self, forKey: .comment) {
            comments = (try? commentContainer.decodeIfPresent([JiraComment].self, forKey: .comments)) ?? []
        } else {
            comments = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(changelog, forKey: .changelog)
        var fields = container.nestedContainer(keyedBy: FieldKeys.self, forKey: .fields)
        try fields.encode(summary, forKey: .summary)
        var statusContainer = fields.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        try statusContainer.encode(status, forKey: .name)
        if let statusCategory {
            var category = statusContainer.nestedContainer(keyedBy: StatusCategoryKeys.self, forKey: .statusCategory)
            try category.encode(statusCategory, forKey: .key)
        }
        if let assignee {
            var value = fields.nestedContainer(keyedBy: AssigneeKeys.self, forKey: .assignee)
            try value.encode(assignee, forKey: .displayName)
        }
        var type = fields.nestedContainer(keyedBy: IssueTypeKeys.self, forKey: .issuetype)
        try type.encode(issueType, forKey: .name)
        var projectValue = fields.nestedContainer(keyedBy: ProjectKeys.self, forKey: .project)
        try projectValue.encode(project, forKey: .name)
        try fields.encodeIfPresent(updated.map(JiraDate.format), forKey: .updated)
        try fields.encodeIfPresent(created.map(JiraDate.format), forKey: .created)
        var comment = fields.nestedContainer(keyedBy: CommentKeys.self, forKey: .comment)
        try comment.encode(comments, forKey: .comments)
    }
}

struct JiraUser: Codable, Hashable {
    let accountId: String
    let displayName: String
    let emailAddress: String?
}

struct JiraComment: Codable, Hashable {
    let id: String
    let author: JiraUser
    let created: String
    let body: JiraDocument?
}

struct JiraDocument: Codable, Hashable {
    let type: String?
    let text: String?
    let attrs: JiraDocumentAttributes?
    let content: [JiraDocument]?

    var plainText: String {
        let ownText = text ?? attrs?.text ?? ""
        return ownText + (content ?? []).map(\.plainText).joined(separator: " ")
    }

    func mentions(accountId: String) -> Bool {
        if type == "mention", attrs?.id == accountId { return true }
        return (content ?? []).contains { $0.mentions(accountId: accountId) }
    }
}

struct JiraDocumentAttributes: Codable, Hashable {
    let id: String?
    let text: String?
}

struct JiraChangelog: Codable, Hashable {
    let histories: [JiraHistory]
}

struct JiraHistory: Codable, Hashable {
    let id: String
    let author: JiraUser
    let created: String
    let items: [JiraHistoryItem]
}

struct JiraHistoryItem: Codable, Hashable {
    let field: String
    let fromString: String?
    let toString: String?
}

enum JiraNotificationKind: String, Codable, CaseIterable {
    case mention
    case comment
    case assigned
    case status
    case updated

    var title: String {
        switch self {
        case .mention: return "Mentioned you"
        case .comment: return "New comment"
        case .assigned: return "Assigned to you"
        case .status: return "Status changed"
        case .updated: return "Issue updated"
        }
    }

    var systemImage: String {
        switch self {
        case .mention: return "at"
        case .comment: return "bubble.left.fill"
        case .assigned: return "person.badge.plus"
        case .status: return "arrow.left.arrow.right"
        case .updated: return "pencil"
        }
    }
}

struct JiraNotificationEvent: Codable, Identifiable, Hashable {
    let id: String
    let issueKey: String
    let issueSummary: String
    let kind: JiraNotificationKind
    let message: String
    let authorName: String
    let date: Date
    var isRead: Bool
}

struct TimeLogEntry: Codable, Identifiable {
    let id: String
    let worklogID: String?
    let issueKey: String
    let issueSummary: String
    let duration: TimeInterval
    let startTime: Date
    let loggedAt: Date
    var description: String

    init(worklogID: String? = nil, issueKey: String, issueSummary: String, duration: TimeInterval, startTime: Date, description: String, loggedAt: Date = Date()) {
        self.worklogID = worklogID
        self.id = worklogID ?? UUID().uuidString
        self.issueKey = issueKey
        self.issueSummary = issueSummary
        self.duration = duration
        self.startTime = startTime
        self.loggedAt = loggedAt
        self.description = description
    }
}

struct JiraSearchResponse: Codable {
    let issues: [JiraIssue]
    let total: Int?

    // Custom initializer to handle missing fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issues = try container.decode([JiraIssue].self, forKey: .issues)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
    }

    enum CodingKeys: String, CodingKey {
        case issues, total
    }
}

struct JiraTransitionResponse: Codable {
    let transitions: [JiraTransition]
}

struct JiraTransition: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let to: JiraTransitionStatus
}

struct JiraTransitionStatus: Codable, Hashable {
    let id: String
    let name: String
}

struct WorkLogEntry: Codable {
    let timeSpentSeconds: Int
    let comment: CommentADF
    let started: String

    private enum CodingKeys: String, CodingKey {
        case timeSpentSeconds, comment, started
    }
}

// Atlassian Document Format (ADF) for comments
struct CommentADF: Codable {
    let type: String
    let version: Int
    let content: [ADFContent]
}

struct ADFContent: Codable {
    let type: String
    let content: [ADFText]?
}

struct ADFText: Codable {
    let type: String
    let text: String
}

enum TimerState {
    case idle
    case running(startTime: Date, issue: JiraIssue)
}

enum JiraDate {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum JiraURLBuilder {
    static func siteURL(from input: String) -> URL? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = value.contains(".") ? "https://\(value)" : "https://\(value).atlassian.net"
        }
        guard var components = URLComponents(string: value),
              components.scheme == "https", components.host != nil else { return nil }
        guard components.path.isEmpty || components.path == "/" else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func apiURL(domain: String, version: Int, path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard let site = siteURL(from: domain), var components = URLComponents(url: site, resolvingAgainstBaseURL: false) else { return nil }
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        components.path = site.path + "/rest/api/\(version)" + suffix
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    static func issueURL(domain: String, issueKey: String) -> URL? {
        siteURL(from: domain)?.appendingPathComponent("browse").appendingPathComponent(issueKey)
    }
}

struct AppSettings {
    private let defaults = UserDefaults.standard

    var jiraDomain: String {
        get {
            defaults.string(forKey: "JiraAPI.domain") ?? ""
        }
        set {
            defaults.set(newValue, forKey: "JiraAPI.domain")
        }
    }

    var jiraEmail: String {
        get {
            defaults.string(forKey: "JiraAPI.email") ?? ""
        }
        set {
            defaults.set(newValue, forKey: "JiraAPI.email")
        }
    }

    var defaultJQL: String {
        get {
            defaults.string(forKey: "JiraAPI.defaultJQL") ?? "assignee = currentUser() AND status != Done"
        }
        set {
            defaults.set(newValue, forKey: "JiraAPI.defaultJQL")
        }
    }

    var customJQLTemplates: [JQLTemplate] {
        get {
            if let data = defaults.data(forKey: "JiraAPI.customTemplates"),
               let templates = try? JSONDecoder().decode([JQLTemplate].self, from: data) {
                return templates
            }
            return []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "JiraAPI.customTemplates")
            }
        }
    }
}

struct JQLTemplate: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let query: String
    let isCustom: Bool

    init(name: String, query: String, isCustom: Bool = false) {
        self.id = UUID()
        self.name = name
        self.query = query
        self.isCustom = isCustom
    }

    static let commonTemplates = [
        JQLTemplate(
            name: "My Open Issues",
            query: "assignee = currentUser() AND status NOT IN (Done, Complete, Completed, Resolved, Closed)"
        ),
        JQLTemplate(
            name: "My Recent Issues",
            query: "assignee = currentUser() ORDER BY updated DESC"
        ),
        JQLTemplate(
            name: "My In Progress",
            query: "assignee = currentUser() AND (status = \"In Progress\" OR status = \"Work in Progress\")"
        ),
        JQLTemplate(
            name: "All My Issues",
            query: "assignee = currentUser()"
        )
    ]
}
