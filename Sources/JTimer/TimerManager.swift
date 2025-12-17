import Foundation

class TimerManager: ObservableObject {
    @Published var currentState: TimerState = .idle
    @Published var elapsedTime: TimeInterval = 0

    private var timer: Timer?

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
        startInternalTimer()
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
        elapsedTime = 0
        stopInternalTimer()

        if let result = result {
            print("Timer stopped for issue: \(result.issue.key), duration: \(Int(result.duration))s")
        }

        return result
    }

    private func startInternalTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.updateElapsedTime()
        }
    }

    private func stopInternalTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateElapsedTime() {
        switch currentState {
        case .running(let startTime, _):
            elapsedTime = Date().timeIntervalSince(startTime)
        case .idle:
            elapsedTime = 0
        }
    }

    func formattedElapsedTime() -> String {
        let hours = Int(elapsedTime) / 3600
        let minutes = Int(elapsedTime) / 60 % 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}