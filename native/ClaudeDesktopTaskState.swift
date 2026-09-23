import Foundation

/// Presentation state for Claude's ordinary desktop chats. Accessibility
/// exposes a running indicator, but not a trustworthy completed-answer event;
/// these records deliberately never manufacture an answer revision.
struct ClaudeDesktopTaskRecord {
    let key: String
    let title: String
    let family: String
    let status: String
    let updatedAt: String
    let url: String?
}

final class ClaudeDesktopTaskState {
    private struct Previous {
        let status: String
        let updatedAt: String
    }

    private var previous: [String: Previous] = [:]
    private let formatter = ISO8601DateFormatter()
    private let oldTimestamp = "1970-01-01T00:00:00Z"

    func update(_ scan: ClaudeDesktopScan, now: Date = Date()) -> [ClaudeDesktopTaskRecord] {
        guard case .observed(let conversations) = scan else {
            // Never infer completion after Claude is hidden, changes modes,
            // or temporarily stops exposing a complete sidebar.
            previous.removeAll()
            return []
        }

        var next: [String: Previous] = [:]
        var records: [ClaudeDesktopTaskRecord] = []
        let timestamp = formatter.string(from: now)
        for chat in conversations {
            guard next[chat.key] == nil,
                  ["working", "waiting", "idle", "unknown"].contains(chat.status) else { continue }
            let earlier = previous[chat.key]
            let updatedAt: String
            if let earlier {
                updatedAt = earlier.status == chat.status || chat.status == "unknown"
                    ? earlier.updatedAt : timestamp
            } else {
                // An old, merely visible sidebar item is not a fresh task.
                updatedAt = chat.status == "working" || chat.status == "waiting" || chat.url != nil
                    ? timestamp : oldTimestamp
            }
            next[chat.key] = Previous(status: chat.status, updatedAt: updatedAt)
            records.append(ClaudeDesktopTaskRecord(
                key: chat.key, title: chat.title, family: chat.family,
                status: chat.status, updatedAt: updatedAt, url: chat.url
            ))
        }
        previous = next
        return records
    }
}
