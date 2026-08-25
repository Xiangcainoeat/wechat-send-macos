import AppKit
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
    var accountIdentifier: String?
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
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await Self.inspect()
            }.value
            await MainActor.run {
                self?.snapshot = result
                self?.isRefreshing = false
            }
        }
    }

    nonisolated static func inspect() async -> WeChatSnapshot {
        let now = Date()
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.tencent.xinWeChat" ||
            $0.localizedName == "WeChat" || $0.localizedName == "微信"
        }
        guard running else {
            return WeChatSnapshot(phase: .notRunning, detail: "请先打开并登录微信", checkedAt: now)
        }

        let accountID = discoverAccountIdentifier()
        if accountID != nil {
            return WeChatSnapshot(
                phase: .loggedIn,
                accountIdentifier: accountID,
                detail: "微信正在运行，已找到本机账号标识",
                checkedAt: now
            )
        }

        return WeChatSnapshot(
            phase: .runningUnknown,
            detail: "微信正在运行；未找到本机账号标识，请确认已登录",
            checkedAt: now
        )
    }

    nonisolated static func discoverAccountIdentifier(baseURL: URL? = nil) -> String? {
        let loginURL = baseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/all_users/login")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: loginURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return entries
            .filter { $0.lastPathComponent.hasPrefix("wxid_") }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .first?
            .lastPathComponent
    }

}
