import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct SearchPanelCapture {
    let image: CGImage
    let pointSize: CGSize
}

enum ScreenCaptureServiceError: LocalizedError {
    case permissionMissing
    case mainWindowMissing
    case displayMissing
    case overlayDidNotOpen
    case overlayDidNotClose
    case captureFailed(String)
    case invalidSearchPanel

    var errorDescription: String? {
        switch self {
        case .permissionMissing:
            return "缺少屏幕录制权限，请在设置页授权后重新打开应用"
        case .mainWindowMissing:
            return "找不到微信主窗口，已停止；请确认微信窗口已打开"
        case .displayMissing:
            return "无法确定微信所在显示器，已停止"
        case .overlayDidNotOpen:
            return "微信截图工具没有响应 Control-Command-K，已停止；请检查微信截图快捷键"
        case .overlayDidNotClose:
            return "微信截图工具未能安全退出，已停止；不会选择联系人或发送消息"
        case .captureFailed(let detail):
            return "无法读取微信搜索结果截图，已停止：\(detail)"
        case .invalidSearchPanel:
            return "无法从微信窗口定位搜索结果区域，已停止"
        }
    }
}

enum ScreenCaptureService {
    private static let screenshotKeyCode: CGKeyCode = 0x28
    private static let overlayOpenDelay: UInt64 = 100_000_000
    private static let overlayPollCount = 15

    static func captureSearchPanel(for app: NSRunningApplication) async throws -> SearchPanelCapture {
        guard PermissionCenter.hasScreenCapture else {
            throw ScreenCaptureServiceError.permissionMissing
        }
        guard let windowBounds = mainWindowBounds(processIdentifier: app.processIdentifier) else {
            throw ScreenCaptureServiceError.mainWindowMissing
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw ScreenCaptureServiceError.captureFailed(error.localizedDescription)
        }
        guard let display = display(containing: windowBounds, in: content.displays) else {
            throw ScreenCaptureServiceError.displayMissing
        }
        guard let panelBounds = searchPanelBounds(window: windowBounds, display: display.frame) else {
            throw ScreenCaptureServiceError.invalidSearchPanel
        }

        let originalCursor = CGEvent(source: nil)?.location ?? display.frame.center
        let parkedCursor = CGPoint(x: display.frame.maxX - 12, y: display.frame.maxY - 12)
        CGWarpMouseCursorPosition(parkedCursor)

        do {
            try postGlobalShortcut(
                keyCode: screenshotKeyCode,
                modifiers: [.maskControl, .maskCommand]
            )
            guard await waitForCaptureOverlay(
                processIdentifier: app.processIdentifier,
                displayFrame: display.frame,
                visible: true
            ) else {
                CGWarpMouseCursorPosition(originalCursor)
                throw ScreenCaptureServiceError.overlayDidNotOpen
            }

            let result: Result<SearchPanelCapture, Error>
            do {
                let displayImage = try await capture(display: display)
                let panelCapture = try crop(
                    displayImage: displayImage,
                    panelBounds: panelBounds,
                    displayBounds: display.frame
                )
                result = .success(panelCapture)
            } catch {
                result = .failure(error)
            }

            let overlayClosed = await cancelCaptureOverlay(
                processIdentifier: app.processIdentifier,
                displayFrame: display.frame,
                cursor: parkedCursor
            )
            CGWarpMouseCursorPosition(originalCursor)
            guard overlayClosed else {
                throw ScreenCaptureServiceError.overlayDidNotClose
            }
            return try result.get()
        } catch {
            if captureOverlayIsVisible(
                processIdentifier: app.processIdentifier,
                displayFrame: display.frame
            ) {
                _ = await cancelCaptureOverlay(
                    processIdentifier: app.processIdentifier,
                    displayFrame: display.frame,
                    cursor: parkedCursor
                )
            }
            CGWarpMouseCursorPosition(originalCursor)
            throw error
        }
    }

    private static func capture(display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGDisplayPixelsWide(display.displayID))
        configuration.height = Int(CGDisplayPixelsHigh(display.displayID))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: ScreenCaptureServiceError.captureFailed(
                        error?.localizedDescription ?? "ScreenCaptureKit 没有返回图像"
                    ))
                }
            }
        }
    }

    private static func crop(
        displayImage: CGImage,
        panelBounds: CGRect,
        displayBounds: CGRect
    ) throws -> SearchPanelCapture {
        let scaleX = CGFloat(displayImage.width) / displayBounds.width
        let scaleY = CGFloat(displayImage.height) / displayBounds.height
        var imageRect = CGRect(
            x: (panelBounds.minX - displayBounds.minX) * scaleX,
            y: (panelBounds.minY - displayBounds.minY) * scaleY,
            width: panelBounds.width * scaleX,
            height: panelBounds.height * scaleY
        ).integral
        imageRect = imageRect.intersection(CGRect(
            x: 0,
            y: 0,
            width: displayImage.width,
            height: displayImage.height
        ))
        guard imageRect.width > 0,
              imageRect.height > 0,
              let panelImage = displayImage.cropping(to: imageRect) else {
            throw ScreenCaptureServiceError.invalidSearchPanel
        }
        return SearchPanelCapture(image: panelImage, pointSize: panelBounds.size)
    }

    private static func searchPanelBounds(window: CGRect, display: CGRect) -> CGRect? {
        let leftInset: CGFloat = 60
        guard window.width > leftInset + 180 else { return nil }
        let proposed = CGRect(
            x: window.minX + leftInset,
            y: window.minY,
            width: min(440, window.width - leftInset),
            height: min(680, window.height)
        )
        let intersection = proposed.intersection(display)
        return intersection.width >= 240 && intersection.height >= 300 ? intersection : nil
    }

    private static func display(containing window: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        if let direct = displays.first(where: { $0.frame.contains(window.center) }) {
            return direct
        }
        return displays.max {
            $0.frame.intersection(window).area < $1.frame.intersection(window).area
        }
    }

    private static func mainWindowBounds(processIdentifier: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionAll],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        return windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }.max { $0.area < $1.area }
    }

    private static func postGlobalShortcut(
        keyCode: CGKeyCode,
        modifiers: CGEventFlags
    ) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw ScreenCaptureServiceError.captureFailed("无法创建截图快捷键事件")
        }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        usleep(50_000)
        up.post(tap: .cghidEventTap)
    }

    private static func waitForCaptureOverlay(
        processIdentifier: pid_t,
        displayFrame: CGRect,
        visible: Bool
    ) async -> Bool {
        for _ in 0..<overlayPollCount {
            if captureOverlayIsVisible(
                processIdentifier: processIdentifier,
                displayFrame: displayFrame
            ) == visible {
                return true
            }
            try? await Task.sleep(nanoseconds: overlayOpenDelay)
        }
        return false
    }

    private static func cancelCaptureOverlay(
        processIdentifier: pid_t,
        displayFrame: CGRect,
        cursor: CGPoint
    ) async -> Bool {
        for _ in 0..<2 where captureOverlayIsVisible(
            processIdentifier: processIdentifier,
            displayFrame: displayFrame
        ) {
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let down = CGEvent(
                    mouseEventSource: source,
                    mouseType: .rightMouseDown,
                    mouseCursorPosition: cursor,
                    mouseButton: .right
                  ),
                  let up = CGEvent(
                    mouseEventSource: source,
                    mouseType: .rightMouseUp,
                    mouseCursorPosition: cursor,
                    mouseButton: .right
                  ) else { return false }
            down.post(tap: .cghidEventTap)
            usleep(120_000)
            up.post(tap: .cghidEventTap)
            if await waitForCaptureOverlay(
                processIdentifier: processIdentifier,
                displayFrame: displayFrame,
                visible: false
            ) {
                return true
            }
        }
        return !captureOverlayIsVisible(
            processIdentifier: processIdentifier,
            displayFrame: displayFrame
        )
    }

    private static func captureOverlayIsVisible(
        processIdentifier: pid_t,
        displayFrame: CGRect
    ) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionAll],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 >= 20,
                  (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return false }
            return width >= displayFrame.width * 0.8 && height >= displayFrame.height * 0.8
        }
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
