import Combine
import Foundation

@MainActor
final class TaskScheduler: ObservableObject {
    @Published private(set) var isExecuting = false
    @Published private(set) var currentTaskID: UUID?

    private let store: TaskStore
    private let clearDraftAfterPreview: Bool
    private let schedulerInterval: TimeInterval = 0.25
    private var timer: Timer?

    init(
        store: TaskStore,
        autoStart: Bool = true,
        clearDraftAfterPreview: Bool = false
    ) {
        self.store = store
        self.clearDraftAfterPreview = clearDraftAfterPreview
        if autoStart { start() }
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: schedulerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func runNow(_ task: SendTask) {
        guard !isExecuting else { return }
        execute(task, source: .manual)
    }

    private func tick(now: Date = Date()) {
        guard !isExecuting, let task = store.dueTasks(at: now).first else { return }
        let lateness = now.timeIntervalSince(task.scheduledAt)
        if lateness > store.settings.missedTaskGraceSeconds {
            store.setState(
                .needsAttention,
                detail: "计划时间已错过 \(Int(lateness / 60)) 分钟，没有静默补发",
                for: task.id,
                at: now
            )
            return
        }
        execute(task, source: .scheduled)
    }

    private func execute(_ task: SendTask, source: ExecutionSource) {
        isExecuting = true
        currentTaskID = task.id
        if source == .scheduled {
            store.setState(
                .running,
                detail: "v1.0.5：定时任务正在打开微信并搜索联系人",
                for: task.id
            )
        }
        let realSend = store.settings.realSendEnabled
        let accessibilityAllowed = PermissionCenter.hasAccessibility
        let shouldClearDraft = clearDraftAfterPreview

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await WeChatAutomation().execute(
                    task: task,
                    realSend: realSend,
                    source: source,
                    accessibilityAllowed: accessibilityAllowed,
                    restoreSenderAfterExecution: true,
                    clearDraftAfterPreview: shouldClearDraft
                )
            }.value
            guard let self else { return }
            self.store.completeExecution(
                for: task.id,
                state: result.state,
                detail: result.detail,
                advancesSchedule: source == .scheduled
            )
            self.currentTaskID = nil
            self.isExecuting = false
        }
    }
}
