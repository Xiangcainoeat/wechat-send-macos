import Combine
import Foundation

@MainActor
final class TaskScheduler: ObservableObject {
    @Published private(set) var isExecuting = false
    @Published private(set) var currentTaskID: UUID?

    private let store: TaskStore
    private var timer: Timer?

    init(store: TaskStore) {
        self.store = store
        start()
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func runNow(_ task: SendTask) {
        guard !isExecuting else { return }
        execute(task, restoreSenderAfterExecution: true)
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
        execute(task, restoreSenderAfterExecution: false)
    }

    private func execute(_ task: SendTask, restoreSenderAfterExecution: Bool) {
        isExecuting = true
        currentTaskID = task.id
        store.setState(.running, detail: "v1.0.0：正在打开微信并搜索唯一联系人", for: task.id)
        let realSend = store.settings.realSendEnabled
        let accessibilityAllowed = PermissionCenter.hasAccessibility

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await WeChatAutomation().execute(
                    task: task,
                    realSend: realSend,
                    accessibilityAllowed: accessibilityAllowed,
                    restoreSenderAfterExecution: restoreSenderAfterExecution
                )
            }.value
            guard let self else { return }
            self.store.completeExecution(
                for: task.id,
                state: result.state,
                detail: result.detail
            )
            self.currentTaskID = nil
            self.isExecuting = false
        }
    }
}
