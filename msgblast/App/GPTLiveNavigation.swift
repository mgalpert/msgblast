import Foundation

enum GPTLiveDestination: String, CaseIterable {
    case agents, discover, settings, permissions
}
struct GPTLiveNavigationRequest: Identifiable, Equatable {
    let id = UUID()
    let destination: GPTLiveDestination
}
