import AppKit
import Foundation
@testable import msgblastCore

@main struct Benchmark {
    static func main() async throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard (5...6).contains(args.count), let pid = Int(args[3]),
              NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == "com.msgblast.grok-transport-fixture" else {
            fatalError("Requires the isolated Grok Transport Fixture, never a real provider")
        }
        let agent = URL(fileURLWithPath: args[1]), cua = URL(fileURLWithPath: args[2]), socket = args[4]
        let runner: DesktopAppConversation.ProcessRunner = { executable, arguments, environment, timeout, cancellation in
            var invocation = arguments
            if executable == cua {
                if arguments.count > 2, arguments[1] == "get_window_state" {
                    var payload = try JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as! [String: Any]
                    payload["tree_format"] = "elements"
                    invocation[2] = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                }
                invocation += ["--embedded", "--socket", socket]
            }
            let result = try await DesktopAppConversation.execute(executable, invocation, environment, timeout, cancellation)
            if result.status != 0 { print("DRIVER ERROR", arguments.prefix(2), result.status, result.stderr, result.stdout); return result }
            // Run real discovery (including its latency), then rewrite only
            // the fixture's provider identity. Never expose a real Grok process
            // as a benchmark destination, and never fabricate a running PID.
            let isCuaDiscovery = arguments.first == "call" && arguments.dropFirst().first == "list_apps"
            if isCuaDiscovery || arguments.first == "list-apps" {
                var envelope = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as! [String: Any]
                var data = isCuaDiscovery ? envelope : envelope["data"] as! [String: Any]
                let rows = data["apps"] as? [[String: Any]] ?? []
                var matches = rows.filter { $0["pid"] as? Int == pid && $0["bundle_id"] as? String == "com.msgblast.grok-transport-fixture" }
                guard matches.count == 1 else { throw CocoaError(.validationMissingMandatoryProperty) }
                matches[0]["bundle_id"] = "com.anysphere.sand"
                data["apps"] = matches
                if isCuaDiscovery { envelope = data } else { envelope["data"] = data }
                return .init(status: result.status, stdout: String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self), stderr: result.stderr)
            }
            return result
        }
        var timing = DesktopAppConversation.Timing()
        timing.pollInterval = .milliseconds(100)
        timing.stableDuration = .milliseconds(300)
        timing.replyTimeout = .seconds(15)
        let transports = [
            ("cua-0.38.0", DesktopAppConversation(executable: cua, timing: timing, delivery: .foreground, runProcess: runner)),
            ("agent-desktop-1.0.2", DesktopAppConversation(timing: timing, delivery: .foreground,
                agentDesktop: AgentDesktopTransport(executable: agent, run: runner)))
        ]
        var failures = 0
        for (name, driver) in transports {
            if args.count == 6, args[5] != "both", !name.hasPrefix(args[5]) { continue }
            do {
                let target = try await driver.target(.grokBot)
                func click(_ label: String) async throws {
                    let state = try await driver.snapshot(target, session: "benchmark-control")
                    let controls = state.elements.filter { $0.label == label && $0.role == "AXButton" }
                    guard controls.count == 1, let ref = controls.first?.element_token else { throw CocoaError(.validationMissingMandatoryProperty) }
                    _ = try await driver.call("click", ["element_token": ref, "session": "benchmark-control"], numbers: ["pid": target.pid, "window_id": target.window], as: DesktopAppConversation.Action.self)
                }
                try await driver.activate(target, session: "benchmark-focus")
                try await click("Reset fixture")
                let bots = try await driver.availableGrokBots()
                guard bots == ["Fixture Bot", "Research Bot"] else { throw CocoaError(.validationMissingMandatoryProperty) }
                print("PASS \(name): list both fixture bots")
                for iteration in 0..<5 {
                    let bot = iteration % 2 == 0 ? "Fixture Bot" : "Research Bot"
                    let binding = try await driver.connectGrokBot(named: bot)
                    let prompt = "Repeated benchmark prompt\nUnicode 🦊 café\n\nFinal line"
                    let receipt = Receipt()
                    let start = ContinuousClock.now
                    let answer = try await driver.reply(prompt, app: .grokBot, binding: binding, onReceipt: { await receipt.save($0) })
                    let elapsed = start.duration(to: .now)
                    guard answer == "Fixture reply: " + prompt else { throw CocoaError(.validationMissingMandatoryProperty) }
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    print("TIMING \(name) \(iteration) \(seconds)")
                    guard let anchor = await receipt.anchor else { throw CocoaError(.validationMissingMandatoryProperty) }
                    let stored = GrokReplyReceipt(comparisonID: UUID(), bot: bot, prompt: prompt, anchor: anchor)
                    let decoded = try JSONDecoder().decode(GrokReplyReceipt.self, from: JSONEncoder().encode(stored))
                    let recovered = try await driver.recoverGrokReply(decoded)
                    guard recovered == answer else { throw CocoaError(.validationMissingMandatoryProperty) }
                    print("PASS \(name): multiline Unicode, bot switching, duplicate prompt attribution, serialized receipt recovery")
                }
                try await click("Seed foreign draft")
                let draft = try GrokBotAppProfile.capture(target).draft
                _ = try await driver.availableGrokBots()
                try await driver.checkGrokBot(named: "Fixture Bot")
                var refused = false
                do { _ = try await driver.reply("Must not send", app: .grokBot, binding: .init(name: "Fixture Bot")) }
                catch { refused = true }
                guard refused, try GrokBotAppProfile.capture(target).draft == draft, draft == "Existing user draft — preserve me" else { throw CocoaError(.validationMissingMandatoryProperty) }
                _ = try await driver.reply("Other bot", app: .grokBot, binding: .init(name: "Research Bot"))
                try await click("Fixture Bot")
                guard try GrokBotAppProfile.capture(target).draft == draft else { throw CocoaError(.validationMissingMandatoryProperty) }
                print("PASS \(name): read-only setup with foreign draft, send refusal, other-bot send preserves original draft")
                let edgeCases = [
                    ("leading blank line", "\nLeading blank line"),
                    ("chunked long Unicode", String(repeating: "Long Unicode 🦊 café ", count: 18) + "End.")
                ]
                for (label, prompt) in edgeCases {
                    try await click("Reset fixture")
                    let edgeBefore = try await driver.snapshot(target, session: "edge-probe")
                    let edgeAnchor = try edgeBefore.grokHistoryAnchor()
                    do {
                        let answer = try await driver.reply(prompt, app: .grokBot, binding: .init(name: "Fixture Bot"))
                        guard answer == "Fixture reply: " + prompt else { throw CocoaError(.validationMissingMandatoryProperty) }
                        print("EDGE PASS \(name): \(label)")
                    } catch {
                        let edgeAfter = try await driver.snapshot(target, session: "edge-probe")
                        guard try edgeAnchor.matchesEnd(of: edgeAfter.historyText(app: .grokBot)) else { throw error }
                        print("EDGE REFUSED \(name): \(label), transcript unchanged, nothing submitted; \(error)")
                    }
                }
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
                if let target = try? await driver.target(.grokBot), let native = try? GrokBotAppProfile.capture(target) {
                    print("FIXTURE FAILURE STATE \(name): draft=\(String(reflecting: native.draft)), focused=\(native.composerFocused == true)")
                }
            }
        }
        if failures > 0 { exit(1) }
    }
    actor Receipt {
        var anchor: DesktopAppSnapshot.GrokHistoryAnchor?
        func save(_ value: DesktopAppSnapshot.GrokHistoryAnchor) { anchor = value }
    }
}
