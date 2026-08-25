import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum PermissionCenter {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static var hasScreenCapture: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func requestScreenCapture() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum LaunchAgentManager {
    static let label = "local.wechatsend.scheduler"

    static var installedApplicationURL: URL {
        URL(fileURLWithPath: "/Applications/微信发送.app", isDirectory: true)
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            let application: URL
            if FileManager.default.fileExists(atPath: installedApplicationURL.path) {
                application = installedApplicationURL
            } else if Bundle.main.bundleURL.pathExtension == "app" {
                application = Bundle.main.bundleURL
            } else {
                throw NSError(domain: "WeChatSend", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到应用可执行文件"])
            }
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-W", application.path],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Interactive"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }
}
