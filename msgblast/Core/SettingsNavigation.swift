import AppKit

/// Back and forward history for a sidebar of pages, like System Settings.
public struct PageHistory<Page: Equatable>: Equatable {
    public private(set) var current: Page
    private var back: [Page] = []
    private var forward: [Page] = []
    public init(_ page: Page) { current = page }
    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }
    public mutating func go(to page: Page) {
        guard page != current else { return }
        back.append(current); forward.removeAll(); current = page
    }
    public mutating func goBack() {
        guard let page = back.popLast() else { return }
        forward.append(current); current = page
    }
    public mutating func goForward() {
        guard let page = forward.popLast() else { return }
        back.append(current); current = page
    }
}

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public static let defaultsKey = "appAppearance"
    public var id: Self { self }
    public var title: String { rawValue.capitalized }
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    public static func saved(in defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}
