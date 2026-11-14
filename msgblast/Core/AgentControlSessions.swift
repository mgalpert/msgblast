import Foundation

/// The open local sessions of outside agents. Switching Outside agents off closes every one,
/// so a session accepted before the switch can't keep answering after it.
@MainActor public final class AgentControlSessions<Session: AnyObject> {
    private struct Entry {
        let session: Session
        var pending = 0, ended = false
    }

    public private(set) var isOpen = false
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let cancel: (Session) -> Void

    public init(cancel: @escaping (Session) -> Void) { self.cancel = cancel }

    public var count: Int { entries.count }

    public func contains(_ session: Session) -> Bool { entries[ObjectIdentifier(session)] != nil }

    public func open() { isOpen = true }

    /// Keeps `session` open. While closed, cancels it instead and returns false.
    @discardableResult public func add(_ session: Session) -> Bool {
        guard isOpen else { cancel(session); return false }
        entries[ObjectIdentifier(session)] = Entry(session: session)
        return true
    }

    /// A request arrived on `session`. False, with the session cancelled, once it is closed or gone.
    @discardableResult public func begin(_ session: Session) -> Bool {
        let id = ObjectIdentifier(session)
        guard isOpen, entries[id] != nil else { cancel(session); return false }
        entries[id]?.pending += 1
        return true
    }

    /// A reply went out. Ends the session if the agent has stopped sending and nothing else is pending.
    public func finish(_ session: Session) {
        let id = ObjectIdentifier(session)
        guard let entry = entries[id] else { return }
        entries[id]?.pending = max(0, entry.pending - 1)
        endIfIdle(id)
    }

    /// The agent sent its last bytes. Ends the session once every reply has gone out.
    public func end(_ session: Session) {
        let id = ObjectIdentifier(session)
        entries[id]?.ended = true
        endIfIdle(id)
    }

    /// Cancels `session` now, for example after a read failed.
    public func drop(_ session: Session) {
        entries[ObjectIdentifier(session)] = nil
        cancel(session)
    }

    /// Switching off: refuses new sessions and cancels every open one.
    public func close() {
        isOpen = false
        let open = entries.values.map(\.session)
        entries = [:]
        open.forEach(cancel)
    }

    private func endIfIdle(_ id: ObjectIdentifier) {
        guard let entry = entries[id], entry.ended, entry.pending == 0 else { return }
        entries[id] = nil
        cancel(entry.session)
    }
}
