import Foundation

// Standalone fixtures keep the state test independent of macOS Accessibility.
struct ClaudeDesktopConversation {
    let key: String
    let title: String
    let family: String
    let status: String
    let url: String?
}

enum ClaudeDesktopScan {
    case unavailable(reason: String)
    case observed([ClaudeDesktopConversation])
}

@main
struct ClaudeDesktopTaskStateTests {
    static func main() {
        let state = ClaudeDesktopTaskState()
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let later = first.addingTimeInterval(9)
        let oldChat = ClaudeDesktopConversation(key: "title:project|old", title: "Old",
                                                family: "Project", status: "idle", url: nil)
        let running = ClaudeDesktopConversation(key: "title:project|new", title: "New",
                                                family: "Project", status: "working", url: nil)
        let waiting = ClaudeDesktopConversation(key: "title:project|waiting", title: "Input needed",
                                                family: "Project", status: "waiting", url: nil)

        let baseline = state.update(.observed([oldChat, running, waiting]), now: first)
        precondition(baseline.count == 3)
        precondition(baseline[0].updatedAt == "1970-01-01T00:00:00Z")
        precondition(baseline[1].updatedAt != baseline[0].updatedAt)
        precondition(baseline[2].updatedAt != baseline[0].updatedAt)
        precondition(state.update(.observed([oldChat, running, waiting]), now: later)[1].updatedAt
                     == baseline[1].updatedAt, "A sidebar heartbeat must not refresh a task")

        let finished = ClaudeDesktopConversation(key: running.key, title: running.title,
                                                 family: running.family, status: "idle", url: nil)
        let transitioned = state.update(.observed([oldChat, finished, waiting]), now: later)
        precondition(transitioned[1].updatedAt != baseline[1].updatedAt)

        _ = state.update(.unavailable(reason: "ordinary_chat_not_visible"), now: later)
        let rediscovered = state.update(.observed([finished]), now: later.addingTimeInterval(3))
        precondition(rediscovered[0].updatedAt == "1970-01-01T00:00:00Z",
                     "Returning from an unreadable window must not imply a new answer")
        print("Claude desktop task state OK")
    }
}
