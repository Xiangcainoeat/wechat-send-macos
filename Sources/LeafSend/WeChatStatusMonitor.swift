import AppKit
import ApplicationServices
import Combine
import Foundation

enum WeChatPhase: String {
    case notRunning
    case loginRequired
    case loggedIn
    case runningUnknown

    var title: String {
        switch self {
        case .notRunning: return "微信未运行"
        case .loginRequired: return "微信等待登录"
        case .loggedIn: return "微信已登录"
        case .runningUnknown: return "微信运行中"
        }
    }
}

struct WeChatSnapshot {
    var phase: WeChatPhase = .notRunning
    var detail = "尚未检查"
    var checkedAt = Date()
}

@MainActor
final class WeChatStatusMonitor: ObservableObject {
    @Published private(set) var snapshot = WeChatSnapshot()
    @Published private(set) var isRefreshing = false

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        snapshot.detail = "正在检查微信状态..."
        snapshot.checkedAt = Date()
        snapshot = Self.inspect()
        isRefreshing = false
    }

    static func inspect() -> WeChatSnapshot {
        let now = Date()
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.tencent.xinWeChat"
        }) else {
            return WeChatSnapshot(phase: .notRunning, detail: "请先打开并登录微信", checkedAt: now)
        }

        if AXIsProcessTrusted(), searchMenuIsAvailable(for: app.processIdentifier) {
            return WeChatSnapshot(
                phase: .loggedIn,
                detail: "微信搜索功能已就绪",
                checkedAt: now
            )
        }

        return WeChatSnapshot(
            phase: .runningUnknown,
            detail: AXIsProcessTrusted()
                ? "微信正在运行；执行任务时会再次确认搜索功能"
                : "微信正在运行；授权辅助功能后可进一步检查",
            checkedAt: now
        )
    }

    private static func searchMenuIsAvailable(for processIdentifier: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let menuBar = element(application, attribute: kAXMenuBarAttribute),
              let editMenu = findElement(
                in: menuBar,
                titles: ["编辑", "Edit"],
                roles: [kAXMenuBarItemRole as String]
              ),
              let searchItem = findElement(
                in: editMenu,
                titles: ["搜索", "Search"],
                roles: [kAXMenuItemRole as String]
              ) else { return false }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            searchItem,
            kAXEnabledAttribute as CFString,
            &value
        ) == .success else { return true }
        return (value as? Bool) ?? true
    }

    private static func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as! AXUIElement?
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func findElement(
        in root: AXUIElement,
        titles: [String],
        roles: [String],
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth < 8 else { return nil }
        let title = string(root, attribute: kAXTitleAttribute) ?? ""
        let role = string(root, attribute: kAXRoleAttribute) ?? ""
        if titles.contains(title), roles.contains(role) { return root }
        for child in children(root) {
            if let match = findElement(in: child, titles: titles, roles: roles, depth: depth + 1) {
                return match
            }
        }
        return nil
    }
}
