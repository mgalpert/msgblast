import Foundation
import CryptoKit

public struct BusinessMessagePayload: Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case quickReply, listPicker, unsupported }
    public struct Option: Hashable, Sendable, Identifiable {
        public let id: Int
        public let title: String
        public let subtitle: String?
        public let section: String?
        public let selected: Bool
    }
    public let kind: Kind
    public let title: String
    public let options: [Option]
    public let sourceFingerprint: Data

    public static func decode(_ data: Data, bundleID: String) -> BusinessMessagePayload? {
        let businessID = "com.apple.icloud.apps.messages.business.extension"
        guard bundleID == businessID || bundleID.hasSuffix(":" + businessID),
              !data.isEmpty, data.count <= 1_048_576,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let fields = archiveFields(plist) else { return nil }
        let fingerprint = Data(SHA256.hash(data: data))
        let fallback = label(fields["ldtext"])
        guard let jsonData = fields["data"] as? Data, jsonData.count <= 524_288,
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return fallback.map { BusinessMessagePayload(kind: .unsupported, title: $0, options: [], sourceFingerprint: fingerprint) }
        }
        if let quick = json["quick-reply"] as? [String: Any], let items = quick["items"] as? [[String: Any]], items.count <= 100 {
            let selected = (quick["selectedIndex"] as? NSNumber)?.intValue
            let options = items.enumerated().compactMap { index, item -> Option? in
                guard let title = label(item["title"]) else { return nil }
                return Option(id: index, title: title, subtitle: nil, section: nil, selected: selected == index)
            }
            guard !options.isEmpty else { return nil }
            return BusinessMessagePayload(kind: .quickReply, title: label(quick["summaryText"]) ?? fallback ?? "Choose a response", options: options, sourceFingerprint: fingerprint)
        }
        if let picker = json["listPicker"] as? [String: Any], let sections = picker["sections"] as? [[String: Any]], sections.count <= 100 {
            let isReply = json["replyMessage"] as? [String: Any] != nil
            var options: [Option] = []
            for (sectionIndex, section) in sections.enumerated() {
                guard let items = section["items"] as? [[String: Any]], items.count <= 100 else { return nil }
                for item in items {
                    guard let title = label(item["title"]) else { continue }
                    options.append(Option(id: options.count, title: title, subtitle: label(item["subtitle"]), section: label(section["title"]), selected: isReply && sectionIndex == 0))
                }
            }
            guard !options.isEmpty, options.count <= 500 else { return nil }
            let received = json["receivedMessage"] as? [String: Any]
            return BusinessMessagePayload(kind: .listPicker, title: label(received?["title"]) ?? fallback ?? "Choose an option", options: options, sourceFingerprint: fingerprint)
        }
        return BusinessMessagePayload(kind: .unsupported, title: fallback ?? "Interactive business message", options: [], sourceFingerprint: fingerprint)
    }

    private static func label(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_096 else { return nil }
        return trimmed
    }

    // Resolve only the root dictionary's strings/data. Never instantiate archived classes.
    private static func archiveFields(_ plist: [String: Any]) -> [String: Any]? {
        guard plist["$archiver"] as? String == "NSKeyedArchiver",
              let objects = plist["$objects"] as? [Any], objects.count <= 4_096,
              let top = plist["$top"] as? [String: Any], let rootRef = top["root"],
              let rootIndex = referenceIndex(rootRef), objects.indices.contains(rootIndex),
              let root = objects[rootIndex] as? [String: Any],
              let keys = root["NS.keys"] as? [Any], let values = root["NS.objects"] as? [Any],
              keys.count == values.count, keys.count <= 128 else { return nil }
        var fields: [String: Any] = [:]
        for (keyRef, valueRef) in zip(keys, values) {
            guard let keyIndex = referenceIndex(keyRef), let valueIndex = referenceIndex(valueRef),
                  objects.indices.contains(keyIndex), objects.indices.contains(valueIndex),
                  let key = objects[keyIndex] as? String, fields[key] == nil else { return nil }
            if key == "data" || key == "ldtext" { fields[key] = objects[valueIndex] }
        }
        return fields
    }

    private static func referenceIndex(_ value: Any) -> Int? {
        // Foundation's XML writer represents binary-plist UIDs as CF$UID dictionaries.
        // Inspect that XML plist representation instead of using private UID APIs.
        guard let xml = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0),
              xml.count < 1_024, let text = String(data: xml, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"<plist[^>]*>\s*<dict>\s*<key>CF\$UID</key>\s*<integer>([0-9]+)</integer>\s*</dict>\s*</plist>\s*$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

/// Display-only snapshot for recording and owner-reviewed sharing.
/// Archive fingerprints and native action identifiers never enter this format.
public struct BusinessMessageCard: Codable, Equatable, Sendable {
    public var kind: BusinessMessagePayload.Kind
    public var title: String
    public var options: [Option]
    public struct Option: Codable, Equatable, Sendable {
        public var title: String
        public var selected: Bool
        public var subtitle: String?
        public var section: String?
    }
    public init(payload: BusinessMessagePayload, selectedOptionID: Int?) {
        kind = payload.kind
        title = payload.title
        options = payload.options.map { option in
            .init(title: option.title, selected: selectedOptionID.map { $0 == option.id } ?? option.selected,
                  subtitle: option.subtitle, section: option.section)
        }
    }
    public init(kind: BusinessMessagePayload.Kind, title: String, options: [Option]) {
        self.kind = kind; self.title = title; self.options = options
    }
    public mutating func redactText(_ transform: (String) -> String) {
        title = transform(title)
        for i in options.indices {
            options[i].title = transform(options[i].title)
            options[i].subtitle = options[i].subtitle.map(transform)
            options[i].section = options[i].section.map(transform)
        }
    }
}
