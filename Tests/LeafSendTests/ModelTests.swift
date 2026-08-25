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

    @Test func newestAccountDirectoryIsSelected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = root.appendingPathComponent("wxid_old")
        let current = root.appendingPathComponent("wxid_current")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: current.path)

        #expect(WeChatStatusMonitor.discoverAccountIdentifier(baseURL: root) == "wxid_current")
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
        #expect(result.detail.contains("联系人名称在微信中唯一"))
    }
}
