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
    static let revision = "direct-search-v5"

    private let commandDelay: useconds_t = 250_000
    private let searchFocusDelay: UInt64 = 600_000_000
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
        let previouslyFrontmostApplication = NSWorkspace.shared.frontmostApplication
        defer {
            if restoreSenderAfterExecution {
                restore(previouslyFrontmostApplication)
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
                    detail: "v1.0.3：\(source.title)已按确认过的联系人名称打开首项；内容已填入，未按发送键"
                )
            }
            return AutomationResult(
                state: .submitted,
                detail: "v1.0.3：\(source.title)已按确认过的联系人名称打开首项；已向微信投递发送按键"
            )
        } catch {
            return AutomationResult(
                state: .failed,
                detail: "v1.0.3：\(source.title)失败：\(error.localizedDescription)"
            )
        }
    }

    private func validate(_ task: SendTask) throws {
        guard !task.contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.invalidTask("联系人不能为空")
        }
        guard task.uniqueContactConfirmed else {
            throw AutomationError.invalidTask(
                "请先编辑任务并确认该联系人名称在微信搜索结果中唯一"
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
        try typeSearchContact(contact, in: app)
        trace("contact_typed")
        try await Task.sleep(nanoseconds: searchResultsDelay)

        try ensureWeChatFrontmost(app)
        trace("search_results_wait_complete")
        trace("contact_uniqueness_acknowledged")

        try ensureWeChatFrontmost(app)
        try press(.returnKey, in: app)
        trace("search_confirm_enter_posted")
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

    private func typeSearchContact(_ contact: String, in app: NSRunningApplication) throws {
        try ensureWeChatFrontmost(app)
        try globalShortcut(keyCode: KeyCode.a.rawValue, modifiers: .maskCommand)
        try globalShortcut(keyCode: KeyCode.delete.rawValue, modifiers: [])

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw AutomationError.actionFailed("无法创建联系人输入事件，已停止")
        }
        for character in contact {
            let codeUnits = Array(String(character).utf16)
            guard !codeUnits.isEmpty,
                  let down = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: KeyCode.a.rawValue,
                    keyDown: true
                  ),
                  let up = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: KeyCode.a.rawValue,
                    keyDown: false
                  ) else {
                throw AutomationError.actionFailed("无法创建联系人输入事件，已停止")
            }
            codeUnits.withUnsafeBufferPointer { buffer in
                guard let address = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: address
                )
                up.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: address
                )
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                throw AutomationError.actionFailed("输入联系人时微信失去前台焦点，已停止")
            }
            down.post(tap: .cghidEventTap)
            usleep(35_000)
            up.post(tap: .cghidEventTap)
        }
        usleep(commandDelay)
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

    private func globalShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw AutomationError.actionFailed("无法创建键盘事件")
        }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        usleep(50_000)
        up.post(tap: .cghidEventTap)
        usleep(commandDelay)
    }

    private func restore(_ application: NSRunningApplication?) {
        let restore = {
            guard let application, !application.isTerminated else { return }
            application.unhide()
            application.activate(options: [.activateAllWindows])
            if application.processIdentifier == NSRunningApplication.current.processIdentifier {
                NSApplication.shared.windows
                    .first(where: { $0.canBecomeKey })?
                    .makeKeyAndOrderFront(nil)
            }
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
