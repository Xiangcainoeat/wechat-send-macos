import Combine
import Foundation

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [SendTask] = []
    @Published private(set) var logs: [ExecutionLog] = []
    @Published var settings = AppSettings() {
        didSet { save() }
    }

    private let stateURL: URL
    private var isLoading = false

    init(stateURL: URL? = nil) {
        self.stateURL = stateURL ?? Self.defaultStateURL()
        load()
    }

    func add(_ task: SendTask) {
        tasks.append(task)
        sortTasks()
        save()
    }

    func update(_ task: SendTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var copy = task
        copy.updatedAt = Date()
        tasks[index] = copy
        sortTasks()
        save()
    }

    func delete(_ task: SendTask) {
        tasks.removeAll { $0.id == task.id }
        save()
    }

    func task(withID id: UUID) -> SendTask? {
        tasks.first { $0.id == id }
    }

    func dueTasks(at date: Date) -> [SendTask] {
        tasks.filter { $0.isEnabled && $0.state == .pending && $0.scheduledAt <= date }
    }

    func setState(_ state: TaskState, detail: String, for id: UUID, at date: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = state
        tasks[index].lastDetail = detail
        tasks[index].updatedAt = date
        save()
    }

    func completeExecution(for id: UUID, state: TaskState, detail: String, at date: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = state
        tasks[index].lastDetail = detail
        tasks[index].updatedAt = date
        logs.insert(ExecutionLog(
            taskID: id,
            timestamp: date,
            contact: tasks[index].contact,
            result: state,
            detail: detail
        ), at: 0)
        if logs.count > 200 { logs = Array(logs.prefix(200)) }
        if state == .submitted || state == .draftReady {
            tasks[index].advanceAfterExecution(from: date)
        }
        sortTasks()
        save()
    }

    func retry(_ task: SendTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].state = .pending
        tasks[index].isEnabled = true
        tasks[index].scheduledAt = max(Date().addingTimeInterval(5), task.scheduledAt)
        tasks[index].lastDetail = "已重新加入队列"
        save()
    }

    func replaceSettings(_ newSettings: AppSettings) {
        settings = newSettings
    }

    private func sortTasks() {
        tasks.sort { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
            return lhs.scheduledAt < rhs.scheduledAt
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: stateURL),
              let persisted = try? JSONDecoder.leafSend.decode(PersistedState.self, from: data) else {
            return
        }
        tasks = persisted.tasks
        logs = persisted.logs
        settings = persisted.settings
        sortTasks()
    }

    private func save() {
        guard !isLoading else { return }
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let state = PersistedState(tasks: tasks, logs: logs, settings: settings)
            let data = try JSONEncoder.leafSend.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("WeChatSend state save failed: %@", error.localizedDescription)
        }
    }

    static func defaultStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WeChatSend", isDirectory: true)
            .appendingPathComponent("state.json")
    }
}

extension JSONEncoder {
    static let leafSend: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let leafSend: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
