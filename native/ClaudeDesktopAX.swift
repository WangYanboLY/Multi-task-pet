import AppKit
import ApplicationServices
import CryptoKit
import Foundation

/// A title visible in Claude's ordinary-chat sidebar. Title-only keys are
/// best-effort identifiers; only a UUID obtained from AX can identify a chat
/// reliably across renames and support a stable deep link.
struct ClaudeDesktopConversation {
    let key: String
    let title: String
    let family: String
    let status: String
    let url: String?
}

/// `observed` implies Accessibility permission was already granted. Reasons
/// include accessibility_permission_denied, app_not_running, window_unavailable,
/// sidebar_unavailable, and ordinary_chat_not_visible.
enum ClaudeDesktopScan {
    case unavailable(reason: String)
    case observed([ClaudeDesktopConversation])
}

enum ClaudeDesktopAX {
    private static let bundleID = "com.anthropic.claudefordesktop"
    private static let defaultFamily = "Claude 桌面聊天"
    private static let uuidPattern = try! NSRegularExpression(
        pattern: #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
    )
    private static let excludedLabels: Set<String> = [
        "all chats", "artifacts", "chats", "claude", "code", "create project",
        "customize", "home", "new", "new chat", "new from a template",
        "pinned", "projects", "recent", "recents", "scheduled", "search",
        "settings", "starred", "view all", "see all"
    ]

    /// Inspects only the selected Claude window and its left sidebar. This
    /// never requests Accessibility permission, changes focus, or clicks UI.
    static func scan() -> ClaudeDesktopScan {
        guard AXIsProcessTrusted() else {
            return .unavailable(reason: "accessibility_permission_denied")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) else {
            return .unavailable(reason: "app_not_running")
        }
        var records: [ClaudeDesktopConversation] = []
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let windows = candidateWindows(of: application)
        guard !windows.isEmpty else { return .unavailable(reason: "window_unavailable") }
        var foundSidebar = false
        var foundOrdinaryChat = false
        for window in windows.prefix(8) {
            guard let windowFrame = frame(of: window) else { continue }
            var discoveryBudget = 240
            guard let sidebar = findSidebar(in: window, windowFrame: windowFrame,
                                            depth: 0, budget: &discoveryBudget) else { continue }
            foundSidebar = true
            // Code's sidebar is not the ordinary-chat list. More than one
            // Claude window may exist, so continue to any ordinary window.
            var modeBudget = 220
            if selectedMode(in: sidebar) == "code"
                || hasCodeSessionControl(in: sidebar, depth: 0, budget: &modeBudget)
                || isCodeWindow(window) { continue }
            foundOrdinaryChat = true
            let selected = currentWindowChat(in: window)
            let start = records.count
            var scanBudget = 550
            collectConversations(in: sidebar, family: defaultFamily, inChatList: false,
                                 selectedURL: selected?.url, depth: 0, budget: &scanBudget,
                                 into: &records)
            if let selected, let uuid = chatUUID(selected.url) {
                let matching = (start..<records.count).filter { records[$0].title == selected.title }
                if matching.count == 1, let index = matching.first {
                    let old = records[index]
                    records[index] = ClaudeDesktopConversation(
                        key: uuid, title: old.title, family: old.family,
                        status: old.status, url: "claude://claude.ai/chat/\(uuid)"
                    )
                } else if matching.isEmpty {
                    records.append(ClaudeDesktopConversation(
                        key: uuid, title: selected.title, family: defaultFamily,
                        status: "unknown", url: "claude://claude.ai/chat/\(uuid)"
                    ))
                }
            }
        }
        guard foundOrdinaryChat else {
            return .unavailable(reason: foundSidebar ? "ordinary_chat_not_visible" : "sidebar_unavailable")
        }
        var seen: Set<String> = []
        return .observed(records.filter { chat in
            return seen.insert(chat.key).inserted
        })
    }

    private static func candidateWindows(of application: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let raw = value(of: application, attribute as CFString),
               CFGetTypeID(raw) == AXUIElementGetTypeID() {
                result.append(raw as! AXUIElement)
            }
        }
        result.append(contentsOf: elements(of: application, kAXWindowsAttribute as CFString))
        var unique: [AXUIElement] = []
        for window in result where !unique.contains(where: { CFEqual($0, window) }) {
            unique.append(window)
        }
        return unique
    }

    private static func findSidebar(in element: AXUIElement, windowFrame: CGRect,
                                    depth: Int, budget: inout Int) -> AXUIElement? {
        guard depth <= 18, budget > 0 else { return nil }
        budget -= 1
        if string(of: element, kAXSubroleAttribute as CFString) == "AXLandmarkComplementary",
           let box = frame(of: element),
           abs(box.minX - windowFrame.minX) < 80,
           box.width >= 120, box.width <= windowFrame.width * 0.48,
           box.height >= windowFrame.height * 0.35 {
            return element
        }
        for child in children(of: element) {
            if let found = findSidebar(in: child, windowFrame: windowFrame,
                                       depth: depth + 1, budget: &budget) {
                return found
            }
        }
        return nil
    }

    private static func hasCodeSessionControl(in element: AXUIElement, depth: Int,
                                              budget: inout Int) -> Bool {
        guard depth <= 13, budget > 0 else { return false }
        budget -= 1
        if string(of: element, kAXRoleAttribute as CFString) == "AXButton",
           (string(of: element, kAXDescriptionAttribute as CFString)
                ?? string(of: element, kAXTitleAttribute as CFString)
                ?? sidebarItemTitle(element)).hasPrefix("New session") {
            return true
        }
        for child in children(of: element) {
            if hasCodeSessionControl(in: child, depth: depth + 1, budget: &budget) {
                return true
            }
        }
        return false
    }

    private static func selectedMode(in sidebar: AXUIElement) -> String? {
        var budget = 90
        func find(_ element: AXUIElement, depth: Int) -> String? {
            guard depth <= 10, budget > 0 else { return nil }
            budget -= 1
            if string(of: element, kAXRoleAttribute as CFString) == "AXRadioButton",
               let active = value(of: element, kAXValueAttribute as CFString) as? NSNumber,
               active.boolValue {
                let label = (string(of: element, kAXDescriptionAttribute as CFString)
                    ?? string(of: element, kAXTitleAttribute as CFString) ?? "").lowercased()
                if label.hasPrefix("claude") { return "claude" }
                if label.hasPrefix("code") { return "code" }
            }
            for child in children(of: element) {
                if let mode = find(child, depth: depth + 1) { return mode }
            }
            return nil
        }
        return find(sidebar, depth: 0)
    }

    private static func collectConversations(in element: AXUIElement, family: String,
                                             inChatList: Bool, selectedURL: String?, depth: Int,
                                             budget: inout Int,
                                             into records: inout [ClaudeDesktopConversation]) {
        guard depth <= 15, budget > 0 else { return }
        budget -= 1
        let role = string(of: element, kAXRoleAttribute as CFString) ?? ""
        let descendants = children(of: element)
        let localFamily = projectHeading(in: element, children: descendants) ?? family
        let listContext = inChatList || ["AXList", "AXOutline", "AXTable"].contains(role)
            || isChatListContainer(element, children: descendants)

        if role == "AXLink" || role == "AXButton" {
            let rawTitle = sidebarItemTitle(element)
            let rowTitle = role == "AXButton" ? conversationRowTitle(element) : nil
            let title = cleanTitle(rowTitle ?? rawTitle)
            let verifiedRow = rowTitle != nil
            let rawURL = urlString(of: element)
            let isSelected = (value(of: element, kAXSelectedAttribute as CFString) as? NSNumber)?.boolValue == true
                || string(of: element, "AXCurrent" as CFString) == "page"
            let chatURL = rawURL.flatMap(validChatURL) ?? (isSelected ? selectedURL : nil)
            let identifier = string(of: element, kAXIdentifierAttribute as CFString) ?? ""
            let identifierUUID = (listContext || verifiedRow) && (identifier.lowercased().contains("chat")
                || identifier.lowercased().contains("conversation"))
                ? uuidInText(identifier) : nil
            let uuid = chatURL.flatMap(chatUUID) ?? identifierUUID
            let hasLabelChild = firstStaticText(in: element, depth: 0, budget: 12) != nil
            let isCandidate = uuid != nil || chatURL != nil
                || (listContext && (role == "AXLink" || hasLabelChild))
                || verifiedRow
            if isCandidate, !title.isEmpty,
               (verifiedRow || !isControlLabel(title)),
               !isProjectHeader(element) {
                // Keep same-title rows distinct. The ordinal is provisional:
                // Claude does not expose a stable ID for every sidebar row.
                let ordinal = records.filter { $0.family == localFamily && $0.title == title }.count
                let key = uuid ?? "\(fallbackKey(family: localFamily, title: title)):\(ordinal)"
                records.append(ClaudeDesktopConversation(
                    key: key, title: title, family: localFamily,
                    status: explicitStatus(in: element, rawTitle: rawTitle,
                                           canonicalTitle: rowTitle), url: chatURL
                ))
            }
        }
        for child in descendants {
            collectConversations(in: child, family: localFamily, inChatList: listContext,
                                 selectedURL: selectedURL, depth: depth + 1,
                                 budget: &budget, into: &records)
        }
    }

    /// URL attributes on a window or web area are metadata; do not descend
    /// into the web area's chat content while looking for the selected URL.
    private static func currentWindowChat(in window: AXUIElement) -> (url: String, title: String)? {
        var budget = 30
        func find(_ element: AXUIElement, depth: Int) -> (url: String, title: String)? {
            guard depth <= 12, budget > 0 else { return nil }
            budget -= 1
            let role = string(of: element, kAXRoleAttribute as CFString)
            if role == "AXWebArea" {
                if let raw = urlString(of: element), let url = validChatURL(raw) {
                    let rawTitle = string(of: element, kAXTitleAttribute as CFString) ?? ""
                    let title = cleanTitle(rawTitle.replacingOccurrences(of: " - Claude", with: ""))
                    if !title.isEmpty { return (url, title) }
                }
                // The web area's descendants contain the chat transcript.
                return nil
            }
            for child in children(of: element) {
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return find(window, depth: 0)
    }

    /// During a mode switch the Claude radio button can change before the
    /// Code sidebar disappears. The web area's URL is a second, independent
    /// signal and can be checked without traversing chat messages.
    private static func isCodeWindow(_ window: AXUIElement) -> Bool {
        var budget = 30
        func find(_ element: AXUIElement, depth: Int) -> Bool {
            guard depth <= 12, budget > 0 else { return false }
            budget -= 1
            if string(of: element, kAXRoleAttribute as CFString) == "AXWebArea" {
                if let raw = urlString(of: element), let url = URL(string: raw),
                   url.host?.lowercased() == "claude.ai",
                   url.path.hasPrefix("/epitaxy/") { return true }
                return false
            }
            return children(of: element).contains { find($0, depth: depth + 1) }
        }
        return find(window, depth: 0)
    }

    private static func projectHeading(in element: AXUIElement,
                                       children: [AXUIElement]) -> String? {
        guard string(of: element, kAXRoleAttribute as CFString) == "AXGroup",
              children.contains(where: {
                  ["AXList", "AXOutline"].contains(
                      string(of: $0, kAXRoleAttribute as CFString) ?? "")
              }) else {
            return nil
        }
        // The project header sits inside several AXGroups beside the list.
        // Requiring its own Toggle sessions control keeps chat rows from
        // becoming project headings when they contain nested preview groups.
        func findHeader(_ candidate: AXUIElement, depth: Int) -> String? {
            guard depth >= 0 else { return nil }
            if string(of: candidate, kAXRoleAttribute as CFString) == "AXButton",
               isProjectHeader(candidate) {
                let title = cleanTitle(sidebarItemTitle(candidate))
                if !title.isEmpty, !isControlLabel(title) { return title }
            }
            for child in Self.children(of: candidate) {
                if let title = findHeader(child, depth: depth - 1) { return title }
            }
            return nil
        }
        for child in children where string(of: child, kAXRoleAttribute as CFString) != "AXList" {
            if let title = findHeader(child, depth: 5) { return title }
        }
        return nil
    }

    private static func isChatListContainer(_ element: AXUIElement,
                                            children: [AXUIElement]) -> Bool {
        let description = (string(of: element, kAXDescriptionAttribute as CFString) ?? "")
            .lowercased()
        if ["conversation", "chat history", "recent chats"].contains(where: description.contains) {
            return true
        }
        return children.contains {
            let role = string(of: $0, kAXRoleAttribute as CFString)
            guard role == "AXHeading" || role == "AXStaticText" else { return false }
            let text = (string(of: $0, kAXTitleAttribute as CFString)
                ?? string(of: $0, kAXValueAttribute as CFString) ?? "").lowercased()
            return ["chats", "recent", "recents"].contains(text)
        }
    }

    /// Claude puts project conversations in an AXList, but recent and
    /// ungrouped conversations are plain rows. Their title button has a
    /// matching "More options for …" sibling. Project headers are rejected
    /// separately, including when they are inside an AXList.
    private static func conversationRowTitle(_ element: AXUIElement) -> String? {
        guard let rawParent = value(of: element, kAXParentAttribute as CFString),
              CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { return nil }
        let parent = rawParent as! AXUIElement
        for sibling in children(of: parent) {
            // Electron wraps the popup in an AXGroup next to the title button.
            let candidates = [sibling] + (string(of: sibling, kAXRoleAttribute as CFString) == "AXGroup"
                ? children(of: sibling) : [])
            for candidate in candidates {
                guard string(of: candidate, kAXRoleAttribute as CFString) == "AXPopUpButton" else {
                    continue
                }
                let label = string(of: candidate, kAXDescriptionAttribute as CFString)
                    ?? string(of: candidate, kAXTitleAttribute as CFString) ?? ""
                let prefix = "More options for "
                guard label.hasPrefix(prefix) else { continue }
                let title = String(label.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { return title }
            }
        }
        return nil
    }

    private static func isProjectHeader(_ element: AXUIElement) -> Bool {
        func isToggle(_ candidate: AXUIElement) -> Bool {
            guard string(of: candidate, kAXRoleAttribute as CFString) == "AXButton" else {
                return false
            }
            let label = string(of: candidate, kAXDescriptionAttribute as CFString)
                ?? string(of: candidate, kAXTitleAttribute as CFString) ?? ""
            return label.hasPrefix("Toggle sessions for ")
        }
        func containsToggle(_ candidate: AXUIElement, depth: Int) -> Bool {
            if isToggle(candidate) { return true }
            guard depth > 0 else { return false }
            return children(of: candidate).contains {
                containsToggle($0, depth: depth - 1)
            }
        }
        if containsToggle(element, depth: 2) { return true }
        guard let rawParent = value(of: element, kAXParentAttribute as CFString),
              CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { return false }
        return children(of: rawParent as! AXUIElement).contains(where: isToggle)
    }

    private static func sidebarItemTitle(_ element: AXUIElement) -> String {
        if let title = string(of: element, kAXTitleAttribute as CFString), !title.isEmpty {
            return title
        }
        return firstStaticText(in: element, depth: 0, budget: 12) ?? ""
    }

    private static func firstStaticText(in element: AXUIElement, depth: Int,
                                        budget: Int) -> String? {
        guard depth <= 3, budget > 0 else { return nil }
        for child in children(of: element).prefix(budget) {
            if string(of: child, kAXRoleAttribute as CFString) == "AXStaticText",
               let text = string(of: child, kAXValueAttribute as CFString), !text.isEmpty {
                return text
            }
            if let text = firstStaticText(in: child, depth: depth + 1, budget: budget - 1) {
                return text
            }
        }
        return nil
    }

    private static func explicitStatus(in element: AXUIElement, rawTitle: String,
                                       canonicalTitle: String?) -> String {
        var budget = 20
        if let marker = statusMarker(in: element, depth: 0, budget: &budget) {
            return marker
        }
        // Ordinary-chat rows can expose the Running badge beside the title
        // button. Inspect only that button's own row, never the whole list.
        if let rawParent = value(of: element, kAXParentAttribute as CFString),
           CFGetTypeID(rawParent) == AXUIElementGetTypeID() {
            let parent = rawParent as! AXUIElement
            let titleButtons = children(of: parent).filter {
                string(of: $0, kAXRoleAttribute as CFString) == "AXButton"
            }
            if titleButtons.count == 1 {
                budget = 20
                if let marker = statusMarker(in: parent, depth: 0, budget: &budget) {
                    return marker
                }
            }
        }
        // Some versions put the status into the button name. A separate
        // row-menu label establishes the real title before treating a prefix
        // as a status; "Running experiments" may simply be a chat title.
        if let canonicalTitle {
            let shown = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            for (prefix, status) in [("Running ", "working"), ("Idle ", "idle"),
                                     ("Awaiting input ", "waiting")] {
                if shown == prefix + canonicalTitle { return status }
            }
        }
        return "unknown"
    }

    private static func statusMarker(in element: AXUIElement, depth: Int,
                                     budget: inout Int) -> String? {
        guard depth <= 4, budget > 0 else { return nil }
        budget -= 1
        let role = string(of: element, kAXRoleAttribute as CFString) ?? ""
        if string(of: element, kAXSubroleAttribute as CFString) == "AXApplicationStatus"
            || ["AXGroup", "AXImage", "AXStaticText"].contains(role) {
            let label = string(of: element, kAXDescriptionAttribute as CFString)
                ?? string(of: element, kAXTitleAttribute as CFString)
                ?? string(of: element, kAXValueAttribute as CFString)
            switch label?.lowercased() {
            case "running": return "working"
            case "idle": return "idle"
            case "awaiting input": return "waiting"
            default: break
            }
        }
        for child in children(of: element) {
            if let marker = statusMarker(in: child, depth: depth + 1, budget: &budget) {
                return marker
            }
        }
        return nil
    }

    private static func cleanTitle(_ value: String) -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(title.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isControlLabel(_ value: String) -> Bool {
        let lower = value.lowercased()
        return excludedLabels.contains(lower) || lower.hasPrefix("new ")
            || lower.hasPrefix("more ") || lower.hasPrefix("filter ")
    }

    private static func fallbackKey(family: String, title: String) -> String {
        let input = Data("\(family.lowercased())\u{0}\(title.lowercased())".utf8)
        let digest = SHA256.hash(data: input)
        return "title:" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func validChatURL(_ raw: String) -> String? {
        let absolute = raw.hasPrefix("claude.ai/") ? "https://\(raw)" : raw
        guard let url = URL(string: absolute),
              ["https", "claude"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "claude.ai",
              url.query == nil, url.fragment == nil,
              chatUUID(absolute) != nil else { return nil }
        return absolute
    }

    private static func chatUUID(_ text: String) -> String? {
        guard let url = URL(string: text),
              url.pathComponents.contains("chat") || url.pathComponents.contains("conversation")
                || (url.scheme?.lowercased() == "claude" && url.host?.lowercased() == "chat") else {
            return nil
        }
        return uuidInText(url.path)
    }

    private static func uuidInText(_ text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = uuidPattern.firstMatch(in: text, range: range),
              let span = Range(match.range, in: text) else { return nil }
        return String(text[span]).lowercased()
    }

    private static func urlString(of element: AXUIElement) -> String? {
        for attribute in ["AXURL", "AXDocument"] {
            guard let raw = value(of: element, attribute as CFString) else { continue }
            if let url = raw as? URL { return url.absoluteString }
            if let text = raw as? String { return text }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        elements(of: element, kAXChildrenAttribute as CFString)
    }

    private static func elements(of element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        value(of: element, attribute) as? [AXUIElement] ?? []
    }

    private static func string(of element: AXUIElement, _ attribute: CFString) -> String? {
        value(of: element, attribute) as? String
    }

    private static func value(of element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else {
            return nil
        }
        return result
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let rawPosition = value(of: element, kAXPositionAttribute as CFString),
              let rawSize = value(of: element, kAXSizeAttribute as CFString),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
