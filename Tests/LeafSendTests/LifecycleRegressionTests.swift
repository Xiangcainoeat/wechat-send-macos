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

    @Test func scheduledAndManualExecutionUseTheSameWindowRestorationPath() throws {
        let scheduler = try source("Sources/LeafSend/Scheduler.swift")
        let automation = try source("Sources/LeafSend/WeChatAutomation.swift")

        #expect(scheduler.contains("execute(task, source: .manual)"))
        #expect(scheduler.contains("execute(task, source: .scheduled)"))
        #expect(scheduler.contains("restoreSenderAfterExecution: true"))
        #expect(!scheduler.contains("restoreSenderAfterExecution: false"))
        #expect(automation.contains("defer"))
        #expect(automation.contains("restoreSenderApplication()"))
    }

    @Test func contactSelectionRequiresScreenshotAndUniqueOCRResultBeforeEnter() throws {
        let automation = try source("Sources/LeafSend/WeChatAutomation.swift")
        let openSearch = try #require(automation.range(of: "try openSearchMenu(in: app)"))
        let typeContact = try #require(automation.range(of: "try typeSearchContact(contact, in: app)"))
        let capture = try #require(automation.range(of: "ScreenCaptureService.captureSearchPanel"))
        let recognize = try #require(automation.range(of: "VisionOCR.verifyUniqueContact"))
        let unique = try #require(automation.range(of: "guard evidence.resultMatchCount == 1"))
        let submit = try #require(automation.range(of: "trace(\"search_confirm_enter_posted\")"))

        #expect(openSearch.lowerBound < typeContact.lowerBound)
        #expect(typeContact.lowerBound < capture.lowerBound)
        #expect(capture.lowerBound < recognize.lowerBound)
        #expect(recognize.lowerBound < unique.lowerBound)
        #expect(unique.lowerBound < submit.lowerBound)
        #expect(!automation.contains("putStringOnPasteboard(contact)"))
    }

    @Test func buildVersionIsVisibleAndIncludedInExecutionResults() throws {
        let infoURL = projectRoot.appendingPathComponent("Resources/Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        let info = try #require(
            PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        )
        let views = try source("Sources/LeafSend/Views.swift")
        let automation = try source("Sources/LeafSend/WeChatAutomation.swift")

        #expect(info["CFBundleShortVersionString"] as? String == "1.0.2")
        #expect(info["CFBundleVersion"] as? String == "102")
        #expect((info["NSScreenCaptureUsageDescription"] as? String)?.contains("不保存或上传截图") == true)
        #expect(views.contains("v1.0.2"))
        #expect(automation.contains("v1.0.2："))
    }

    @Test func searchScreenshotsRemainInMemoryOnly() throws {
        let capture = try source("Sources/LeafSend/ScreenCaptureService.swift")

        #expect(capture.contains("SCScreenshotManager.captureImage"))
        #expect(!capture.contains("CGImageDestination"))
        #expect(!capture.contains("write(to:"))
        #expect(!capture.contains("DEBUG_CAPTURE"))
    }

    @Test func publicReadmeExplainsTechnologyAndExecutionPipelineWithoutLocalPaths() throws {
        let readme = try source("README.md")

        #expect(readme.hasPrefix("# 微信发送"))
        #expect(readme.contains("## 技术栈"))
        #expect(readme.contains("## 实现原理"))
        #expect(readme.contains("SwiftUI"))
        #expect(readme.contains("CGEvent"))
        #expect(readme.contains("ScreenCaptureKit"))
        #expect(readme.contains("Vision"))
        #expect(readme.contains("Control-Command-K"))
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
        #expect(app.contains("WECHAT_SEND_ACCEPTANCE_BACKGROUND"))
        #expect(app.contains("realSend: false"))
        #expect(app.contains("clearDraftAfterPreview: true"))
        #expect(automation.contains("preview_draft_cleared"))
    }

    @Test func directSearchExecutionEmitsObservableStageMarkers() throws {
        let automation = try source("Sources/LeafSend/WeChatAutomation.swift")
        for stage in [
            "search_opened",
            "contact_typed",
            "capture_overlay_requested",
            "capture_overlay_closed",
            "search_field_ocr_confirmed",
            "unique_result_confirmed",
            "search_confirm_enter_posted",
            "chat_wait_complete",
            "message_pasted",
            "message_send_enter_posted",
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
