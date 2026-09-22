import Combine
import Darwin
import Foundation

struct SavedThought: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
}

enum ThoughtStoreError: LocalizedError {
    case emptyThought
    case thoughtTooLong
    case invalidStoreFile

    var errorDescription: String? {
        switch self {
        case .emptyThought: return "请输入想保存的想法。"
        case .thoughtTooLong: return "单条想法不能超过 64 KB。"
        case .invalidStoreFile: return "想法存储位置不是普通文件或目录。"
        }
    }
}

@MainActor
final class ThoughtStore: ObservableObject {
    @Published private(set) var thoughts: [SavedThought] = []
    @Published private(set) var loadError: String?

    let fileURL: URL
    private let recentLimit: Int
    private let usesDefaultDirectory: Bool

    init(fileURL: URL? = nil, recentLimit: Int = 100) {
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-pet", isDirectory: true)
        self.fileURL = fileURL ?? defaultDirectory.appendingPathComponent("thoughts.jsonl")
        self.usesDefaultDirectory = fileURL == nil
        self.recentLimit = max(1, recentLimit)
        do {
            try reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    func save(_ text: String) throws -> SavedThought {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThoughtStoreError.emptyThought
        }
        guard text.utf8.count <= 65_536 else {
            throw ThoughtStoreError.thoughtTooLong
        }

        try ensureDirectory()
        let thought = SavedThought(id: UUID(), text: text, createdAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var record = try encoder.encode(thought)
        record.append(0x0A)

        let descriptor = open(fileURL.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                              S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw ThoughtStoreError.invalidStoreFile
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if metadata.st_size > 0 {
            var lastByte: UInt8 = 0
            guard pread(descriptor, &lastByte, 1, metadata.st_size - 1) == 1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if lastByte != 0x0A {
                var newline: UInt8 = 0x0A
                guard Darwin.write(descriptor, &newline, 1) == 1 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        try record.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        thoughts.insert(thought, at: 0)
        if thoughts.count > recentLimit { thoughts.removeLast(thoughts.count - recentLimit) }
        loadError = nil
        return thought
    }

    func reload() throws {
        try ensureDirectory()
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT {
                thoughts = []
                loadError = nil
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw ThoughtStoreError.invalidStoreFile
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var recent: [SavedThought] = []
        for line in data.split(separator: 0x0A) {
            guard let thought = try? decoder.decode(SavedThought.self, from: Data(line)) else { continue }
            recent.insert(thought, at: 0)
            if recent.count > recentLimit { recent.removeLast() }
        }
        thoughts = recent
        loadError = nil
    }

    private func ensureDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard lstat(directory.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw ThoughtStoreError.invalidStoreFile
        }
        if usesDefaultDirectory && chmod(directory.path, S_IRWXU) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
