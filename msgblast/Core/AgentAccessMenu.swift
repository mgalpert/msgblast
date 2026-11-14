import SwiftUI

/// The level beside an approved outside agent in Settings → Outside agents. Its items are menu
/// toggles, so a level is saved only when the person picks one, never while SwiftUI builds or
/// redraws the agent's row. Picking the level already set does nothing.
public struct AgentAccessMenu: View {
    private let level: AgentControlAccess
    private let choose: (AgentControlAccess) -> Void

    public init(_ level: AgentControlAccess, choose: @escaping (AgentControlAccess) -> Void) {
        self.level = level
        self.choose = choose
    }

    public var body: some View {
        Menu(level.label) {
            ForEach(AgentControlAccess.allCases, id: \.self) { option in
                Toggle(option.label, isOn: Binding(get: { option == level }, set: { on in
                    if let next = Self.choice(option, picked: on, current: level) { choose(next) }
                }))
            }
        }
        .fixedSize()
    }

    /// The level to save when the person toggles `option` in the menu, or nil when nothing changes.
    static func choice(_ option: AgentControlAccess, picked: Bool, current: AgentControlAccess) -> AgentControlAccess? {
        picked && option != current ? option : nil
    }
}
