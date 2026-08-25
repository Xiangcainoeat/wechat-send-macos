import Foundation

enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case once
    case daily
    case weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: return "仅一次"
        case .daily: return "每天"
        case .weekly: return "每周"
        }
    }
}

enum TaskState: String, Codable {
    case pending
    case running
    case draftReady
    case submitted
    case needsAttention
    case failed
    case cancelled

    var title: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "正在执行"
        case .draftReady: return "草稿已填入"
        case .submitted: return "已提交发送"
        case .needsAttention: return "需要确认"
        case .failed: return "执行失败"
        case .cancelled: return "已取消"
        }
    }
}

struct SendTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var contact: String
    var message: String
    var filePaths: [String]
    var scheduledAt: Date
    var repeatRule: RepeatRule
    var uniqueContactConfirmed = false
    var isEnabled = true
    var state: TaskState = .pending
    var lastDetail: String = ""
    var createdAt = Date()
    var updatedAt = Date()

    enum CodingKeys: String, CodingKey {
        case id, contact, message, filePaths, scheduledAt, repeatRule
        case uniqueContactConfirmed, isEnabled, state, lastDetail, createdAt, updatedAt
    }

    init(
        id: UUID = UUID(),
        contact: String,
        message: String,
        filePaths: [String],
        scheduledAt: Date,
        repeatRule: RepeatRule,
        uniqueContactConfirmed: Bool = false,
        isEnabled: Bool = true,
        state: TaskState = .pending,
        lastDetail: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.contact = contact
        self.message = message
        self.filePaths = filePaths
        self.scheduledAt = scheduledAt
        self.repeatRule = repeatRule
        self.uniqueContactConfirmed = uniqueContactConfirmed
        self.isEnabled = isEnabled
        self.state = state
        self.lastDetail = lastDetail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        contact = try values.decode(String.self, forKey: .contact)
        message = try values.decode(String.self, forKey: .message)
        filePaths = try values.decodeIfPresent([String].self, forKey: .filePaths) ?? []
        scheduledAt = try values.decode(Date.self, forKey: .scheduledAt)
        repeatRule = try values.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) ?? .once
        uniqueContactConfirmed = try values.decodeIfPresent(Bool.self, forKey: .uniqueContactConfirmed) ?? false
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        state = try values.decodeIfPresent(TaskState.self, forKey: .state) ?? .pending
        lastDetail = try values.decodeIfPresent(String.self, forKey: .lastDetail) ?? ""
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    var nextExecutionDescription: String {
        Self.dateFormatter.string(from: scheduledAt)
    }

    mutating func advanceAfterExecution(from date: Date = Date()) {
        let calendar = Calendar.current
        switch repeatRule {
        case .once:
            isEnabled = false
        case .daily:
            repeat {
                scheduledAt = calendar.date(byAdding: .day, value: 1, to: scheduledAt) ?? scheduledAt
            } while scheduledAt <= date
            state = .pending
        case .weekly:
            repeat {
                scheduledAt = calendar.date(byAdding: .day, value: 7, to: scheduledAt) ?? scheduledAt
            } while scheduledAt <= date
            state = .pending
        }
        updatedAt = date
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

struct AppSettings: Codable, Equatable {
    var realSendEnabled = false
    var launchAtLogin = false
    var missedTaskGraceSeconds: TimeInterval = 120
    var accountLabel = ""

    enum CodingKeys: String, CodingKey {
        case realSendEnabled, launchAtLogin, missedTaskGraceSeconds, accountLabel
    }

    init(
        realSendEnabled: Bool = false,
        launchAtLogin: Bool = false,
        missedTaskGraceSeconds: TimeInterval = 120,
        accountLabel: String = ""
    ) {
        self.realSendEnabled = realSendEnabled
        self.launchAtLogin = launchAtLogin
        self.missedTaskGraceSeconds = missedTaskGraceSeconds
        self.accountLabel = accountLabel
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        realSendEnabled = try values.decodeIfPresent(Bool.self, forKey: .realSendEnabled) ?? false
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        missedTaskGraceSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .missedTaskGraceSeconds) ?? 120
        accountLabel = try values.decodeIfPresent(String.self, forKey: .accountLabel) ?? ""
    }
}

struct ExecutionLog: Identifiable, Codable, Equatable {
    var id = UUID()
    var taskID: UUID
    var timestamp = Date()
    var contact: String
    var result: TaskState
    var detail: String
}

struct PersistedState: Codable {
    var tasks: [SendTask] = []
    var logs: [ExecutionLog] = []
    var settings = AppSettings()
}
