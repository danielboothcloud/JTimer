import Foundation

@MainActor
final class TimerManager: ObservableObject {
    @Published var currentState: TimerState = .idle
    private let defaults: UserDefaults
    private let storageKey = "JTimer.runningTimer.v1"

    private struct StoredTimer: Codable {
        let startTime: Date
        let issue: JiraIssue
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    var isRunning: Bool {
        if case .running = currentState {
            return true
        }
        return false
    }

    var currentIssue: JiraIssue? {
        switch currentState {
        case .running(_, let issue):
            return issue
        case .idle:
            return nil
        }
    }

    func startTimer(for issue: JiraIssue) {
        _ = stopTimer()
        currentState = .running(startTime: Date(), issue: issue)
        persist()
        print("Timer started for issue: \(issue.key)")
    }

    func stopTimer() -> (issue: JiraIssue, startTime: Date, duration: TimeInterval)? {
        let result: (issue: JiraIssue, startTime: Date, duration: TimeInterval)?

        switch currentState {
        case .running(let startTime, let issue):
            let duration = Date().timeIntervalSince(startTime)
            result = (issue: issue, startTime: startTime, duration: duration)
        case .idle:
            result = nil
        }

        currentState = .idle
        defaults.removeObject(forKey: storageKey)

        if let result = result {
            print("Timer stopped for issue: \(result.issue.key), duration: \(Int(result.duration))s")
        }

        return result
    }

    static func formattedElapsedTime(since startTime: Date, now: Date = Date()) -> String {
        let elapsedTime = max(0, now.timeIntervalSince(startTime))
        let hours = Int(elapsedTime) / 3600
        let minutes = Int(elapsedTime) / 60 % 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func persist() {
        guard case .running(let startTime, let issue) = currentState,
              let data = try? JSONEncoder().encode(StoredTimer(startTime: startTime, issue: issue)) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func restore() {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(StoredTimer.self, from: data) else { return }
        currentState = .running(startTime: stored.startTime, issue: stored.issue)
    }
}
