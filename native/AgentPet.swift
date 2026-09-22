import AppKit
import SwiftUI

private enum Palette {
    static let ink = Color(red: 0.91, green: 0.94, blue: 0.99)
    static let muted = Color(red: 0.60, green: 0.67, blue: 0.78)
    static let panel = Color(red: 0.075, green: 0.095, blue: 0.16)
    static let card = Color(red: 0.12, green: 0.15, blue: 0.23)
    static let line = Color.white.opacity(0.09)
    static let mint = Color(red: 0.42, green: 0.92, blue: 0.77)
}

private struct TaskSnapshot: Decodable {
    let generatedAt: String
    let tasks: [AgentTask]
}

private struct AgentTask: Decodable, Identifiable {
    let id: String
    let source: String
    let familyId: String
    let family: String
    let title: String
    let status: String
    let updatedAt: String
    let detail: String?
    let completed: Int?
    let total: Int?
    let url: String?

    var normalizedStatus: String { status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var isDone: Bool { normalizedStatus == "done" }
    var isActive: Bool { ["working", "waiting"].contains(normalizedStatus) }
    var familyKey: String { familyId.isEmpty ? "\(source):\(id)" : familyId }
    var familyName: String { family.isEmpty ? title : family }

    var observedProgress: String? {
        guard let completed, let total, total > 0, completed >= 0, completed <= total else { return nil }
        return "\(completed)/\(total)"
    }

    var destination: URL? {
        guard let url, let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              ["https", "http", "codex"].contains(scheme) else { return nil }
        return parsed
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
    var hasActiveTask: Bool { tasks.contains(where: \.isActive) }
    var hasPendingTask: Bool { tasks.contains { !$0.isActive && !$0.isDone } }
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
    case claudeCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpt: return "GPT"
        case .claude: return "Claude"
        case .claudeCode: return "Claude Code"
        }
    }

    func includes(_ source: String) -> Bool {
        switch self {
        case .gpt: return ["codex", "chatgpt", "gpt"].contains(SourceStyle.normalized(source))
        case .claude: return SourceStyle.normalized(source) == "claude"
        case .claudeCode: return ["claude_code", "claudecode"].contains(SourceStyle.normalized(source))
        }
    }
}

@MainActor
private final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [AgentTask] = []
    @Published private(set) var generatedAt: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var message: String = "正在读取任务…"
    @Published private(set) var hasSnapshot = false

    let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-pet/tasks.json")

    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        lastCheckedAt = Date()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            tasks = []
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
            tasks = snapshot.tasks
            generatedAt = snapshot.generatedAt
            hasSnapshot = true
            message = snapshot.tasks.isEmpty ? "目前没有观察到任务。" : ""
        } catch {
            // Keep the last good snapshot if a writer is replacing the file.
            message = "本次读取失败：\(error.localizedDescription)"
        }
    }

    private func families(for selected: [AgentTask]) -> [TaskFamily] {
        let grouped = Dictionary(grouping: selected, by: \.familyKey)
        return grouped.map { key, entries in
            let ordered = entries.sorted { $0.updatedAt > $1.updatedAt }
            return TaskFamily(id: key,
                              name: ordered.first?.familyName ?? "未命名任务族",
                              tasks: ordered,
                              newestUpdate: ordered.first?.updatedAt ?? "")
        }.sorted { $0.newestUpdate > $1.newestUpdate }
    }

    var activeFamilies: [TaskFamily] { families(for: tasks).filter(\.hasActiveTask) }
    var pendingFamilies: [TaskFamily] { families(for: tasks).filter { !$0.hasActiveTask && $0.hasPendingTask } }

    func tasks(in category: SourceCategory) -> [AgentTask] {
        tasks.filter { category.includes($0.source) }
    }

    func taskCount(in category: SourceCategory) -> Int { tasks(in: category).count }
    func activeCount(in category: SourceCategory) -> Int { tasks(in: category).filter(\.isActive).count }
    func pendingCount(in category: SourceCategory) -> Int {
        tasks(in: category).filter { !$0.isActive && !$0.isDone }.count
    }
    func failedCount(in category: SourceCategory) -> Int {
        tasks(in: category).filter { $0.normalizedStatus == "failed" }.count
    }
    func activeFamilies(in category: SourceCategory) -> [TaskFamily] {
        families(for: tasks(in: category)).filter(\.hasActiveTask)
    }
    func pendingFamilies(in category: SourceCategory) -> [TaskFamily] {
        families(for: tasks(in: category)).filter { !$0.hasActiveTask && $0.hasPendingTask }
    }
    func recentDone(in category: SourceCategory) -> [AgentTask] {
        Array(tasks(in: category).filter(\.isDone).sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
    }
    var uncategorizedCount: Int {
        tasks.filter { task in !SourceCategory.allCases.contains { $0.includes(task.source) } }.count
    }

    var recentDone: [AgentTask] {
        Array(tasks.filter(\.isDone).sorted { $0.updatedAt > $1.updatedAt }.prefix(8))
    }

    var activeCount: Int { tasks.filter(\.isActive).count }
    var pendingCount: Int { tasks.filter { !$0.isActive && !$0.isDone }.count }
    var failedCount: Int { tasks.filter { $0.normalizedStatus == "failed" }.count }
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

private struct PetView: View {
    @ObservedObject var store: TaskStore
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

            Circle()
                .fill(store.isStale ? StatusStyle.color("waiting") : (store.failedCount > 0 ? StatusStyle.color("failed") : (store.activeCount > 0 ? Palette.mint : Palette.muted)))
                .frame(width: 24, height: 24)
                .overlay {
                    Text(!store.hasSnapshot || store.isStale ? "?" : (store.failedCount > 0 ? "!" : (store.activeCount > 9 ? "9+" : "\(store.activeCount)")))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.23))
                }
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                .offset(x: 40, y: -36)
        }
        .frame(width: 118, height: 126)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .accessibilityLabel(store.isStale ? "Agent Pet，采集器未更新，悬停查看详情" : "Agent Pet，\(store.activeCount) 个活跃任务，悬停查看详情")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Text(task.title.isEmpty ? "未命名对话" : task.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let destination = task.destination {
                    Button {
                        NSWorkspace.shared.open(destination)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.muted)
                    .help("打开对话")
                }
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
        .padding(11)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct FamilyCard: View {
    let family: TaskFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
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
            ForEach(Array(family.tasks.enumerated()), id: \.offset) { _, task in
                TaskRow(task: task)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }
}

private struct DashboardView: View {
    @ObservedObject var store: TaskStore
    let onClose: () -> Void
    let onQuit: () -> Void
    @State private var selectedCategory: SourceCategory = .gpt
    @State private var categoryInitialized = false

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
                }
                .help("立即刷新")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .help("关闭面板")
                Button(action: onQuit) {
                    Image(systemName: "power")
                }
                .help("退出 Agent Pet")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .padding(.bottom, 12)

            categoryTabs
                .padding(.bottom, 12)

            HStack(spacing: 8) {
                summaryNumber("\(store.activeFamilies(in: selectedCategory).count)", "活跃任务族", Palette.mint)
                summaryNumber("\(store.activeCount(in: selectedCategory))", "活跃对话", Color(red: 0.46, green: 0.84, blue: 0.95))
                summaryNumber("\(store.pendingCount(in: selectedCategory))", "待后续 / 需处理", store.failedCount(in: selectedCategory) > 0 ? StatusStyle.color("failed") : StatusStyle.color("waiting"))
            }
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 3) {
                Text("数据生成：\(TimeText.display(store.generatedAt))")
                Text("上次检查：\(store.lastCheckedAt.map(TimeText.display) ?? "尚未检查")")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.muted)
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

                    if store.hasSnapshot && store.taskCount(in: selectedCategory) == 0 {
                        emptyLabel("\(selectedCategory.title) 目前没有可观察到的任务")
                    }
                    if store.uncategorizedCount > 0 {
                        emptyLabel("另有 \(store.uncategorizedCount) 条来源未识别的记录，暂未归入这三个分类。")
                    }

                    sectionTitle("活跃任务族", count: store.activeFamilies(in: selectedCategory).count)
                    if store.activeFamilies(in: selectedCategory).isEmpty {
                        emptyLabel("当前没有活跃任务")
                    } else {
                        ForEach(store.activeFamilies(in: selectedCategory)) { family in
                            FamilyCard(family: family)
                        }
                    }

                    sectionTitle("待后续与需处理", count: store.pendingFamilies(in: selectedCategory).count)
                    if store.pendingFamilies(in: selectedCategory).isEmpty {
                        emptyLabel("暂无待后续记录")
                    } else {
                        ForEach(store.pendingFamilies(in: selectedCategory)) { family in
                            FamilyCard(family: family)
                        }
                    }

                    sectionTitle("最近完成", count: store.recentDone(in: selectedCategory).count)
                    if store.recentDone(in: selectedCategory).isEmpty {
                        emptyLabel("暂无已完成记录")
                    } else {
                        ForEach(Array(store.recentDone(in: selectedCategory).enumerated()), id: \.offset) { _, task in
                            TaskRow(task: task)
                        }
                    }
                }
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 8) {
                Text("网页聊天仅追踪已打开并安装浏览器伴侣的标签；普通 Claude / ChatGPT 桌面聊天暂无线索。")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("设置说明") {
                    if let readme = Bundle.main.resourceURL?.appendingPathComponent("SETUP.md") {
                        NSWorkspace.shared.activateFileViewerSelecting([readme])
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.mint)
                .fixedSize()
            }
            .padding(.top, 9)
            Text(store.fileURL.path)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 9)
        }
        .padding(17)
        .frame(width: 420, height: 600)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.13), lineWidth: 1))
        .preferredColorScheme(.dark)
        .onAppear { chooseInitialCategoryIfNeeded() }
        .onChange(of: store.generatedAt) { _ in chooseInitialCategoryIfNeeded() }
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
                        Text("\(store.taskCount(in: category))")
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

    private func chooseInitialCategoryIfNeeded() {
        guard !categoryInitialized, store.hasSnapshot else { return }
        var best = SourceCategory.gpt
        for candidate in [SourceCategory.claude, .claudeCode] {
            if store.activeCount(in: candidate) > store.activeCount(in: best) {
                best = candidate
            }
        }
        selectedCategory = best
        categoryInitialized = true
    }

    private func summaryNumber(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 11))
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
    private var petWindow: FloatingPanel!
    private var dashboardWindow: FloatingPanel!
    private var hoverTimer: Timer?
    private var outsideSince: Date?
    private var collectorProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let petSize = NSSize(width: 118, height: 126)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let petFrame = NSRect(x: screen.maxX - petSize.width - 28,
                              y: screen.minY + 28,
                              width: petSize.width, height: petSize.height)
        petWindow = makePanel(frame: petFrame, shadow: false)
        petWindow.delegate = self
        let petView = DraggablePetView(rootView: PetView(store: store, onHover: { [weak self] hovering in
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
