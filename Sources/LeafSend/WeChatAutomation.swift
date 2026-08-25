import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AutomationResult {
    let state: TaskState
    let detail: String
}

enum ExecutionSource: String {
    case manual
    case scheduled
    case acceptance

    var title: String {
        switch self {
        case .manual: return "立即执行"
        case .scheduled: return "定时执行"
        case .acceptance: return "安全验收"
        }
    }
}

enum AutomationError: LocalizedError {
    case permission(String)
    case weChatNotRunning
    case invalidTask(String)
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permission(let message), .invalidTask(let message), .actionFailed(let message):
            return message
        case .weChatNotRunning:
            return "微信没有运行或尚未登录"
        }
    }
}

final class WeChatAutomation {
    static let revision = "verified-search-v3"

    private let commandDelay: useconds_t = 250_000
    private let searchFocusDelay: UInt64 = 600_000_000
    private let searchFieldRetryDelay: UInt64 = 100_000_000
    private let searchResultsDelay: UInt64 = 1_500_000_000
    private let chatOpenDelay: UInt64 = 1_000_000_000

    func execute(
        task: SendTask,
        realSend: Bool,
        source: ExecutionSource = .manual,
        accessibilityAllowed: Bool = PermissionCenter.hasAccessibility,
        restoreSenderAfterExecution: Bool = false,
        clearDraftAfterPreview: Bool = false
    ) async -> AutomationResult {
        defer {
            if restoreSenderAfterExecution {
                restoreSenderApplication()
            }
        }

        do {
            try validate(task)
            try verifyPermissions(accessibilityAllowed: accessibilityAllowed)
            trace("execution_source_\(source.rawValue)")
            trace("validated")
            let app = try await activateWeChat()
            trace("wechat_activated")
            try await openFirstSearchResult(contact: task.contact, app: app)

            if !task.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try ensureWeChatFrontmost(app)
                try pasteText(task.message, into: app)
                trace("message_pasted")
                if realSend {
                    try ensureWeChatFrontmost(app)
                    try press(.returnKey, in: app)
                    trace("message_send_enter_posted")
                    usleep(500_000)
                }
            }

            if !task.filePaths.isEmpty {
                if !realSend && !task.message.isEmpty {
                    return AutomationResult(
                        state: .draftReady,
                        detail: "文字草稿已填入；安全预览模式不会继续粘贴附件，避免覆盖草稿"
                    )
                }
                try ensureWeChatFrontmost(app)
                try pasteFiles(task.filePaths, into: app)
                trace("files_pasted")
                if realSend {
                    usleep(800_000)
                    try ensureWeChatFrontmost(app)
                    try press(.returnKey, in: app)
                    trace("file_send_enter_posted")
                    usleep(1_000_000)
                }
            }

            if !realSend {
                if clearDraftAfterPreview && !task.message.isEmpty && task.filePaths.isEmpty {
                    try ensureWeChatFrontmost(app)
                    try shortcut(keyCode: KeyCode.a.rawValue, modifiers: .maskCommand, in: app)
                    try press(.delete, in: app)
                    trace("preview_draft_cleared")
                }
                return AutomationResult(
                    state: .draftReady,
                    detail: "v1.0.1：\(source.title)已确认联系人写入搜索框并选择第一项；内容已填入，未按发送键"
                )
            }
            return AutomationResult(
                state: .submitted,
                detail: "v1.0.1：\(source.title)已确认联系人写入搜索框并选择第一项；已向微信投递发送按键"
            )
        } catch {
            return AutomationResult(
                state: .failed,
                detail: "v1.0.1：\(source.title)失败：\(error.localizedDescription)"
            )
        }
    }

    private func validate(_ task: SendTask) throws {
        guard !task.contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.invalidTask("联系人不能为空")
        }
        guard task.uniqueContactConfirmed else {
            throw AutomationError.invalidTask(
                "请先编辑任务并确认该联系人名称在微信中唯一；程序会直接选择搜索结果第一项"
            )
        }
        guard !task.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !task.filePaths.isEmpty else {
            throw AutomationError.invalidTask("消息和附件不能同时为空")
        }
        for path in task.filePaths where !FileManager.default.fileExists(atPath: path) {
            throw AutomationError.invalidTask("附件不存在：\(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }

    private func verifyPermissions(accessibilityAllowed: Bool) throws {
        guard accessibilityAllowed else {
            throw AutomationError.permission("缺少辅助功能权限，请在设置页授权")
        }
    }

    private func activateWeChat() async throws -> NSRunningApplication {
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.tencent.xinWeChat" ||
            $0.localizedName == "WeChat" || $0.localizedName == "微信"
        }
        let app: NSRunningApplication
        if let running = candidates.first {
            app = running
        } else {
            guard let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.tencent.xinWeChat"
            ) else {
                throw AutomationError.weChatNotRunning
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            app = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
        }
        try ensureWeChatFrontmost(app)
        return app
    }

    private func ensureWeChatFrontmost(_ app: NSRunningApplication) throws {
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)

        for _ in 0..<3 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return
            }

            if NSRunningApplication.current.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier {
                DispatchQueue.main.sync {
                    NSApplication.shared.hide(nil)
                }
            }

            app.unhide()
            app.activate(options: [.activateAllWindows])
            AXUIElementSetAttributeValue(
                applicationElement,
                kAXFrontmostAttribute as CFString,
                kCFBooleanTrue
            )
            Thread.sleep(forTimeInterval: 0.35)
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw AutomationError.actionFailed("无法将微信保持在前台，已停止；不会输入或发送内容")
        }
    }

    private func openFirstSearchResult(contact: String, app: NSRunningApplication) async throws {
        try ensureWeChatFrontmost(app)
        try openSearchMenu(in: app)
        trace("search_opened")
        try await Task.sleep(nanoseconds: searchFocusDelay)

        try ensureWeChatFrontmost(app)
        let searchField = try await waitForSearchField(in: app)
        try setSearchValue(contact, in: searchField)
        trace("contact_value_confirmed")
        try await Task.sleep(nanoseconds: searchResultsDelay)

        try ensureWeChatFrontmost(app)
        try confirmSearchField(searchField)
        trace("first_result_confirmed")
        try await Task.sleep(nanoseconds: chatOpenDelay)
        try ensureWeChatFrontmost(app)
        trace("chat_wait_complete")
    }

    private func openSearchMenu(in app: NSRunningApplication) throws {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = axElement(application, attribute: kAXMenuBarAttribute),
              let editMenu = findAXElement(in: menuBar, titles: ["编辑", "Edit"], roles: [kAXMenuBarItemRole as String]),
              let searchItem = findAXElement(in: editMenu, titles: ["搜索", "Search"], roles: [kAXMenuItemRole as String]) else {
            throw AutomationError.actionFailed("找不到微信菜单“编辑 → 搜索”，已停止")
        }
        let result = AXUIElementPerformAction(searchItem, kAXPressAction as CFString)
        guard result == .success else {
            throw AutomationError.actionFailed("无法打开微信搜索面板，已停止")
        }
    }

    private func waitForSearchField(in app: NSRunningApplication) async throws -> AXUIElement {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<20 {
            if let field = findSearchField(in: application),
               isAXValueSettable(field),
               axActionNames(field).contains(kAXConfirmAction as String) {
                trace("search_field_ready")
                return field
            }
            try await Task.sleep(nanoseconds: searchFieldRetryDelay)
        }
        throw AutomationError.actionFailed(
            "微信搜索框已打开，但没有取得可写入的搜索控件，已停止；不会选择联系人或发送消息"
        )
    }

    private func setSearchValue(_ contact: String, in searchField: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(
            searchField,
            kAXValueAttribute as CFString,
            contact as CFString
        )
        guard result == .success else {
            throw AutomationError.actionFailed(
                "无法把联系人写入微信搜索框，已停止；不会选择联系人或发送消息"
            )
        }

        guard axString(searchField, attribute: kAXValueAttribute) == contact else {
            throw AutomationError.actionFailed(
                "微信搜索框没有确认联系人内容，已停止；不会选择联系人或发送消息"
            )
        }
    }

    private func confirmSearchField(_ searchField: AXUIElement) throws {
        guard axActionNames(searchField).contains(kAXConfirmAction as String) else {
            throw AutomationError.actionFailed(
                "微信搜索框不支持确认操作，已停止；不会选择联系人或发送消息"
            )
        }
        let result = AXUIElementPerformAction(searchField, kAXConfirmAction as CFString)
        guard result == .success else {
            throw AutomationError.actionFailed(
                "无法确认微信搜索结果，已停止；不会输入或发送消息"
            )
        }
    }

    private func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as! AXUIElement?
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func axActionNames(_ element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private func isAXValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    private func findSearchField(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 12 else { return nil }
        let role = axString(root, attribute: kAXRoleAttribute) ?? ""
        let subrole = axString(root, attribute: kAXSubroleAttribute) ?? ""
        let identifier = axString(root, attribute: kAXIdentifierAttribute) ?? ""
        if Self.isSearchField(role: role, subrole: subrole, identifier: identifier) {
            return root
        }
        for child in axChildren(root) {
            if let match = findSearchField(in: child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    static func isSearchField(role: String, subrole: String, identifier: String) -> Bool {
        role == kAXTextFieldRole as String && (
            subrole == kAXSearchFieldSubrole as String || identifier == "_SC_SEARCH_FIELD"
        )
    }

    private func findAXElement(in root: AXUIElement, titles: [String], roles: [String], depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        let title = axString(root, attribute: kAXTitleAttribute) ?? ""
        let role = axString(root, attribute: kAXRoleAttribute) ?? ""
        if titles.contains(title) && roles.contains(role) { return root }
        for child in axChildren(root) {
            if let match = findAXElement(in: child, titles: titles, roles: roles, depth: depth + 1) { return match }
        }
        return nil
    }

    private func pasteText(_ text: String, into app: NSRunningApplication) throws {
        try putStringOnPasteboard(text)
        try shortcut(keyCode: KeyCode.v.rawValue, modifiers: .maskCommand, in: app)
        usleep(commandDelay)
    }

    private func pasteFiles(_ paths: [String], into app: NSRunningApplication) throws {
        let urls = paths.map { NSURL(fileURLWithPath: $0) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls) else {
            throw AutomationError.actionFailed("无法把附件写入系统剪贴板")
        }
        try shortcut(keyCode: KeyCode.v.rawValue, modifiers: .maskCommand, in: app)
        usleep(700_000)
    }

    private func putStringOnPasteboard(_ value: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            throw AutomationError.actionFailed("无法写入系统剪贴板")
        }
    }

    private func press(_ key: KeyCode, in app: NSRunningApplication) throws {
        try shortcut(keyCode: key.rawValue, modifiers: [], in: app)
    }

    private func shortcut(keyCode: CGKeyCode, modifiers: CGEventFlags, in app: NSRunningApplication) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw AutomationError.actionFailed("无法创建键盘事件")
        }
        down.flags = modifiers
        up.flags = modifiers
        down.postToPid(app.processIdentifier)
        usleep(50_000)
        up.postToPid(app.processIdentifier)
        usleep(commandDelay)
    }

    private func restoreSenderApplication() {
        let restore = {
            NSApplication.shared.unhide(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApplication.shared.windows
                .first(where: { $0.canBecomeKey })?
                .makeKeyAndOrderFront(nil)
        }
        if Thread.isMainThread {
            restore()
        } else {
            DispatchQueue.main.sync(execute: restore)
        }
        trace("sender_restored")
    }

    private func trace(_ stage: String) {
        NSLog("[WeChatSend:%@] %@", Self.revision, stage)
    }

}

private enum KeyCode: CGKeyCode {
    case a = 0x00
    case v = 0x09
    case returnKey = 0x24
    case delete = 0x33
}
