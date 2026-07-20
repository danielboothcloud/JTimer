import XCTest
@testable import JTimer

final class JiraURLBuilderTests: XCTestCase {
    func testNormalizesShortAndFullCloudDomains() {
        XCTAssertEqual(JiraURLBuilder.siteURL(from: "acme")?.absoluteString, "https://acme.atlassian.net")
        XCTAssertEqual(JiraURLBuilder.siteURL(from: "https://acme.atlassian.net/")?.absoluteString, "https://acme.atlassian.net")
        XCTAssertEqual(
            JiraURLBuilder.apiURL(domain: "https://acme.atlassian.net", version: 3, path: "/myself")?.absoluteString,
            "https://acme.atlassian.net/rest/api/3/myself"
        )
    }

    func testQueryItemsAreEncodedSafely() {
        let url = JiraURLBuilder.apiURL(
            domain: "acme", version: 3, path: "/search/jql",
            queryItems: [URLQueryItem(name: "jql", value: "summary ~ \"A&B\"")]
        )
        XCTAssertTrue(url?.absoluteString.contains("A%26B") == true)
    }

    func testRejectsUnsafeOrEmptyDomains() {
        XCTAssertNil(JiraURLBuilder.siteURL(from: ""))
        XCTAssertNil(JiraURLBuilder.siteURL(from: "http://acme.atlassian.net"))
    }
}

final class JiraModelTests: XCTestCase {
    func testIssueDecodesWithOptionalFieldsMissingOrNull() throws {
        let json = #"{"id":"1","key":"DEV-1","fields":{"summary":"Test","status":{"name":"Open"},"assignee":null}}"#
        let issue = try JSONDecoder().decode(JiraIssue.self, from: Data(json.utf8))
        XCTAssertEqual(issue.key, "DEV-1")
        XCTAssertEqual(issue.issueType, "Issue")
        XCTAssertEqual(issue.project, "")
        XCTAssertNil(issue.assignee)
        XCTAssertTrue(issue.comments.isEmpty)
    }

    func testIssuePersistenceRoundTrip() throws {
        let issue = JiraIssue(id: "1", key: "DEV-1", summary: "Persist me", status: "Doing")
        let restored = try JSONDecoder().decode(JiraIssue.self, from: JSONEncoder().encode(issue))
        XCTAssertEqual(restored, issue)
    }

    func testJiraDatesWithAndWithoutFractions() {
        XCTAssertNotNil(JiraDate.parse("2026-07-20T10:00:00.123Z"))
        XCTAssertNotNil(JiraDate.parse("2026-07-20T10:00:00Z"))
    }
}

@MainActor
final class TimerManagerTests: XCTestCase {
    func testRunningTimerRestoresAndStopClearsPersistence() {
        let suite = "TimerManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let issue = JiraIssue(id: "1", key: "DEV-1", summary: "Timer")

        let first = TimerManager(defaults: defaults)
        first.startTimer(for: issue)
        let restored = TimerManager(defaults: defaults)
        XCTAssertTrue(restored.isRunning)
        XCTAssertEqual(restored.currentIssue?.key, "DEV-1")

        XCTAssertNotNil(restored.stopTimer())
        XCTAssertFalse(TimerManager(defaults: defaults).isRunning)
    }

    func testElapsedTimeNeverDisplaysNegativeValues() {
        XCTAssertEqual(TimerManager.formattedElapsedTime(since: Date().addingTimeInterval(10), now: Date()), "00:00:00")
    }
}
