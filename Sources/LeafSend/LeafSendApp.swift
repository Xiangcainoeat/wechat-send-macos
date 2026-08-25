import SwiftUI

@main
struct LeafSendApp: App {
    @StateObject private var store: TaskStore
    @StateObject private var scheduler: TaskScheduler
    @StateObject private var weChatStatus: WeChatStatusMonitor

    init() {
        let store = TaskStore()
        let isAcceptanceRun = ProcessInfo.processInfo.environment["WECHAT_SEND_ACCEPTANCE_REPORT"] != nil
        _store = StateObject(wrappedValue: store)
        _scheduler = StateObject(wrappedValue: TaskScheduler(store: store, autoStart: !isAcceptanceRun))
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
        let startsInBackground = environment["WECHAT_SEND_ACCEPTANCE_BACKGROUND"] == "1"
        if startsInBackground {
            NSApplication.shared.hide(nil)
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        let task = SendTask(
            contact: contact,
            message: "微信发送 v1.0.3 安全验收草稿",
            filePaths: [],
            scheduledAt: Date(),
            repeatRule: .once,
            uniqueContactConfirmed: true
        )
        let accessibilityAllowed = PermissionCenter.hasAccessibility
        let scheduledDelay = environment["WECHAT_SEND_ACCEPTANCE_SCHEDULE_DELAY"]
            .flatMap(Double.init)
            .map { min(max($0, 1), 10) }
        let result: AutomationResult
        let mode: String

        if let scheduledDelay {
            mode = "scheduled"
            result = await runScheduled(
                task: task,
                delay: scheduledDelay,
                accessibilityAllowed: accessibilityAllowed
            )
        } else {
            mode = "direct"
            result = await Task.detached(priority: .userInitiated) {
                await WeChatAutomation().execute(
                    task: task,
                    realSend: false,
                    source: .acceptance,
                    accessibilityAllowed: accessibilityAllowed,
                    restoreSenderAfterExecution: true,
                    clearDraftAfterPreview: true
                )
            }.value
        }

        try? await Task.sleep(nanoseconds: 400_000_000)
        let report: [String: Any] = [
            "revision": WeChatAutomation.revision,
            "state": result.state.rawValue,
            "detail": result.detail,
            "mode": mode,
            "accessibilityAllowed": accessibilityAllowed,
            "startedInBackground": startsInBackground,
            "senderIsFrontmost": NSRunningApplication.current.isActive,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
    }

    private static func runScheduled(
        task: SendTask,
        delay: TimeInterval,
        accessibilityAllowed: Bool
    ) async -> AutomationResult {
        guard accessibilityAllowed else {
            return AutomationResult(state: .failed, detail: "安全验收缺少辅助功能权限")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeChatSend-ScheduledAcceptance-\(UUID().uuidString)", isDirectory: true)
        let store = TaskStore(stateURL: directory.appendingPathComponent("state.json"))
        var settings = store.settings
        settings.realSendEnabled = false
        settings.missedTaskGraceSeconds = 120
        store.replaceSettings(settings)

        var scheduledTask = task
        scheduledTask.scheduledAt = Date().addingTimeInterval(delay)
        store.add(scheduledTask)
        let scheduler = TaskScheduler(
            store: store,
            clearDraftAfterPreview: true
        )
        let deadline = Date().addingTimeInterval(delay + 15)

        while Date() < deadline {
            if let log = store.logs.first(where: { $0.taskID == scheduledTask.id }) {
                withExtendedLifetime(scheduler) {}
                try? FileManager.default.removeItem(at: directory)
                return AutomationResult(state: log.result, detail: log.detail)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        withExtendedLifetime(scheduler) {}
        try? FileManager.default.removeItem(at: directory)
        return AutomationResult(
            state: .failed,
            detail: "定时安全验收超时：调度器未在 \(Int(delay + 15)) 秒内写入执行记录"
        )
    }
}
