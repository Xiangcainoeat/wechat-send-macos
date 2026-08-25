import SwiftUI

@main
struct LeafSendApp: App {
    @StateObject private var store: TaskStore
    @StateObject private var scheduler: TaskScheduler
    @StateObject private var weChatStatus: WeChatStatusMonitor

    init() {
        let store = TaskStore()
        _store = StateObject(wrappedValue: store)
        _scheduler = StateObject(wrappedValue: TaskScheduler(store: store))
        _weChatStatus = StateObject(wrappedValue: WeChatStatusMonitor())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(scheduler)
                .environmentObject(weChatStatus)
                .frame(minWidth: 920, minHeight: 620)
                .task {
                    await AcceptanceRunner.runIfRequested()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra("微信发送", systemImage: "paperplane.fill") {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(scheduler)
                .environmentObject(weChatStatus)
        }
    }
}

@MainActor
private enum AcceptanceRunner {
    private static var hasRun = false

    static func runIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard !hasRun,
              let reportPath = environment["WECHAT_SEND_ACCEPTANCE_REPORT"] else { return }
        hasRun = true

        let contact = environment["WECHAT_SEND_ACCEPTANCE_CONTACT"] ?? "文件传输助手"
        let task = SendTask(
            contact: contact,
            message: "微信发送 v1.0.0 安全验收草稿",
            filePaths: [],
            scheduledAt: Date(),
            repeatRule: .once,
            uniqueContactConfirmed: true
        )
        let accessibilityAllowed = PermissionCenter.hasAccessibility
        let result = await Task.detached(priority: .userInitiated) {
            await WeChatAutomation().execute(
                task: task,
                realSend: false,
                accessibilityAllowed: accessibilityAllowed,
                restoreSenderAfterExecution: true,
                clearDraftAfterPreview: true
            )
        }.value

        try? await Task.sleep(nanoseconds: 400_000_000)
        let report: [String: Any] = [
            "revision": WeChatAutomation.revision,
            "state": result.state.rawValue,
            "detail": result.detail,
            "accessibilityAllowed": accessibilityAllowed,
            "senderIsFrontmost": NSRunningApplication.current.isActive,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
    }
}
