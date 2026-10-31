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
            // Only discovery is injected to bind the unchanged Grok workflow to
            // the explicit local fixture. Every window read and input is real.
            if arguments.first == "call", arguments.dropFirst().first == "list_apps" {
                return .init(status: 0, stdout: "{\"apps\":[{\"pid\":\(pid),\"bundle_id\":\"com.anysphere.sand\",\"running\":true}]}")
            }
            if arguments.first == "list-apps" {
                let value: [String: Any] = ["ok": true, "data": ["apps": [["pid": pid, "bundle_id": "com.anysphere.sand", "name": "Grok Transport Fixture"]]]]
                return .init(status: 0, stdout: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
            }
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
            if result.status != 0 { print("DRIVER ERROR", arguments.prefix(2), result.status, result.stderr, result.stdout) }
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
                    let prompt = "Repeated benchmark prompt\nUnicode 🦊 café\n\n" + String(repeating: "Long Unicode 🦊 café ", count: 18)
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
                try await click("Reset fixture")
                let edgeBefore = try await driver.snapshot(target, session: "leading-newline")
                let edgeAnchor = try edgeBefore.grokHistoryAnchor()
                do {
                    let edge = try await driver.reply("\nLeading blank line", app: .grokBot, binding: .init(name: "Fixture Bot"))
                    guard edge == "Fixture reply: \nLeading blank line" else { throw CocoaError(.validationMissingMandatoryProperty) }
                    print("EDGE PASS \(name): leading blank line")
                } catch {
                    let edgeAfter = try await driver.snapshot(target, session: "leading-newline")
                    guard try edgeAnchor.matchesEnd(of: edgeAfter.historyText(app: .grokBot)) else { throw error }
                    print("EDGE REFUSED \(name): leading blank line, transcript unchanged, nothing submitted; \(error)")
                }
            } catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        if failures > 0 { exit(1) }
    }
    actor Receipt {
        var anchor: DesktopAppSnapshot.GrokHistoryAnchor?
        func save(_ value: DesktopAppSnapshot.GrokHistoryAnchor) { anchor = value }
    }
}
