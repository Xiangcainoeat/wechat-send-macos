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

@MainActor
final class WeChatAutomation {
    static let revision = "window-focus-v7"

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
                try await ensureWeChatFrontmost(app)
                try pasteText(task.message, into: app)
                trace("message_pasted")
                if realSend {
                    try await ensureWeChatFrontmost(app)
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
                try await ensureWeChatFrontmost(app)
                try pasteFiles(task.filePaths, into: app)
                trace("files_pasted")
                if realSend {
                    usleep(800_000)
                    try await ensureWeChatFrontmost(app)
                    try press(.returnKey, in: app)
                    trace("file_send_enter_posted")
                    usleep(1_000_000)
                }
            }

            if !realSend {
                if clearDraftAfterPreview && !task.message.isEmpty && task.filePaths.isEmpty {
                    try await ensureWeChatFrontmost(app)
                    try shortcut(keyCode: KeyCode.a.rawValue, modifiers: .maskCommand, in: app)
                    try press(.delete, in: app)
                    trace("preview_draft_cleared")
                }
                return AutomationResult(
                    state: .draftReady,
                    detail: "v1.0.4：\(source.title)已按确认过的联系人名称打开首项；内容已填入，未按发送键"
                )
            }
            return AutomationResult(
                state: .submitted,
                detail: "v1.0.4：\(source.title)已按确认过的联系人名称打开首项；已向微信投递发送按键"
            )
        } catch {
            return AutomationResult(
                state: .failed,
                detail: "v1.0.4：\(source.title)失败：\(error.localizedDescription)"
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
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.tencent.xinWeChat"
        ) else {
            throw AutomationError.weChatNotRunning
        }

        // Launch Services performs the real app switch. NSRunningApplication.activate()
        // can report success while the previous app still owns the menu bar.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
        guard app.bundleIdentifier == "com.tencent.xinWeChat" else {
            throw AutomationError.weChatNotRunning
        }
        try await activateWeChatFrontmost(app)
        return app
    }

    private func activateWeChatFrontmost(_ app: NSRunningApplication) async throws {
        for attempt in 0..<30 {
            if isWeChatFrontmost(app) { return }
            requestWeChatActivation(app)
            raiseMainWindow(of: app)
            if isWeChatFrontmost(app) { return }
            if attempt < 29 {
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        throw AutomationError.actionFailed("无法将微信激活到前台，已停止；不会输入或发送内容")
    }

    private func ensureWeChatFrontmost(_ app: NSRunningApplication) async throws {
        for attempt in 0..<20 {
            if isWeChatFrontmost(app) { return }
            requestWeChatActivation(app)
            raiseMainWindow(of: app)
            if isWeChatFrontmost(app) { return }
            if attempt < 19 {
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        throw AutomationError.actionFailed("无法将微信保持在前台，已停止；不会输入或发送内容")
    }

    private func isWeChatFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier && app.isActive
    }

    private func requestWeChatActivation(_ app: NSRunningApplication) {
        app.unhide()
        _ = app.activate(options: [.activateAllWindows])
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
    }

    private func raiseMainWindow(of app: NSRunningApplication) {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = axElements(application, attribute: kAXWindowsAttribute),
              let window = windows.first(where: { axString($0, attribute: kAXTitleAttribute) == "微信" }) ?? windows.first else {
            return
        }
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private func openFirstSearchResult(contact: String, app: NSRunningApplication) async throws {
        let previousMouseLocation = CGEvent(source: nil)?.location
        defer {
            if let previousMouseLocation {
                restoreMouse(to: previousMouseLocation)
            }
        }

        try await ensureWeChatFrontmost(app)
        try await openSearchMenu(in: app)
        trace("search_opened")
        try await Task.sleep(nanoseconds: searchFocusDelay)

        try await ensureWeChatFrontmost(app)
        let searchPanel = try await waitForSearchPanel(for: app)
        try clickSearchField(in: searchPanel)
        trace("search_field_clicked")
        try await Task.sleep(nanoseconds: 150_000_000)
        try await typeSearchContact(contact, in: app)
        trace("contact_typed")
        try await Task.sleep(nanoseconds: searchResultsDelay)

        try await ensureWeChatFrontmost(app)
        trace("search_results_wait_complete")
        trace("contact_uniqueness_acknowledged")

        try await ensureWeChatFrontmost(app)
        try press(.returnKey, in: app)
        trace("search_confirm_enter_posted")
        try await waitForSearchPanelToClose(for: app)
        try await Task.sleep(nanoseconds: chatOpenDelay)
        try await ensureWeChatFrontmost(app)
        trace("chat_wait_complete")
    }

    private func waitForSearchPanel(for app: NSRunningApplication) async throws -> CGRect {
        for _ in 0..<20 {
            if let bounds = searchPanelBounds(for: app.processIdentifier) {
                trace("search_panel_found")
                return bounds
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AutomationError.actionFailed(
            "微信搜索面板没有出现，已停止；不会输入联系人或发送消息"
        )
    }

    private func waitForSearchPanelToClose(for app: NSRunningApplication) async throws {
        for _ in 0..<20 {
            if searchPanelBounds(for: app.processIdentifier) == nil {
                trace("search_panel_closed")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AutomationError.actionFailed(
            "微信搜索面板没有关闭，未确认已进入联系人聊天；不会粘贴或发送消息"
        )
    }

    private func searchPanelBounds(for processIdentifier: pid_t) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 3,
                  let rawBounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  rect.width >= 300,
                  rect.height >= 250,
                  rect.height <= 700 else {
                continue
            }
            return rect
        }
        return nil
    }

    private func clickSearchField(in panel: CGRect) throws {
        let point = CGPoint(
            x: panel.midX,
            y: panel.minY + min(28, panel.height * 0.12)
        )
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
              ),
              let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else {
            throw AutomationError.actionFailed("无法点击微信搜索框，已停止；不会输入或发送消息")
        }
        down.post(tap: .cghidEventTap)
        usleep(50_000)
        up.post(tap: .cghidEventTap)
    }

    private func restoreMouse(to point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func openSearchMenu(in app: NSRunningApplication) async throws {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        for attempt in 0..<80 {
            if let menuBar = axElement(application, attribute: kAXMenuBarAttribute),
               let editMenu = findAXElement(in: menuBar, titles: ["编辑", "Edit"], roles: [kAXMenuBarItemRole as String]),
               let searchItem = findAXElement(in: editMenu, titles: ["搜索", "Search"], roles: [kAXMenuItemRole as String]) {
                let result = AXUIElementPerformAction(searchItem, kAXPressAction as CFString)
                if result == .success {
                    trace("search_menu_ready")
                    return
                }
            }

            if attempt % 5 == 4 {
                try? await ensureWeChatFrontmost(app)
            }
            if attempt % 10 == 9 {
                try? await activateWeChatFrontmost(app)
            }
            try await Task.sleep(nanoseconds: 125_000_000)
        }
        throw AutomationError.actionFailed("找不到微信菜单“编辑 → 搜索”，已停止")
    }

    private func typeSearchContact(_ contact: String, in app: NSRunningApplication) async throws {
        try await ensureWeChatFrontmost(app)
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

    private func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
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
