import AppKit
import SwiftUI
import UserNotifications

private enum Palette {
    static let ink = Color(red: 0.91, green: 0.94, blue: 0.99)
    static let muted = Color(red: 0.60, green: 0.67, blue: 0.78)
    static let panel = Color(red: 0.075, green: 0.095, blue: 0.16)
    static let card = Color(red: 0.12, green: 0.15, blue: 0.23)
    static let line = Color.white.opacity(0.09)
    static let mint = Color(red: 0.42, green: 0.92, blue: 0.77)
    static let amber = Color(red: 1.00, green: 0.79, blue: 0.36)
    static let sky = Color(red: 0.51, green: 0.76, blue: 1.00)
}

private struct TaskSnapshot: Decodable {
    let generatedAt: String
    let tasks: [AgentTask]
    let ignoredTaskIds: [String]?
    let scheduledTaskIds: [String]?
}

private struct AgentTask: Decodable, Identifiable {
    let id: String
    let source: String
    let familyId: String
    let family: String
    let title: String
    let topicLabel: String?
    let status: String
    let updatedAt: String
    let detail: String?
    let completed: Int?
    let total: Int?
    let url: String?
    let answerRevision: String?

    var normalizedStatus: String { status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var isDone: Bool { normalizedStatus == "done" }
    var isActive: Bool { ["working", "waiting"].contains(normalizedStatus) }
    func belongs(to filter: ConversationFilter, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard !isDone else { return false }
        let updatedToday = TimeText.date(updatedAt).map { date in
            date <= now && calendar.isDate(date, inSameDayAs: now)
        } ?? false
        if filter == .active { return isActive || updatedToday }
        return normalizedStatus == "waiting" || normalizedStatus == "failed"
    }
    var familyKey: String { familyId.isEmpty ? "\(source):\(id)" : familyId }
    var familyName: String { family.isEmpty ? title : family }
    var displayTitle: String {
        let label = topicLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty { return label }
        return title.isEmpty ? "未命名对话" : title
    }
    var hasDistinctTopicLabel: Bool {
        guard let label = topicLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty, !title.isEmpty else { return false }
        return label != title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var observedProgress: String? {
        guard let completed, let total, total > 0, completed >= 0, completed <= total else { return nil }
        return "\(completed)/\(total)"
    }

    var destination: URL? {
        DestinationURL.forTask(id: id, source: source, raw: url)
    }
}

private struct TaskFamily: Identifiable {
    let id: String
    let name: String
    let tasks: [AgentTask]
    let newestUpdate: String

    var workingCount: Int { tasks.filter { $0.normalizedStatus == "working" }.count }
    var waitingCount: Int { tasks.filter { $0.normalizedStatus == "waiting" }.count }
    var idleCount: Int { tasks.filter { $0.normalizedStatus == "idle" }.count }
    var failedCount: Int { tasks.filter { $0.normalizedStatus == "failed" }.count }
    var doneCount: Int { tasks.filter(\.isDone).count }
    var unknownCount: Int { tasks.filter { !["working", "waiting", "idle", "failed", "done"].contains($0.normalizedStatus) }.count }
    var statusSummary: String {
        var parts: [String] = []
        if workingCount > 0 { parts.append("\(workingCount) 进行中") }
        if waitingCount > 0 { parts.append("\(waitingCount) 等待中") }
        if idleCount > 0 { parts.append("\(idleCount) 待后续") }
        if failedCount > 0 { parts.append("\(failedCount) 需处理") }
        if doneCount > 0 { parts.append("\(doneCount) 已完成") }
        if unknownCount > 0 { parts.append("\(unknownCount) 未知") }
        return parts.joined(separator: " · ")
    }
}

private enum SourceCategory: String, CaseIterable, Identifiable {
    case gpt
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpt: return "GPT"
        case .claude: return "Claude"
        }
    }

    func includes(_ source: String) -> Bool {
        switch self {
        case .gpt: return ["codex", "chatgpt", "gpt"].contains(SourceStyle.normalized(source))
        case .claude: return ["claude", "claude_code", "claudecode"].contains(SourceStyle.normalized(source))
        }
    }
}

private enum ConversationFilter: String, CaseIterable, Identifiable {
    case active
    case needsHandling

    var id: String { rawValue }
    var title: String { self == .active ? "活跃对话" : "需要处理" }
    var emptyMessage: String { self == .active ? "当前没有活跃对话" : "当前没有需要处理的对话" }
    var tint: Color { self == .active ? Palette.mint : StatusStyle.color("failed") }
}

@MainActor
private final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [AgentTask] = []
    @Published private(set) var ignoredTaskIDs: [String] = []
    @Published private(set) var scheduledTaskIDs: Set<String> = []
    @Published private(set) var generatedAt: String?
    @Published private(set) var message: String = "正在读取任务…"
    @Published private(set) var hasSnapshot = false

    let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-pet/tasks.json")

    private var timer: Timer?
    var onSnapshot: (([AgentTask], [String]) -> Void)?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            tasks = []
            ignoredTaskIDs = []
            scheduledTaskIDs = []
            generatedAt = nil
            hasSnapshot = false
            message = "等待任务数据。采集器尚未写入 tasks.json。"
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let snapshot = try decoder.decode(TaskSnapshot.self, from: data)
            var ignored = Set(snapshot.ignoredTaskIds ?? [])
            ignored.formUnion(snapshot.tasks.filter { $0.id.hasPrefix("claude-agent:") }.map(\.id))
            ignoredTaskIDs = Array(ignored)
            scheduledTaskIDs = Set(snapshot.scheduledTaskIds ?? [])
            tasks = snapshot.tasks.filter { !ignored.contains($0.id) }
            generatedAt = snapshot.generatedAt
            hasSnapshot = true
            message = tasks.isEmpty ? "目前没有观察到任务。" : ""
            onSnapshot?(tasks, ignoredTaskIDs)
        } catch {
            // Keep the last good snapshot if a writer is replacing the file.
            message = "本次读取失败：\(error.localizedDescription)"
        }
    }

    func families(for selected: [AgentTask]) -> [TaskFamily] {
        let grouped = Dictionary(grouping: selected, by: \.familyKey)
        return grouped.map { key, entries in
            let ordered = entries.sorted { $0.updatedAt > $1.updatedAt }
            return TaskFamily(id: key,
                              name: ordered.first?.familyName ?? "未命名任务族",
                              tasks: ordered,
                              newestUpdate: ordered.first?.updatedAt ?? "")
        }.sorted { $0.newestUpdate > $1.newestUpdate }
    }

    func tasks(in category: SourceCategory) -> [AgentTask] {
        tasks.filter { category.includes($0.source) }
    }

    func tasks(in category: SourceCategory, filter: ConversationFilter) -> [AgentTask] {
        let now = Date()
        let calendar = Calendar.current
        return tasks(in: category).filter { $0.belongs(to: filter, now: now, calendar: calendar) }
    }
    func count(in category: SourceCategory, filter: ConversationFilter) -> Int {
        tasks(in: category, filter: filter).count
    }
    func visibleCount(in category: SourceCategory) -> Int {
        tasks(in: category).filter { !$0.isDone }.count
    }
    func activeCount(in category: SourceCategory) -> Int { tasks(in: category).filter(\.isActive).count }
    func families(in category: SourceCategory, filter: ConversationFilter) -> [TaskFamily] {
        families(for: tasks(in: category, filter: filter))
    }
    var uncategorizedCount: Int {
        tasks.filter { task in
            !task.isDone && !SourceCategory.allCases.contains { $0.includes(task.source) }
        }.count
    }

    var activeCount: Int { tasks.filter(\.isActive).count }
    var activeFamilyCount: Int { families(for: tasks.filter(\.isActive)).count }
    var isStale: Bool {
        guard hasSnapshot else { return false }
        guard let date = TimeText.date(generatedAt) else { return true }
        return abs(Date().timeIntervalSince(date)) > 15
    }
}

private enum TimeText {
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return precise.date(from: raw) ?? regular.date(from: raw)
    }

    static func display(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "未提供" }
        guard let parsed = date(raw) else { return raw }
        return display(parsed)
    }

    static func display(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter.string(from: date)
    }
}

private enum StatusStyle {
    static func label(_ status: String) -> String {
        switch status.lowercased() {
        case "working": return "进行中"
        case "waiting": return "等待中"
        case "done": return "已完成"
        case "failed": return "需处理"
        case "idle": return "待后续"
        default: return "未知"
        }
    }

    static func color(_ status: String) -> Color {
        switch status.lowercased() {
        case "working": return Palette.mint
        case "waiting": return Color(red: 1, green: 0.77, blue: 0.43)
        case "done": return Color(red: 0.62, green: 0.72, blue: 0.87)
        case "failed": return Color(red: 1, green: 0.50, blue: 0.58)
        case "idle": return Color(red: 0.62, green: 0.69, blue: 0.82)
        default: return Color(red: 0.68, green: 0.64, blue: 0.92)
        }
    }
}

private enum SourceStyle {
    static func normalized(_ source: String) -> String {
        source.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    static func label(_ source: String) -> String {
        switch normalized(source) {
        case "codex": return "Codex"
        case "claude_code", "claudecode": return "Claude Code"
        case "claude": return "Claude"
        case "chatgpt", "gpt": return "ChatGPT"
        default: return source.isEmpty ? "其他" : source
        }
    }

    static func color(_ source: String) -> Color {
        switch normalized(source) {
        case "codex": return Color(red: 0.46, green: 0.84, blue: 0.95)
        case "claude_code", "claudecode": return Color(red: 0.98, green: 0.68, blue: 0.50)
        case "claude": return Color(red: 0.98, green: 0.72, blue: 0.59)
        case "chatgpt", "gpt": return Color(red: 0.53, green: 0.89, blue: 0.72)
        default: return Palette.muted
        }
    }
}

private enum DestinationURL {
    static func forTask(id: String, source: String, raw: String?) -> URL? {
        if let raw, let parsed = URL(string: raw),
           let scheme = parsed.scheme?.lowercased() {
            if ["https", "http", "codex"].contains(scheme) { return parsed }
            if scheme == "claude", SourceStyle.normalized(source) == "claude",
               id.hasPrefix("claude-code:"), parsed.host == "code", parsed.path == "/continue",
               parsed.fragment == nil,
               let components = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
               let items = components.queryItems, items.count == 1,
               items[0].name == "session", let sessionID = items[0].value,
               sessionID.hasPrefix("local_"),
               UUID(uuidString: String(sessionID.dropFirst("local_".count))) != nil {
                return parsed
            }
        }
        guard SourceStyle.normalized(source) == "codex", id.hasPrefix("codex:") else { return nil }
        let threadID = String(id.dropFirst("codex:".count))
        guard UUID(uuidString: threadID) != nil else { return nil }
        return URL(string: "codex://threads/\(threadID)")
    }
}

private struct PetView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var inbox: AnswerInbox
    let onHover: (Bool) -> Void

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.18))
                .frame(width: 82, height: 15)
                .offset(y: 49)

            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(red: 0.20, green: 0.53, blue: 0.55))
                .frame(width: 26, height: 49)
                .rotationEffect(.degrees(-25))
                .offset(x: -29, y: -28)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(red: 0.20, green: 0.53, blue: 0.55))
                .frame(width: 26, height: 49)
                .rotationEffect(.degrees(25))
                .offset(x: 29, y: -28)

            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.59, green: 1.0, blue: 0.87),
                                              Color(red: 0.19, green: 0.68, blue: 0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 92, height: 88)
                .overlay(alignment: .topLeading) {
                    Ellipse().fill(Color.white.opacity(0.23))
                        .frame(width: 49, height: 20).rotationEffect(.degrees(-28))
                        .offset(x: 15, y: 8)
                }
                .shadow(color: Color(red: 0.15, green: 0.64, blue: 0.66).opacity(0.55), radius: 12, y: 5)
                .offset(y: 6)

            HStack(spacing: 25) {
                Capsule().fill(Color(red: 0.07, green: 0.22, blue: 0.31)).frame(width: 7, height: 13)
                Capsule().fill(Color(red: 0.07, green: 0.22, blue: 0.31)).frame(width: 7, height: 13)
            }.offset(y: 1)

            HStack(spacing: 46) {
                Circle().fill(Color(red: 1, green: 0.59, blue: 0.68).opacity(0.6)).frame(width: 12, height: 8)
                Circle().fill(Color(red: 1, green: 0.59, blue: 0.68).opacity(0.6)).frame(width: 12, height: 8)
            }.offset(y: 18)

            Text("⌣").font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.07, green: 0.22, blue: 0.31))
                .offset(y: 13)

            metric(store.activeCount, color: Palette.mint, label: "正在运行的对话", diameter: 26)
                .offset(x: -32, y: -40)
            metric(inbox.unreadCount, color: Palette.amber, label: "未查看的新回答", diameter: 31)
                .offset(x: 0, y: -46)
            metric(store.activeFamilyCount, color: Palette.sky, label: "活跃对话族", diameter: 23)
                .offset(x: 29, y: -38)
        }
        .frame(width: 118, height: 126)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .accessibilityLabel("Agent Pet，\(store.activeCount) 个运行中的对话，\(inbox.unreadCount) 个未查看的新回答，\(store.activeFamilyCount) 个活跃对话族，悬停查看详情")
    }

    private func metric(_ count: Int, color: Color, label: String, diameter: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(count > 9 ? "9+" : "\(count)")
                    .font(.system(size: diameter < 25 ? 9 : (diameter > 30 ? 11 : 10),
                                  weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.23))
            }
            .overlay(Circle().stroke(Color.white.opacity(0.92), lineWidth: 1.5))
            .help("\(label)：\(count)")
    }
}

private struct StatusPill: View {
    let status: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(StatusStyle.color(status)).frame(width: 6, height: 6)
            Text(StatusStyle.label(status)).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(StatusStyle.color(status))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(StatusStyle.color(status).opacity(0.13), in: Capsule())
    }
}

private struct SourcePill: View {
    let source: String

    var body: some View {
        Text(SourceStyle.label(source))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(SourceStyle.color(source))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(SourceStyle.color(source).opacity(0.13), in: Capsule())
    }
}

private struct TaskRow: View {
    let task: AgentTask
    let isUnread: Bool
    let onOpen: (AgentTask) -> Void
    let onResolve: (AgentTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                if isUnread {
                    Circle().fill(Palette.amber).frame(width: 7, height: 7).padding(.top, 4)
                        .accessibilityLabel("未查看的新回答")
                }
                if task.destination != nil {
                    Button { onOpen(task) } label: { titleLabel }
                        .buttonStyle(.plain)
                        .help("打开对话")
                } else {
                    titleLabel
                }
                Toggle("已处理", isOn: Binding(
                    get: { false },
                    set: { if $0 { onResolve(task) } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .fixedSize()
                .padding(.horizontal, 3)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .help("将这条任务标记为已处理")
                if task.destination != nil {
                    Button {
                        onOpen(task)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.muted)
                    .help("打开对话")
                }
            }
            if task.destination != nil {
                Button { onOpen(task) } label: { taskDetails }
                    .buttonStyle(.plain)
                    .help("打开对话")
            } else {
                taskDetails
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var titleLabel: some View {
        Text(task.displayTitle)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            if task.hasDistinctTopicLabel {
                Text(task.title)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
            }
            if let detail = task.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
            }
            HStack(spacing: 6) {
                SourcePill(source: task.source)
                StatusPill(status: task.status)
                if let progress = task.observedProgress {
                    Text(progress)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            Text("更新：\(TimeText.display(task.updatedAt))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct FamilyCard: View {
    let family: TaskFamily
    let unreadIDs: Set<String>
    let onOpen: (AgentTask) -> Void
    let onResolve: (AgentTask) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.mint)
                        Text(family.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text("\(family.tasks.count) 项")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.muted)
                    }
                    Text(family.statusSummary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !expanded {
                        ForEach(Array(family.tasks.prefix(3))) { task in
                            Text("· \(task.displayTitle)")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if family.tasks.count > 3 {
                            Text("还有 \(family.tasks.count - 3) 项")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(family.name)，\(family.tasks.count) 项，\(family.tasks.prefix(3).map(\.displayTitle).joined(separator: "，"))")
            .accessibilityValue(expanded ? "已展开" : "已折叠")

            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(family.tasks) { task in
                        TaskRow(task: task, isUnread: unreadIDs.contains(task.id),
                                onOpen: onOpen, onResolve: onResolve)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }
}

@MainActor
private final class DashboardRoute: ObservableObject {
    @Published private(set) var version = 0
    private(set) var source = ""

    func showNeedsHandling(source: String) {
        self.source = source
        version += 1
    }
}

private struct DashboardView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var inbox: AnswerInbox
    @ObservedObject var resolutions: ManualResolutionStore
    @ObservedObject var thoughtStore: ThoughtStore
    @ObservedObject var route: DashboardRoute
    let onClose: () -> Void
    let onQuit: () -> Void
    @State private var selectedCategory: SourceCategory = .gpt
    @State private var selectedFilter: ConversationFilter = .active
    @State private var categoryInitialized = false
    @State private var thoughtDraft = ""
    @State private var thoughtFeedback = ""
    @State private var showThoughts = false
    @State private var showResolved = false
    @State private var resolutionFeedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("✦  Agent Pet")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                    Text("任务观察面板")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { store.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .help("立即刷新")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .help("关闭面板")
                Button(action: onQuit) {
                    Image(systemName: "power")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .help("退出 Agent Pet")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .padding(.bottom, 12)

            categoryTabs
                .padding(.bottom, 9)

            conversationTabs
                .padding(.bottom, 12)

            if store.isStale {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("采集器未更新")
                        .fontWeight(.bold)
                    Text("快照超过 15 秒，以下状态可能过期")
                }
                .font(.system(size: 10))
                .foregroundStyle(StatusStyle.color("waiting"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(StatusStyle.color("waiting").opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 10)
            }

            Rectangle().fill(Palette.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.message.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: store.hasSnapshot ? "info.circle" : "tray")
                            Text(store.message)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                    }

                    if store.hasSnapshot && store.visibleCount(in: selectedCategory) == 0 && unreadAnswers(in: selectedCategory).isEmpty {
                        emptyLabel("\(selectedCategory.title) 目前没有可观察到的任务")
                    }
                    if store.uncategorizedCount > 0 {
                        emptyLabel("另有 \(store.uncategorizedCount) 条来源未识别的记录，暂未归入这两个来源。")
                    }
                    if !resolutionFeedback.isEmpty {
                        Text(resolutionFeedback)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                    if resolutions.storageError != nil {
                        Text("已处理记录暂时无法保存；请检查本机存储。")
                            .font(.system(size: 11))
                            .foregroundStyle(StatusStyle.color("failed"))
                    }

                    conversationContent
                    resolvedSection
                    thoughtsHistory
                }
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .id("\(selectedCategory.rawValue):\(selectedFilter.rawValue)")

            Rectangle().fill(Palette.line).frame(height: 1)
            thoughtComposer
        }
        .padding(17)
        .frame(width: 420, height: 600)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.13), lineWidth: 1))
        .preferredColorScheme(.dark)
        .onAppear {
            chooseInitialCategoryIfNeeded()
            if route.version > 0 { applyRoute() }
        }
        .onChange(of: store.generatedAt) { _ in chooseInitialCategoryIfNeeded() }
        .onChange(of: route.version) { _ in applyRoute() }
    }

    @ViewBuilder
    private var thoughtsHistory: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showThoughts.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: showThoughts ? "chevron.down" : "chevron.right")
                Text("随手想法").font(.system(size: 12, weight: .semibold))
                Text("\(thoughtStore.thoughts.count)").font(.system(size: 10))
                Spacer()
            }
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if showThoughts {
            if thoughtStore.thoughts.isEmpty {
                emptyLabel("还没有保存想法")
            } else {
                ForEach(thoughtStore.thoughts.prefix(20)) { thought in
                    Text(thought.text)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
                }
            }
        }
    }

    private var thoughtComposer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("随手记下一个想法…", text: $thoughtDraft, axis: .vertical)
                    .font(.system(size: 12))
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(9)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
                Button(action: saveThought) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Palette.mint)
                }
                .buttonStyle(.plain)
                .disabled(thoughtDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("保存想法")
            }
            if !thoughtFeedback.isEmpty {
                Text(thoughtFeedback)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.vertical, 9)
    }

    private func saveThought() {
        do {
            try thoughtStore.save(thoughtDraft)
            thoughtDraft = ""
            thoughtFeedback = "已保存在本机"
        } catch {
            thoughtFeedback = error.localizedDescription
        }
    }

    @ViewBuilder
    private var conversationContent: some View {
        if selectedFilter == .active {
            let active = visibleTasks(in: selectedCategory, filter: .active)
            let families = store.families(for: active)
            sectionTitle("活跃对话", count: active.count)
            if families.isEmpty {
                emptyLabel(ConversationFilter.active.emptyMessage)
            } else {
                ForEach(families) { family in
                    FamilyCard(family: family, unreadIDs: unreadIDs,
                               onOpen: openTask, onResolve: resolveTask)
                }
            }
        } else {
            let pendingTasks = visibleTasks(in: selectedCategory, filter: .needsHandling)
            let pending = store.families(for: pendingTasks)
            let unread = unreadAnswers(in: selectedCategory)
            if pending.isEmpty && unread.isEmpty {
                emptyLabel(ConversationFilter.needsHandling.emptyMessage)
            } else {
                sectionTitle("待你操作", count: pendingTasks.count)
                ForEach(pending) { family in
                    FamilyCard(family: family, unreadIDs: unreadIDs,
                               onOpen: openTask, onResolve: resolveTask)
                }
                sectionTitle("未查看的新回答", count: unread.count)
                ForEach(unread) { answer in
                    unreadRow(answer)
                }
            }
        }
    }

    @ViewBuilder
    private var resolvedSection: some View {
        let entries = resolutions.resolved
            .filter { selectedCategory.includes($0.source) &&
                (selectedFilter != .needsHandling || !store.scheduledTaskIDs.contains($0.id)) }
            .sorted { $0.resolvedAt > $1.resolvedAt }
        if !entries.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showResolved.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: showResolved ? "chevron.down" : "chevron.right")
                    Text("已处理").font(.system(size: 12, weight: .semibold))
                    Text("\(entries.count)").font(.system(size: 10))
                    Spacer()
                }
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showResolved ? "已展开" : "已折叠")
            if showResolved {
                ForEach(entries) { entry in
                    let currentTask = store.tasks.first { $0.id == entry.id }
                    Toggle(isOn: Binding(
                        get: { true },
                        set: { if !$0 { restoreTask(id: entry.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(currentTask?.displayTitle ?? (entry.title.isEmpty ? "未命名对话" : entry.title))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.ink)
                            if let currentTask, currentTask.hasDistinctTopicLabel {
                                Text(currentTask.title)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(2)
                            }
                            Text("取消勾选即可恢复")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
                }
            }
        }
    }

    private var unreadIDs: Set<String> { Set(inbox.unread.map(\.id)) }

    private func visibleTasks(in category: SourceCategory, filter: ConversationFilter) -> [AgentTask] {
        store.tasks(in: category, filter: filter).filter {
            !resolutions.isResolved(id: $0.id) &&
                (filter != .needsHandling || !store.scheduledTaskIDs.contains($0.id))
        }
    }

    private func unreadAnswers(in category: SourceCategory) -> [UnreadAnswer] {
        inbox.unread.filter {
            category.includes($0.source) && !resolutions.isResolved(id: $0.id) &&
                !store.scheduledTaskIDs.contains($0.id)
        }
    }

    private func filterCount(in category: SourceCategory) -> Int {
        if selectedFilter == .active { return visibleTasks(in: category, filter: .active).count }
        return filterCountForNeeds(in: category)
    }

    private func filterCountForNeeds(in category: SourceCategory) -> Int {
        let pending = visibleTasks(in: category, filter: .needsHandling).map(\.id)
        let unread = unreadAnswers(in: category).map(\.id)
        return Set(pending + unread).count
    }

    private func unreadRow(_ answer: UnreadAnswer) -> some View {
        let currentTask = store.tasks.first { $0.id == answer.id }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(Palette.amber).frame(width: 7, height: 7)
                if destination(for: answer) != nil {
                    Button { openUnread(answer) } label: { unreadTitle(answer, currentTask: currentTask) }
                        .buttonStyle(.plain)
                        .help("打开对话")
                } else {
                    unreadTitle(answer, currentTask: currentTask)
                }
                Toggle("已处理", isOn: Binding(
                    get: { false },
                    set: { if $0 { resolveUnread(answer) } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .fixedSize()
                .padding(.horizontal, 3)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .help("将这条新回答标记为已处理")
            }
            if let currentTask, currentTask.hasDistinctTopicLabel {
                Text(currentTask.title)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                SourcePill(source: answer.source)
                Text("新回答：\(TimeText.display(answer.completedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                Spacer()
            }
            HStack(spacing: 11) {
                if destination(for: answer) != nil {
                    Button { openUnread(answer) } label: {
                        Text("打开对话").padding(.horizontal, 4).padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                }
                Button { inbox.markRead(id: answer.id) } label: {
                    Text("标为已读").padding(.horizontal, 4).padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.mint)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func unreadTitle(_ answer: UnreadAnswer, currentTask: AgentTask?) -> some View {
        Text(currentTask?.displayTitle ?? (answer.title.isEmpty ? "未命名对话" : answer.title))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func destination(for answer: UnreadAnswer) -> URL? {
        DestinationURL.forTask(id: answer.id, source: answer.source, raw: answer.url)
    }

    private func openUnread(_ answer: UnreadAnswer) {
        guard let destination = destination(for: answer) else { return }
        if NSWorkspace.shared.open(destination) { inbox.markRead(id: answer.id) }
    }

    private func openTask(_ task: AgentTask) {
        guard let destination = task.destination else { return }
        if NSWorkspace.shared.open(destination) { inbox.markRead(id: task.id) }
    }

    private func resolveTask(_ task: AgentTask) {
        let observation = TaskResolutionObservation(id: task.id, source: task.source,
                                                    title: task.title, status: task.status,
                                                    revision: task.answerRevision)
        do {
            try resolutions.markResolved(observation)
            inbox.markRead(id: task.id)
            showResolved = true
            resolutionFeedback = "已移到下方“已处理”，可取消勾选恢复。"
        } catch {
            resolutionFeedback = "保存已处理状态失败：\(error.localizedDescription)"
        }
    }

    private func resolveUnread(_ answer: UnreadAnswer) {
        if let task = store.tasks.first(where: { $0.id == answer.id }) {
            resolveTask(task)
            return
        }
        let observation = TaskResolutionObservation(id: answer.id, source: answer.source,
                                                    title: answer.title, status: "idle",
                                                    revision: answer.revision)
        do {
            try resolutions.markResolved(observation)
            inbox.markRead(id: answer.id)
            showResolved = true
            resolutionFeedback = "已移到下方“已处理”，可取消勾选恢复。"
        } catch {
            resolutionFeedback = "保存已处理状态失败：\(error.localizedDescription)"
        }
    }

    private func restoreTask(id: String) {
        do {
            try resolutions.restore(id: id)
            resolutionFeedback = ""
        } catch {
            resolutionFeedback = "恢复任务失败：\(error.localizedDescription)"
        }
    }

    private var categoryTabs: some View {
        HStack(spacing: 4) {
            ForEach(SourceCategory.allCases) { category in
                let selected = selectedCategory == category
                Button {
                    selectedCategory = category
                    categoryInitialized = true
                } label: {
                    HStack(spacing: 5) {
                        Text(category.title)
                            .font(.system(size: 11, weight: selected ? .bold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("\(filterCount(in: category))")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(selected ? 0.15 : 0.07), in: Capsule())
                    }
                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(selected ? Palette.mint.opacity(0.16) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Palette.mint.opacity(0.40) : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("查看 \(category.title) 的任务")
            }
        }
        .padding(4)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("任务来源分类")
    }

    private var conversationTabs: some View {
        HStack(spacing: 4) {
            ForEach(ConversationFilter.allCases) { filter in
                let selected = selectedFilter == filter
                Button {
                    selectedFilter = filter
                } label: {
                    HStack(spacing: 6) {
                        Text(filter.title)
                            .font(.system(size: 12, weight: selected ? .bold : .medium))
                        Text("\(filter == .active ? visibleTasks(in: selectedCategory, filter: .active).count : filterCountForNeeds(in: selectedCategory))")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(selected ? 0.16 : 0.07), in: Capsule())
                    }
                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selected ? filter.tint.opacity(0.16) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? filter.tint.opacity(0.45) : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("查看\(filter.title)")
            }
        }
        .padding(4)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("对话状态筛选")
    }

    private func chooseInitialCategoryIfNeeded() {
        guard !categoryInitialized, store.hasSnapshot else { return }
        var best = SourceCategory.gpt
        for candidate in [SourceCategory.claude] {
            if store.activeCount(in: candidate) > store.activeCount(in: best) {
                best = candidate
            }
        }
        selectedCategory = best
        categoryInitialized = true
    }

    private func applyRoute() {
        if let category = SourceCategory.allCases.first(where: { $0.includes(route.source) }) {
            selectedCategory = category
            categoryInitialized = true
        }
        selectedFilter = .needsHandling
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink)
            Text("\(count)").font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.07), in: Capsule())
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

private class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onMove: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseMoved(with event: NSEvent) { onMove?() }
}

private final class DraggablePetView<Content: View>: HoverHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        onEnter?()
        window?.performDrag(with: event)
        onMove?()
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PetAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = TaskStore()
    private let inbox = AnswerInbox()
    private let resolutions = ManualResolutionStore()
    private let thoughtStore = ThoughtStore()
    private let notifier = LocalNotifier()
    private let route = DashboardRoute()
    private var petWindow: FloatingPanel!
    private var dashboardWindow: FloatingPanel!
    private var hoverTimer: Timer?
    private var outsideSince: Date?
    private var collectorProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.prepare(onOpen: { [weak self] taskID in self?.openFromNotification(taskID) })
        if ProcessInfo.processInfo.arguments.contains("--notification-icon-test") {
            let content = UNMutableNotificationContent()
            content.title = "Agent Pet 图标测试"
            content.body = "请查看这条提醒左侧的应用图标。"
            let request = UNNotificationRequest(
                identifier: "agent-pet.icon-test.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error { NSLog("Agent Pet icon test notification failed: %@", error.localizedDescription) }
            }
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in NSApp.terminate(nil) }
            return
        }
        store.onSnapshot = { [weak self] tasks, ignoredIDs in
            self?.handleSnapshot(tasks, ignoredIDs: ignoredIDs)
        }
        if store.hasSnapshot { handleSnapshot(store.tasks, ignoredIDs: store.ignoredTaskIDs) }
        let petSize = NSSize(width: 118, height: 126)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let petFrame = NSRect(x: screen.maxX - petSize.width - 28,
                              y: screen.minY + 28,
                              width: petSize.width, height: petSize.height)
        petWindow = makePanel(frame: petFrame, shadow: false)
        petWindow.delegate = self
        let petView = DraggablePetView(rootView: PetView(store: store, inbox: inbox, onHover: { [weak self] hovering in
            if hovering { self?.showDashboard() } else { self?.checkHoverSoon() }
        }))
        petView.onEnter = { [weak self] in self?.showDashboard() }
        petView.onExit = { [weak self] in self?.checkHoverSoon() }
        petView.onMove = { [weak self] in self?.positionDashboard() }
        petWindow.contentView = petView
        petWindow.orderFrontRegardless()

        dashboardWindow = makePanel(frame: NSRect(x: 0, y: 0, width: 420, height: 600), shadow: true)
        let dashboardView = HoverHostingView(rootView: DashboardView(
            store: store,
            inbox: inbox,
            resolutions: resolutions,
            thoughtStore: thoughtStore,
            route: route,
            onClose: { [weak self] in self?.hideDashboard() },
            onQuit: { NSApp.terminate(nil) }
        ))
        dashboardView.onEnter = { [weak self] in self?.outsideSince = nil }
        dashboardView.onExit = { [weak self] in self?.checkHoverSoon() }
        dashboardWindow.contentView = dashboardView
        startCollector()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHover() }
        }
    }

    private func handleSnapshot(_ tasks: [AgentTask], ignoredIDs: [String]) {
        var ignored = Set(ignoredIDs)
        ignored.formUnion(tasks.filter { $0.id.hasPrefix("claude-agent:") }.map(\.id))
        ignored.formUnion(inbox.unread.filter { $0.id.hasPrefix("claude-agent:") }.map(\.id))
        ignored.formUnion(resolutions.resolved.filter { $0.id.hasPrefix("claude-agent:") }.map(\.id))
        inbox.discard(ids: ignored)
        resolutions.discard(ids: ignored)
        let tasks = tasks.filter { !ignored.contains($0.id) }
        let resolutionObservations = tasks.map { task in
            TaskResolutionObservation(id: task.id, source: task.source, title: task.title,
                                      status: task.status, revision: task.answerRevision)
        }
        resolutions.reconcile(resolutionObservations)
        let observations = tasks.map { task in
            AnswerObservation(id: task.id, source: task.source, title: task.title,
                              status: task.status, updatedAt: task.updatedAt,
                              revision: task.answerRevision, url: task.url)
        }
        let arrivals = inbox.ingest(observations)
        for entry in resolutions.resolved {
            if inbox.unread.first(where: { $0.id == entry.id })?.revision == entry.revision {
                inbox.markRead(id: entry.id)
            }
        }
        for answer in arrivals {
            notifier.notify(taskID: answer.id,
                            source: SourceStyle.label(answer.source),
                            title: answer.title)
        }
    }

    private func openFromNotification(_ taskID: String) {
        let task = store.tasks.first { $0.id == taskID }
        let answer = inbox.unread.first { $0.id == taskID }
        let destination = task?.destination ?? answer.flatMap {
            DestinationURL.forTask(id: $0.id, source: $0.source, raw: $0.url)
        }
        if let destination,
           NSWorkspace.shared.open(destination) {
            inbox.markRead(id: taskID)
            return
        }
        route.showNeedsHandling(source: task?.source ?? answer?.source ?? "")
        showDashboard()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hoverTimer?.invalidate()
        if let collectorProcess, collectorProcess.isRunning {
            collectorProcess.terminate()
        }
    }

    private func startCollector() {
        guard let collectorURL = Bundle.main.resourceURL?.appendingPathComponent("collector.py"),
              FileManager.default.fileExists(atPath: collectorURL.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [collectorURL.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try process.run()
            collectorProcess = process
        } catch {
            NSLog("Agent Pet collector could not start: %@", error.localizedDescription)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow, moved === petWindow else { return }
        positionDashboard()
    }

    private func makePanel(frame: NSRect, shadow: Bool) -> FloatingPanel {
        let panel = FloatingPanel(contentRect: frame,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = shadow
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func showDashboard() {
        guard dashboardWindow != nil else { return }
        outsideSince = nil
        positionDashboard()
        if !dashboardWindow.isVisible {
            dashboardWindow.orderFrontRegardless()
        }
    }

    private func hideDashboard() {
        dashboardWindow?.orderOut(nil)
        outsideSince = nil
    }

    private func checkHoverSoon() {
        outsideSince = Date()
    }

    private func checkHover() {
        guard petWindow != nil, dashboardWindow != nil else { return }
        let pointer = NSEvent.mouseLocation
        let overPet = petWindow.frame.insetBy(dx: -5, dy: -5).contains(pointer)
        if overPet {
            if !dashboardWindow.isVisible { showDashboard() }
            outsideSince = nil
            return
        }
        guard dashboardWindow.isVisible else { return }
        let overDashboard = dashboardWindow.frame.insetBy(dx: -5, dy: -5).contains(pointer)
        if overDashboard {
            outsideSince = nil
            return
        }
        if let outsideSince {
            if Date().timeIntervalSince(outsideSince) > 0.4 { hideDashboard() }
        } else {
            outsideSince = Date()
        }
    }

    private func positionDashboard() {
        guard petWindow != nil, dashboardWindow != nil else { return }
        let pet = petWindow.frame
        let visible = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: pet.midX, y: pet.midY)) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = dashboardWindow.frame.size
        let rightX = pet.maxX + 8
        let leftX = pet.minX - size.width - 8
        let x: CGFloat
        if rightX + size.width <= visible.maxX - 8 {
            x = rightX
        } else if leftX >= visible.minX + 8 {
            x = leftX
        } else {
            x = max(visible.minX + 8, min(rightX, visible.maxX - size.width - 8))
        }
        let y = max(visible.minY + 8, min(pet.midY - size.height / 2, visible.maxY - size.height - 8))
        let current = dashboardWindow.frame.origin
        if abs(current.x - x) > 0.5 || abs(current.y - y) > 0.5 {
            dashboardWindow.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

@main
private struct AgentPetApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PetAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
