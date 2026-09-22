import Combine
import Darwin
import Foundation

/// The status and completed-answer revision seen when the user checks a task.
/// General update times are deliberately excluded: browser heartbeats update them.
struct TaskResolutionObservation {
    let id: String
    let source: String
    let title: String
    let status: String
    let revision: String?

    init(id: String, source: String, title: String, status: String, revision: String? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.status = status
        self.revision = revision
    }
}

struct ResolvedTask: Codable, Identifiable, Equatable {
    let id: String
    let source: String
    let title: String
    let status: String
    let revision: String?
    let resolvedAt: Date
}

enum ManualResolutionStoreError: LocalizedError {
    case invalidTaskID
    case invalidStoreFile
    case unreadableStore

    var errorDescription: String? {
        switch self {
        case .invalidTaskID: return "任务标识无效，无法保存已处理状态。"
        case .invalidStoreFile: return "已处理任务的存储位置不是普通文件或目录。"
        case .unreadableStore: return "已处理任务记录无法读取；请先检查本地存储文件。"
        }
    }
}

@MainActor
final class ManualResolutionStore: ObservableObject {
    @Published private(set) var resolved: [ResolvedTask] = []
    @Published private(set) var storageError: String?

    let fileURL: URL
    private let usesDefaultDirectory: Bool
    private var loadFailed = false

    private struct SavedState: Codable {
        let version: Int
        let resolved: [ResolvedTask]
    }

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-pet", isDirectory: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("resolved-tasks.json")
        self.usesDefaultDirectory = fileURL == nil
        do {
            try load()
        } catch {
            loadFailed = true
            storageError = error.localizedDescription
        }
    }

    func isResolved(id: String) -> Bool {
        resolved.contains { $0.id == id }
    }

    func markResolved(_ observation: TaskResolutionObservation) throws {
        guard !loadFailed else { throw ManualResolutionStoreError.unreadableStore }
        let id = observation.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 512 else {
            throw ManualResolutionStoreError.invalidTaskID
        }
        let task = ResolvedTask(
            id: id,
            source: observation.source,
            title: observation.title,
            status: Self.normalizedStatus(observation.status),
            revision: Self.normalizedRevision(observation.revision),
            resolvedAt: Date()
        )
        var next = resolved.filter { $0.id != id }
        next.insert(task, at: 0)
        do {
            try save(next)
        } catch {
            storageError = error.localizedDescription
            throw error
        }
        resolved = next
        storageError = nil
    }

    func restore(id: String) throws {
        guard !loadFailed else { throw ManualResolutionStoreError.unreadableStore }
        let next = resolved.filter { $0.id != id }
        guard next.count != resolved.count else { return }
        do {
            try save(next)
        } catch {
            storageError = error.localizedDescription
            throw error
        }
        resolved = next
        storageError = nil
    }

    /// Remove stored checkmarks for conversations no longer shown by design.
    func discard(ids: Set<String>) {
        guard !loadFailed, !ids.isEmpty else { return }
        let next = resolved.filter { !ids.contains($0.id) }
        guard next.count != resolved.count else { return }
        do {
            try save(next)
            resolved = next
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// A changed status or a new completed-answer revision reopens a checked task.
    /// Disappearing from a source snapshot does not erase the user's decision.
    func reconcile(_ observations: [TaskResolutionObservation]) {
        guard !loadFailed, !resolved.isEmpty else { return }
        let byID = Dictionary(
            observations.map { ($0.id.trimmingCharacters(in: .whitespacesAndNewlines), $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let next = resolved.filter { task in
            guard let current = byID[task.id] else { return true }
            let currentStatus = Self.normalizedStatus(current.status)
            // "unknown" can be a temporary web-tab expiry; it says nothing
            // about whether the user's earlier action still stands.
            if currentStatus != "unknown", currentStatus != task.status { return false }
            if let revision = Self.normalizedRevision(current.revision), revision != task.revision {
                return false
            }
            return true
        }
        guard next.count != resolved.count else { return }
        do {
            try save(next)
            resolved = next
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    private static func normalizedStatus(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? "unknown" : value
    }

    private static func normalizedRevision(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func load() throws {
        try ensureDirectory()
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size <= 32 * 1024 * 1024 else {
            throw ManualResolutionStoreError.invalidStoreFile
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(SavedState.self, from: data)
        guard saved.version == 1 else { throw ManualResolutionStoreError.unreadableStore }
        var seenIDs = Set<String>()
        resolved = saved.resolved.filter { seenIDs.insert($0.id).inserted }
            .sorted { $0.resolvedAt > $1.resolvedAt }
    }

    private func save(_ tasks: [ResolvedTask]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(SavedState(version: 1, resolved: tasks))
        try ensureDirectory()

        var existing = stat()
        if lstat(fileURL.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG else {
                throw ManualResolutionStoreError.invalidStoreFile
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".resolved-tasks-\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path,
                              O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                              S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary { unlink(temporaryURL.path) }
        }
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
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        shouldRemoveTemporary = false
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
            throw ManualResolutionStoreError.invalidStoreFile
        }
        if usesDefaultDirectory && chmod(directory.path, S_IRWXU) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
