import CoreGraphics
import Foundation
import Vision

struct OCRTextLine: Equatable {
    let text: String
    let top: CGFloat
}

struct ContactVerificationEvidence: Equatable {
    let fieldMatched: Bool
    let resultMatchCount: Int
    let matchedSections: [String]

    var isUnique: Bool {
        fieldMatched && resultMatchCount == 1
    }
}

enum VisionOCRError: LocalizedError {
    case invalidCrop
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCrop:
            return "微信搜索结果截图尺寸无效"
        case .recognitionFailed(let detail):
            return "微信搜索结果文字识别失败：\(detail)"
        }
    }
}

enum VisionOCR {
    private static let selectableSections = Set([
        "联系人", "群聊", "功能", "公众号", "企业微信联系人"
    ])
    private static let knownSections = [
        "企业微信联系人", "搜索网络结果", "聊天记录", "聊天文件",
        "联系人", "公众号", "小程序", "朋友圈", "视频号", "群聊",
        "功能", "收藏", "文章", "表情"
    ]

    static func verifyUniqueContact(
        _ contact: String,
        in capture: SearchPanelCapture
    ) throws -> ContactVerificationEvidence {
        let size = capture.pointSize
        guard size.width >= 240, size.height >= 300 else {
            throw VisionOCRError.invalidCrop
        }

        let fieldImage = try crop(
            capture.image,
            pointRect: CGRect(x: 35, y: 0, width: min(120, size.width - 35), height: min(65, size.height)),
            pointSize: size
        )
        let sectionImage = try crop(
            capture.image,
            pointRect: CGRect(x: 0, y: 0, width: min(335, size.width), height: size.height),
            pointSize: size
        )
        let candidateImage = try crop(
            capture.image,
            pointRect: CGRect(x: 75, y: 0, width: min(260, size.width - 75), height: size.height),
            pointSize: size
        )

        let fieldLines = try recognize(fieldImage, pointHeight: min(65, size.height))
        let sectionLines = try recognize(sectionImage, pointHeight: size.height)
        let candidateLines = try recognize(candidateImage, pointHeight: size.height)
        return evaluate(
            contact: contact,
            fieldTexts: fieldLines.map(\.text),
            sectionLines: sectionLines,
            candidateLines: candidateLines
        )
    }

    static func evaluate(
        contact: String,
        fieldTexts: [String],
        sectionLines: [OCRTextLine],
        candidateLines: [OCRTextLine]
    ) -> ContactVerificationEvidence {
        let expected = normalized(contact)
        let fieldMatched = !expected.isEmpty && fieldTexts.contains {
            normalized($0) == expected
        }

        let sections = canonicalSections(from: sectionLines)
        var matches: [(line: OCRTextLine, section: String)] = []
        for (index, section) in sections.enumerated() where selectableSections.contains(section.title) {
            let lowerBound = section.top + 8
            let upperBound = index + 1 < sections.count ? sections[index + 1].top - 4 : .greatestFiniteMagnitude
            for line in candidateLines where line.top >= lowerBound && line.top < upperBound {
                if normalized(line.text) == expected {
                    matches.append((line, section.title))
                }
            }
        }

        return ContactVerificationEvidence(
            fieldMatched: fieldMatched,
            resultMatchCount: matches.count,
            matchedSections: Array(Set(matches.map(\.section))).sorted()
        )
    }

    private static func recognize(_ image: CGImage, pointHeight: CGFloat) throws -> [OCRTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.012

        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            throw VisionOCRError.recognitionFailed(error.localizedDescription)
        }

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRTextLine(
                text: candidate.string,
                top: (1 - observation.boundingBox.maxY) * pointHeight
            )
        }.sorted { $0.top < $1.top }
    }

    private static func crop(
        _ image: CGImage,
        pointRect: CGRect,
        pointSize: CGSize
    ) throws -> CGImage {
        guard pointSize.width > 0, pointSize.height > 0 else {
            throw VisionOCRError.invalidCrop
        }
        let scaleX = CGFloat(image.width) / pointSize.width
        let scaleY = CGFloat(image.height) / pointSize.height
        var imageRect = CGRect(
            x: pointRect.minX * scaleX,
            y: pointRect.minY * scaleY,
            width: pointRect.width * scaleX,
            height: pointRect.height * scaleY
        ).integral
        imageRect = imageRect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard imageRect.width > 0,
              imageRect.height > 0,
              let result = image.cropping(to: imageRect) else {
            throw VisionOCRError.invalidCrop
        }
        return result
    }

    private static func canonicalSections(from lines: [OCRTextLine]) -> [(title: String, top: CGFloat)] {
        var result: [(title: String, top: CGFloat)] = []
        for line in lines.sorted(by: { $0.top < $1.top }) {
            guard let title = canonicalSectionTitle(line.text) else { continue }
            if let previous = result.last,
               previous.title == title,
               abs(previous.top - line.top) < 8 {
                continue
            }
            result.append((title, line.top))
        }
        return result
    }

    private static func canonicalSectionTitle(_ text: String) -> String? {
        let value = normalized(text)
        return knownSections.first { title in
            guard value.hasPrefix(title) else { return false }
            let suffix = String(value.dropFirst(title.count))
            guard !suffix.isEmpty else { return true }
            return suffix.unicodeScalars.allSatisfy {
                CharacterSet.decimalDigits.contains($0) || "()（）[]【】".unicodeScalars.contains($0)
            }
        }
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_Hans_CN"))
            .unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
    }
}
