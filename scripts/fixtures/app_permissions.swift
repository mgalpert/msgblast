import Foundation
@preconcurrency import Contacts

// Only this standalone harness supplies AppModel. No real Contacts store,
// Messages database, workspace operation, or Automation request is used.
@MainActor
final class AppModel {
    final class ContactsStub { var status = CNAuthorizationStatus.notDetermined }
    var contacts = ContactsStub()
    var demo = false
    var permissionGuidePreview = false
    var contactsAvailable = false
    var contactStatus = ""
    var contactsRequests = 0
    func connectContacts() async {
        contactsRequests += 1
        contacts.status = .authorized
        contactsAvailable = true
    }
}

final class PermissionProbe: @unchecked Sendable {
    struct State {
        var history = AppPermissionStatus.denied
        var automation = AppPermissionStatus.notRequested
        var running = true
        var asks: [Bool] = []
        var historyReads = 0
        var messagesOpened = 0
        var settings: [String] = []
        var openingFails = false
    }
    private let lock = NSLock()
    private var state = State()
    func change(_ body: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&state)
    }
    var snapshot: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }
    @MainActor
    func client(available: Bool = true) -> AppPermissionClient {
        AppPermissionClient(
            historyStatus: {
                precondition(!Thread.isMainThread, "Protected-file checks must run off the main thread")
                self.change { $0.historyReads += 1 }
                return self.snapshot.history
            },
            automationStatus: { ask in
                precondition(!Thread.isMainThread, "Automation checks must run off the main thread")
                self.change { $0.asks.append(ask) }
                return self.snapshot.automation
            },
            messagesAvailable: available,
            messagesRunning: { self.snapshot.running },
            openMessages: {
                if self.snapshot.openingFails { throw CocoaError(.fileNoSuchFile) }
                self.change { $0.messagesOpened += 1; $0.running = true }
            },
            openSettings: { pane in
                self.change { $0.settings.append(pane) }
                return true
            })
    }
}

@main
struct PermissionCheck {
    @MainActor
    static func main() async {
        let model = AppModel()
        let probe = PermissionProbe()
        let permissions = AppPermissions(client: probe.client())
        await permissions.refresh(model: model)
        await permissions.refresh(model: model)
        precondition(permissions.history == .denied && permissions.contacts == .notRequested && permissions.sending == .notRequested)
        precondition(probe.snapshot.asks == [false, false] && probe.snapshot.messagesOpened == 0 && probe.snapshot.settings.isEmpty)
        precondition(model.contactsRequests == 0)
        print("PASS: opening and refreshing Settings check access without requesting consent or launching Messages")

        await permissions.enableContacts(model: model)
        precondition(model.contactsRequests == 1 && permissions.contacts == .allowed && permissions.history == .denied)
        print("PASS: explicit Contacts Enable works independently of Messages access")

        probe.change { $0.automation = .allowed }
        await permissions.enableSending(model: model)
        precondition(probe.snapshot.asks == [false, false, true] && permissions.sending == .allowed)
        print("PASS: explicit Sending Enable requests consent")

        model.contacts.status = .denied
        probe.change { $0.automation = .denied; $0.history = .allowed }
        await permissions.refresh(model: model)
        precondition(permissions.contacts == .denied && permissions.sending == .denied && permissions.history == .allowed)
        precondition(permissions.sending.title == "Off" && permissions.sending.actionTitle == "Open Settings")
        await permissions.enableSending(model: model)
        await permissions.enableContacts(model: model)
        precondition(probe.snapshot.asks == [false, false, true, false])
        precondition(probe.snapshot.settings == ["Privacy_Automation", "Privacy_Contacts"] && model.contactsRequests == 1)
        print("PASS: a subsequent refresh reflects changed access; denied actions open Settings without requesting consent")

        probe.change { $0.running = false; $0.automation = .notRequested; $0.asks = [] }
        await permissions.refresh(model: model)
        precondition(permissions.sending == .needsMessages && permissions.sending.actionTitle == "Check access" && probe.snapshot.asks.isEmpty)
        await permissions.enableSending(model: model)
        precondition(probe.snapshot.messagesOpened == 1 && probe.snapshot.asks == [false] && permissions.sending == .notRequested)
        await permissions.enableSending(model: model)
        precondition(probe.snapshot.asks == [false, true])
        print("PASS: Check access opens Messages and checks without consent; a separate Enable action may request it")

        model.contacts.status = .restricted
        probe.change { $0.automation = .unavailable }
        await permissions.refresh(model: model)
        precondition(permissions.contacts == .restricted && permissions.contacts.title == "Restricted")
        precondition(permissions.sending == .unavailable && permissions.sending.title == "Not checked" && permissions.sending.actionTitle == "Open Settings")
        let unavailable = AppPermissions(client: probe.client(available: false))
        let beforeUnavailable = probe.snapshot.asks
        await unavailable.refresh(model: model)
        precondition(unavailable.sending == .unavailable && probe.snapshot.asks == beforeUnavailable)
        print("PASS: restricted Contacts and unavailable Automation are never shown as Allowed")

        probe.change { $0.running = false; $0.openingFails = true; $0.asks = [] }
        await permissions.refresh(model: model)
        await permissions.enableSending(model: model)
        precondition(probe.snapshot.asks.isEmpty && permissions.message != nil && !permissions.checkingSending)
        print("PASS: a Messages launch failure leaves access unchecked and does not request consent")

        model.demo = true
        model.permissionGuidePreview = true
        let beforeDemo = probe.snapshot
        await permissions.refresh(model: model)
        await permissions.enableSending(model: model)
        precondition(probe.snapshot.historyReads == beforeDemo.historyReads && probe.snapshot.asks == beforeDemo.asks && probe.snapshot.messagesOpened == beforeDemo.messagesOpened)
        precondition(permissions.history == .notConnected && permissions.sending == .allowed)
        print("PASS: demo permissions bypass native permission checks and requests")
        print("8 permission-boundary regressions passed; all OS responses were simulated")
    }
}
