import Foundation
import Testing
@testable import LeafSend

struct LifecycleRegressionTests {
    @Test func installerUnloadsKeepAliveBeforeStoppingAndReplacingApplication() throws {
        let script = try source("scripts/install-app.sh")
        let unload = try #require(script.range(of: "launchctl bootout"))
        let stop = try #require(script.range(of: "pkill -f '/微信发送.app/Contents/MacOS/LeafSend$'"))
        let replace = try #require(script.range(of: "ditto \"$SOURCE_APP\" \"$INSTALLED_APP\""))

        #expect(unload.lowerBound < stop.lowerBound)
        #expect(stop.lowerBound < replace.lowerBound)
    }

    @Test func manualExecutionRequestsSenderWindowRestoration() throws {
        let scheduler = try source("Sources/LeafSend/Scheduler.swift")
        let automation = try source("Sources/LeafSend/WeChatAutomation.swift")

        #expect(scheduler.contains("execute(task, restoreSenderAfterExecution: true)"))
        #expect(automation.contains("defer"))
        #expect(automation.contains("restoreSenderApplication()"))
    }

    @Test func contactSelectionUsesPasteAndEnterWithoutImageRecognition() throws {
        let automation = try source("Sources/LeafSend/WeChatAutomation.swift")
        let openSearch = try #require(automation.range(of: "try openSearchMenu(in: app)"))
        let pasteContact = try #require(automation.range(of: "try putStringOnPasteboard(contact)"))
        let enterResult = try #require(automation.range(of: "try press(.returnKey, in: app)", range: pasteContact.upperBound..<automation.endIndex))

        #expect(openSearch.lowerBound < pasteContact.lowerBound)
        #expect(pasteContact.lowerBound < enterResult.lowerBound)
        #expect(!automation.contains("VisionOCR"))
        #expect(!automation.contains("ScreenCaptureService"))
    }

    @Test func buildVersionIsVisibleAndIncludedInExecutionResults() throws {
        let infoURL = projectRoot.appendingPathComponent("Resources/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        let info = try #require(
            PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        )
        let views = try source("Sources/LeafSend/Views.swift")
        let automation = try source("Sources/LeafSend/WeChatAutomation.swift")

        #expect(info["CFBundleShortVersionString"] as? String == "1.0.0")
        #expect(info["CFBundleVersion"] as? String == "100")
        #expect(views.contains("v1.0.0"))
        #expect(automation.contains("v1.0.0："))
    }

    @Test func publicReadmeExplainsTechnologyAndExecutionPipelineWithoutLocalPaths() throws {
        let readme = try source("README.md")

        #expect(readme.hasPrefix("# 微信发送"))
        #expect(readme.contains("## 技术栈"))
        #expect(readme.contains("## 实现原理"))
        #expect(readme.contains("SwiftUI"))
        #expect(readme.contains("CGEvent"))
        #expect(readme.contains("LaunchAgent"))
        #expect(readme.contains("编辑 → 搜索"))
        #expect(readme.contains("联系人必须唯一"))
        #expect(readme.contains("不读取或解密微信数据库"))
        #expect(!readme.contains("/Users/"))
    }

    @Test func acceptanceModeIsExplicitlyGatedAndCleansItsPreviewDraft() throws {
        let app = try source("Sources/LeafSend/LeafSendApp.swift")
        let automation = try source("Sources/LeafSend/WeChatAutomation.swift")

        #expect(app.contains("WECHAT_SEND_ACCEPTANCE_REPORT"))
        #expect(app.contains("realSend: false"))
        #expect(app.contains("clearDraftAfterPreview: true"))
        #expect(automation.contains("preview_draft_cleared"))
    }

    @Test func directSearchExecutionEmitsObservableStageMarkers() throws {
        let automation = try source("Sources/LeafSend/WeChatAutomation.swift")
        for stage in [
            "search_opened",
            "contact_pasted",
            "first_result_entered",
            "chat_wait_complete",
            "message_pasted",
            "sender_restored"
        ] {
            #expect(automation.contains("trace(\"\(stage)\")"))
        }
    }

    private func source(_ relativePath: String) throws -> String {
        return try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
