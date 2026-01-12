import Foundation

struct JiraIssue: Codable, Identifiable, Hashable {
    let id: String
    let key: String
    let summary: String
    let status: String
    let assignee: String?
    let issueType: String
    let project: String
    let updated: Date?
    let created: Date?

    enum CodingKeys: String, CodingKey {
        case id, key
        case fields
    }

    enum FieldKeys: String, CodingKey {
        case summary, status, assignee, issuetype, project, updated, created
    }

    enum StatusKeys: String, CodingKey {
        case name
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

        let fields = try container.nestedContainer(keyedBy: FieldKeys.self, forKey: .fields)
        summary = try fields.decode(String.self, forKey: .summary)

        let statusContainer = try fields.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        status = try statusContainer.decode(String.self, forKey: .name)

        if let assigneeContainer = try? fields.nestedContainer(keyedBy: AssigneeKeys.self, forKey: .assignee) {
            assignee = try assigneeContainer.decode(String.self, forKey: .displayName)
        } else {
            assignee = nil
        }

        let issueTypeContainer = try fields.nestedContainer(keyedBy: IssueTypeKeys.self, forKey: .issuetype)
        issueType = try issueTypeContainer.decode(String.self, forKey: .name)

        let projectContainer = try fields.nestedContainer(keyedBy: ProjectKeys.self, forKey: .project)
        project = try projectContainer.decode(String.self, forKey: .name)
        
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(key, forKey: .key)
    }
}

struct TimeLogEntry: Codable, Identifiable {
    let id: UUID
    let issueKey: String
    let issueSummary: String
    let duration: TimeInterval
    let startTime: Date
    let loggedAt: Date
    var description: String
    
    init(issueKey: String, issueSummary: String, duration: TimeInterval, startTime: Date, description: String, loggedAt: Date) {
        self.id = UUID()
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
}

struct JiraUser: Codable {
    let accountId: String
    let displayName: String
    let emailAddress: String
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
}

struct JQLTemplate {
    let name: String
    let query: String
    let description: String

    static let commonTemplates = [
        JQLTemplate(
            name: "My Open Issues",
            query: "assignee = currentUser() AND status NOT IN (Done, Complete, Resolved, Closed)",
            description: "All open issues assigned to you"
        ),
        JQLTemplate(
            name: "My Recent Issues",
            query: "assignee = currentUser() ORDER BY updated DESC",
            description: "All your issues sorted by most recent"
        ),
        JQLTemplate(
            name: "My In Progress",
            query: "assignee = currentUser() AND status = \"In Progress\" OR status = \"Work in Progress\"",
            description: "Issues you're currently working on"
        ),
        JQLTemplate(
            name: "My Todo",
            query: "assignee = currentUser() AND status = \"To Do\"",
            description: "Issues ready for you to start"
        ),
        JQLTemplate(
            name: "All My Issues",
            query: "assignee = currentUser()",
            description: "Every issue assigned to you"
        ),
        JQLTemplate(
            name: "Recent Updates",
            query: "assignee = currentUser() AND updated >= -7d",
            description: "Your issues updated in the last week"
        )
    ]
}
