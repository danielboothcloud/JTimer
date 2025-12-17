import Foundation
import Security

class JiraAPI: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: JiraUser?
    @Published var lastError: String?

    private var settings = AppSettings()
    private let keychain = KeychainManager()

    init() {
        loadExistingSettings()
    }

    private func loadExistingSettings() {
        // Check if we have existing settings and a saved token
        let hasDomain = !settings.jiraDomain.isEmpty
        let hasEmail = !settings.jiraEmail.isEmpty
        let hasToken = keychain.getToken() != nil

        if hasDomain && hasEmail && hasToken {
            print("🔧 JTimer: Loading existing settings - domain: '\(settings.jiraDomain)', email: '\(settings.jiraEmail)'")
            Task {
                await validateConnection()
            }
        }
    }

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private var baseURL: String {
        return baseURL(apiVersion: 3)
    }

    private func baseURL(apiVersion: Int) -> String {
        let domain = settings.jiraDomain.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle full domain vs short domain
        if domain.contains("atlassian.net") || domain.contains("atlassian.com") {
            return "https://\(domain)/rest/api/\(apiVersion)"
        } else if domain.hasPrefix("https://") {
            return "\(domain)/rest/api/\(apiVersion)"
        } else {
            return "https://\(domain).atlassian.net/rest/api/\(apiVersion)"
        }
    }

    private var authHeader: String? {
        guard let token = keychain.getToken() else { return nil }
        let credentials = "\(settings.jiraEmail):\(token)"
        let credentialsData = credentials.data(using: .utf8)!
        return "Basic \(credentialsData.base64EncodedString())"
    }

    func configure(domain: String, email: String, token: String) {
        settings.jiraDomain = domain
        settings.jiraEmail = email
        keychain.saveToken(token)

        print("🔧 JTimer: Configuring with domain: '\(domain)', email: '\(email)'")
        print("🔧 JTimer: Base URL will be: '\(baseURL)'")

        Task {
            await validateConnection()
        }
    }

    @MainActor
    func validateConnection() async {
        do {
            let user = try await getCurrentUser()
            currentUser = user
            isAuthenticated = true
            lastError = nil
        } catch {
            isAuthenticated = false
            lastError = error.localizedDescription
        }
    }

    func getCurrentUser() async throws -> JiraUser {
        guard let authHeader = authHeader else {
            throw JiraAPIError.notAuthenticated
        }

        let urlString = "\(baseURL)/myself"
        print("🔍 JTimer: Attempting to connect to: \(urlString)")

        guard let url = URL(string: urlString) else {
            throw JiraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("JTimer/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw JiraAPIError.invalidResponse
            }

            print("📡 JTimer: HTTP Status: \(httpResponse.statusCode)")

            if httpResponse.statusCode == 401 {
                throw JiraAPIError.unauthorized
            }

            guard httpResponse.statusCode == 200 else {
                throw JiraAPIError.serverError(httpResponse.statusCode)
            }

            return try JSONDecoder().decode(JiraUser.self, from: data)
        } catch {
            print("🚨 JTimer: Network error: \(error)")

            // Provide more specific error messages for common SSL issues
            if let urlError = error as? URLError {
                switch urlError.code {
                case .secureConnectionFailed:
                    throw JiraAPIError.sslError
                case .serverCertificateUntrusted:
                    throw JiraAPIError.certificateError
                case .timedOut:
                    throw JiraAPIError.timeoutError
                case .cannotConnectToHost:
                    throw JiraAPIError.connectionError
                default:
                    throw JiraAPIError.networkError(urlError.localizedDescription)
                }
            }

            throw error
        }
    }

    func searchIssues(jql: String) async throws -> [JiraIssue] {
        // Try API v3 first, then fall back to v2 if we get a 410 error
        do {
            return try await searchIssues(jql: jql, apiVersion: 3)
        } catch JiraAPIError.endpointGone {
            print("⚠️ JTimer: API v3 returned 410, trying API v2...")
            return try await searchIssues(jql: jql, apiVersion: 2)
        }
    }

    private func searchIssues(jql: String, apiVersion: Int) async throws -> [JiraIssue] {
        guard let authHeader = authHeader else {
            throw JiraAPIError.notAuthenticated
        }

        let encodedJQL = jql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        // Use the new /search/jql endpoint for API v3, old /search for v2
        let endpoint = apiVersion >= 3 ? "/search/jql" : "/search"
        let urlString = "\(baseURL(apiVersion: apiVersion))\(endpoint)?jql=\(encodedJQL)&fields=summary,status,assignee,issuetype,project&maxResults=50"

        print("🔍 JTimer: Search URL (API v\(apiVersion)): \(urlString)")

        guard let url = URL(string: urlString) else {
            throw JiraAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("JTimer/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw JiraAPIError.invalidResponse
            }

            print("📡 JTimer: Search HTTP Status (API v\(apiVersion)): \(httpResponse.statusCode)")

            // Log response body for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                print("📄 JTimer: Response: \(responseString.prefix(200))...")
            }

            if httpResponse.statusCode == 400 {
                throw JiraAPIError.invalidJQL
            }

            if httpResponse.statusCode == 410 {
                throw JiraAPIError.endpointGone
            }

            guard httpResponse.statusCode == 200 else {
                throw JiraAPIError.serverError(httpResponse.statusCode)
            }

            let searchResponse = try JSONDecoder().decode(JiraSearchResponse.self, from: data)
            return searchResponse.issues
        } catch {
            print("🚨 JTimer: Search error (API v\(apiVersion)): \(error)")
            throw error
        }
    }

    func logWork(issueKey: String, timeSpentSeconds: Int, startTime: Date) async throws {
        guard let authHeader = authHeader else {
            throw JiraAPIError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/issue/\(issueKey)/worklog")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Jira requires the format: yyyy-MM-dd'T'HH:mm:ss.SSSZ (with +0000 not Z)
        // DateFormatter's XXX can still produce 'Z' for UTC, so we manually append +0000
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let timestampWithoutTZ = formatter.string(from: startTime)
        let jiraTimestamp = timestampWithoutTZ + "+0000"

        // Create ADF-formatted comment for Jira API v3
        let commentADF = CommentADF(
            type: "doc",
            version: 1,
            content: [
                ADFContent(
                    type: "paragraph",
                    content: [
                        ADFText(
                            type: "text",
                            text: "Time tracked via JTimer"
                        )
                    ]
                )
            ]
        )

        let workLog = WorkLogEntry(
            timeSpentSeconds: timeSpentSeconds,
            comment: commentADF,
            started: jiraTimestamp
        )

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(workLog)

        // Debug logging
        if let jsonString = String(data: request.httpBody!, encoding: .utf8) {
            print("📤 JTimer: POST \(url)")
            print("📤 JTimer: Request body: \(jsonString)")
        }

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JiraAPIError.invalidResponse
        }

        print("📥 JTimer: Worklog response status: \(httpResponse.statusCode)")

        if let responseString = String(data: data, encoding: .utf8) {
            print("📥 JTimer: Response body: \(responseString)")
        }

        guard httpResponse.statusCode == 201 else {
            throw JiraAPIError.serverError(httpResponse.statusCode)
        }
    }
}

enum JiraAPIError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case invalidResponse
    case unauthorized
    case invalidJQL
    case serverError(Int)
    case endpointGone
    case sslError
    case certificateError
    case timeoutError
    case connectionError
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with Jira"
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .unauthorized:
            return "Invalid credentials"
        case .invalidJQL:
            return "Invalid JQL query"
        case .serverError(let code):
            return "Server error: \(code)"
        case .endpointGone:
            return "API endpoint no longer available (410). Your Jira instance may use a different API version or the search endpoint has moved."
        case .sslError:
            return "SSL connection failed. Check your network connection and domain."
        case .certificateError:
            return "Server certificate is not trusted. Contact your Jira administrator."
        case .timeoutError:
            return "Connection timeout. Check your network connection."
        case .connectionError:
            return "Cannot connect to Jira server. Check domain and network."
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

class KeychainManager {
    private let service = "com.yourcompany.JTimer"
    private let account = "jira-token"

    func saveToken(_ token: String) {
        let data = token.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func getToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess,
           let data = dataTypeRef as? Data,
           let token = String(data: data, encoding: .utf8) {
            return token
        }

        return nil
    }

    func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}