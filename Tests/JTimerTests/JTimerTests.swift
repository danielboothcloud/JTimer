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

final class NotificationFilterTests: XCTestCase {
    private func event(_ id: String, _ date: Date) -> JiraNotificationEvent {
        JiraNotificationEvent(
            id: id, issueKey: "DEV-1", issueSummary: "Summary", kind: .comment,
            message: "hello", authorName: "Someone", date: date, isRead: false
        )
    }

    private let watermark = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testCandidatesAtOrBeforeWatermarkAreNeverFresh() {
        let old = event("old", watermark.addingTimeInterval(-3600))
        let at = event("at", watermark)
        let fresh = event("fresh", watermark.addingTimeInterval(60))

        let result = NotificationFilter.freshEvents(
            candidates: [old, at, fresh], knownIDs: [], watermark: watermark
        )

        XCTAssertEqual(result.map(\.id), ["fresh"])
    }

    func testKnownIDsAreExcluded() {
        let freshUnknown = event("new-1", watermark.addingTimeInterval(60))
        let freshKnown = event("new-2", watermark.addingTimeInterval(120))

        let result = NotificationFilter.freshEvents(
            candidates: [freshUnknown, freshKnown],
            knownIDs: [freshKnown.id],
            watermark: watermark
        )

        XCTAssertEqual(result.map(\.id), ["new-1"])
    }

    /// Regression: when candidates exceed the 250-event store cap, the oldest
    /// candidates are evicted and stay unknown forever. ID-only dedup used to
    /// re-deliver them as native notifications on every poll. The watermark
    /// must keep classifying them as old history.
    func testEvictedHistoryIsNotReDelivered() {
        let candidates = (0..<300).map {
            event("e\($0)", watermark.addingTimeInterval(TimeInterval(-$0)))
        }
        // Simulate the store keeping only the newest 250 events.
        let storedIDs = Set(candidates.prefix(250).map(\.id))

        let result = NotificationFilter.freshEvents(
            candidates: candidates, knownIDs: storedIDs, watermark: watermark
        )

        XCTAssertTrue(result.isEmpty)
    }
}
