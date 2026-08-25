import Foundation
import Testing
@testable import LeafSend

struct ModelTests {
    @Test func oneOffTaskDisablesAfterExecution() {
        let now = Date()
        var task = SendTask(
            contact: "文件传输助手",
            message: "测试",
            filePaths: [],
            scheduledAt: now,
            repeatRule: .once
        )

        task.advanceAfterExecution(from: now)

        #expect(task.isEnabled == false)
    }

    @Test func dailyTaskAdvancesIntoFuture() {
        let now = Date()
        var task = SendTask(
            contact: "文件传输助手",
            message: "测试",
            filePaths: [],
            scheduledAt: now.addingTimeInterval(-3 * 86_400),
            repeatRule: .daily
        )

        task.advanceAfterExecution(from: now)

        #expect(task.isEnabled)
        #expect(task.state == .pending)
        #expect(task.scheduledAt > now)
    }

    @MainActor
    @Test func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("state.json")
        let original = TaskStore(stateURL: url)
        original.add(SendTask(
            contact: "测试联系人",
            message: "你好",
            filePaths: ["/tmp/a.pdf"],
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000),
            repeatRule: .once,
            uniqueContactConfirmed: true
        ))

        let reloaded = TaskStore(stateURL: url)

        #expect(reloaded.tasks.count == 1)
        #expect(reloaded.tasks.first?.contact == "测试联系人")
        #expect(reloaded.tasks.first?.filePaths == ["/tmp/a.pdf"])
        #expect(reloaded.tasks.first?.uniqueContactConfirmed == true)
    }

    @Test func legacyTaskDefaultsUniqueContactConfirmationToFalse() throws {
        let task = SendTask(
            contact: "旧联系人",
            message: "测试",
            filePaths: [],
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000),
            repeatRule: .once,
            uniqueContactConfirmed: true
        )
        let encoded = try JSONEncoder().encode(task)
        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyObject.removeValue(forKey: "uniqueContactConfirmed")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try JSONDecoder().decode(SendTask.self, from: legacyData)

        #expect(decoded.uniqueContactConfirmed == false)
    }

    @MainActor
    @Test func manualExecutionLogsResultWithoutConsumingScheduledTask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TaskStore(stateURL: directory.appendingPathComponent("state.json"))
        let scheduledAt = Date(timeIntervalSince1970: 1_800_000_000)
        let task = SendTask(
            contact: "测试联系人",
            message: "测试",
            filePaths: [],
            scheduledAt: scheduledAt,
            repeatRule: .once,
            uniqueContactConfirmed: true
        )
        store.add(task)

        store.completeExecution(
            for: task.id,
            state: .failed,
            detail: "立即执行失败",
            advancesSchedule: false,
            at: scheduledAt.addingTimeInterval(-4)
        )

        let saved = try #require(store.task(withID: task.id))
        #expect(saved.state == .pending)
        #expect(saved.isEnabled)
        #expect(saved.scheduledAt == scheduledAt)
        #expect(store.logs.first?.result == .failed)
        #expect(store.logs.first?.detail == "立即执行失败")
    }

    @MainActor
    @Test func scheduledExecutionAdvancesOneOffTask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TaskStore(stateURL: directory.appendingPathComponent("state.json"))
        let scheduledAt = Date(timeIntervalSince1970: 1_800_000_000)
        let task = SendTask(
            contact: "测试联系人",
            message: "测试",
            filePaths: [],
            scheduledAt: scheduledAt,
            repeatRule: .once,
            uniqueContactConfirmed: true
        )
        store.add(task)

        store.completeExecution(
            for: task.id,
            state: .submitted,
            detail: "定时执行完成",
            advancesSchedule: true,
            at: scheduledAt
        )

        let saved = try #require(store.task(withID: task.id))
        #expect(saved.state == .submitted)
        #expect(!saved.isEnabled)
        #expect(store.logs.first?.result == .submitted)
    }

    @Test func unconfirmedContactStopsBeforeAutomation() async {
        let task = SendTask(
            contact: "测试联系人",
            message: "测试",
            filePaths: [],
            scheduledAt: Date(),
            repeatRule: .once
        )
        let result = await WeChatAutomation().execute(
            task: task,
            realSend: false,
            accessibilityAllowed: false
        )

        #expect(result.state == .failed)
        #expect(result.detail.contains("联系人名称在微信搜索结果中唯一"))
    }
}
