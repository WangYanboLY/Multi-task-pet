import Combine
import Darwin
import Foundation

/// One snapshot of a conversation. `revision` identifies a completed answer,
/// not a heartbeat or the conversation's last general activity timestamp.
struct AnswerObservation {
    let id: String
    let source: String
    let title: String
    let status: String
    let updatedAt: String
    let revision: String?
    let url: String?
    let completionEligible: Bool

    init(id: String, source: String, title: String, status: String,
         updatedAt: String, revision: String? = nil, url: String? = nil,
         completionEligible: Bool? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.revision = revision
        self.url = url
        // A source may explicitly disqualify a revision, but a status change
        // without a completed-answer revision never creates an unread answer.
        self.completionEligible = completionEligible ?? (revision?.isEmpty == false)
    }
}

struct UnreadAnswer: Codable, Identifiable, Equatable {
    let id: String
    let source: String
    let title: String
    let completedAt: String
    let revision: String?
    let url: String?
}

@MainActor
final class AnswerInbox: ObservableObject {
    @Published private(set) var unread: [UnreadAnswer] = []
    @Published private(set) var storageError: String?

    var unreadCount: Int { unread.count }
    let fileURL: URL

    private struct Cursor: Codable, Equatable {
        var status: String
        var revision: String?
        var seenCompletedRevisions: [String]
    }

    private struct SavedState: Codable {
        let version: Int
        let initialized: Bool
        let cursors: [String: Cursor]
        let unread: [UnreadAnswer]
    }

    private let usesDefaultDirectory: Bool
    private var initialized = false
    private var cursors: [String: Cursor] = [:]
    private let revisionHistoryLimit = 32

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-pet", isDirectory: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("read-state.json")
        self.usesDefaultDirectory = fileURL == nil
        load()
    }

    /// Returns only answers first observed as complete in this ingestion.
    /// An empty first snapshot does not establish a baseline.
    @discardableResult
    func ingest(_ observations: [AnswerObservation]) -> [UnreadAnswer] {
        let valid = observations.compactMap { observation -> (AnswerObservation, String, String, String?)? in
            let id = observation.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.utf8.count <= 512 else { return nil }
            let status = observation.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let revision = observation.revision?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (observation, id, status, revision?.isEmpty == true ? nil : revision)
        }

        if !initialized {
            guard !valid.isEmpty else { return [] }
            for (_, id, status, revision) in valid {
                cursors[id] = Cursor(status: status, revision: revision,
                                     seenCompletedRevisions: isCompleted(status) ? revision.map { [$0] } ?? [] : [])
            }
            initialized = true
            persist()
            return []
        }

        var arrivals: [UnreadAnswer] = []
        var changed = false
        for (observation, id, status, revision) in valid {
            guard var prior = cursors[id] else {
                // A newly discovered already-idle conversation is historical.
                cursors[id] = Cursor(status: status, revision: revision,
                                     seenCompletedRevisions: isCompleted(status) ? revision.map { [$0] } ?? [] : [])
                changed = true
                continue
            }

            let activeToComplete = isActive(prior.status) && isCompleted(status)
            let unseenRevision = revision.map { !prior.seenCompletedRevisions.contains($0) } ?? false
            // Keep completion history through intervening working/failed/unknown
            // snapshots, which may carry no revision of their own.
            let revisionChanged = revision != nil && !prior.seenCompletedRevisions.isEmpty && unseenRevision
            if observation.completionEligible && isCompleted(status) && revision != nil && unseenRevision &&
                (activeToComplete || revisionChanged) {
                let answer = UnreadAnswer(
                    id: id,
                    source: observation.source,
                    title: observation.title,
                    completedAt: observation.updatedAt.isEmpty ? ISO8601DateFormatter().string(from: Date()) : observation.updatedAt,
                    revision: revision,
                    url: observation.url
                )
                unread.removeAll { $0.id == id }
                unread.append(answer)
                arrivals.append(answer)
                changed = true
            }

            if isCompleted(status), let revision, !prior.seenCompletedRevisions.contains(revision) {
                prior.seenCompletedRevisions.append(revision)
                if prior.seenCompletedRevisions.count > revisionHistoryLimit {
                    prior.seenCompletedRevisions.removeFirst(prior.seenCompletedRevisions.count - revisionHistoryLimit)
                }
            }
            prior.status = status
            prior.revision = revision
            if cursors[id] != prior {
                cursors[id] = prior
                changed = true
            }
        }

        if changed {
            sortUnread()
            persist()
        }
        return arrivals
    }

    func markRead(id: String) {
        let previousCount = unread.count
        unread.removeAll { $0.id == id }
        if unread.count != previousCount { persist() }
    }

    func markAllRead() {
        guard !unread.isEmpty else { return }
        unread = []
        persist()
    }

    /// Remove conversations that the collector has confirmed are hidden subagents.
    func discard(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let oldUnreadCount = unread.count
        let oldCursorCount = cursors.count
        unread.removeAll { ids.contains($0.id) }
        cursors = cursors.filter { !ids.contains($0.key) }
        if unread.count != oldUnreadCount || cursors.count != oldCursorCount { persist() }
    }

    private func isActive(_ status: String) -> Bool {
        status == "working" || status == "waiting"
    }

    private func isCompleted(_ status: String) -> Bool {
        status == "idle" || status == "done"
    }

    private func sortUnread() {
        unread.sort { left, right in
            left.completedAt == right.completedAt ? left.id < right.id : left.completedAt > right.completedAt
        }
    }

    private func load() {
        do {
            try ensureDirectory()
        } catch {
            storageError = error.localizedDescription
            return
        }
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno != ENOENT {
                storageError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
            }
            return
        }
        defer { close(descriptor) }

        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_size <= 32 * 1024 * 1024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
            let saved = try JSONDecoder().decode(SavedState.self, from: data)
            guard saved.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            initialized = saved.initialized
            cursors = saved.cursors
            var seenIDs = Set<String>()
            unread = saved.unread.filter { seenIDs.insert($0.id).inserted }
            sortUnread()
        } catch {
            // A damaged state file must never turn old answers into new alerts.
            initialized = false
            cursors = [:]
            unread = []
            storageError = error.localizedDescription
        }
    }

    private func persist() {
        do {
            let saved = SavedState(version: 1, initialized: initialized, cursors: cursors, unread: unread)
            let data = try JSONEncoder().encode(saved)
            try ensureDirectory()
            try writeAtomically(data)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func ensureDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if usesDefaultDirectory, chmod(directory.path, S_IRWXU) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writeAtomically(_ data: Data) throws {
        var existing = stat()
        if lstat(fileURL.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".read-state-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                              S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { unlink(temporary.path) }

        do {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
