import XCTest
@testable import msgblastCore

final class LocalAgentDetectionTests: XCTestCase {
    func testSetupHandoffQuotesPathsAndRunsOnlyInteractiveConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Setup ' $(touch nope) \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for runtime in LocalAgentRuntime.allCases {
            let executable = directory.appendingPathComponent(runtime.rawValue)
            let output = directory.appendingPathComponent("arguments")
            try Data("#!/bin/sh\nprintf '%s' \"$*\" > \"$HOME/arguments\"\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let script = LocalAgentDetection.setupScript(using: .init(runtime: runtime, executableURL: executable), path: "/usr/bin:/bin", environment: ["HOME": directory.path, "OPENAI_API_KEY": "secret-must-not-be-written"])
            XCTAssertFalse(script.contains("secret-must-not-be-written"))
            let scriptURL = directory.appendingPathComponent("setup.command")
            try Data(script.utf8).write(to: scriptURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), runtime == .openclaw ? "configure" : "setup")
            XCTAssertFalse(FileManager.default.fileExists(atPath: scriptURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("nope").path))
        }
    }
    func testFindsOpenClawAndHermesWithoutLaunchingThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAgentDetection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("executed")
        for runtime in LocalAgentRuntime.allCases {
            let executable = directory.appendingPathComponent(runtime.rawValue)
            try Data("#!/bin/sh\n/bin/touch '\(marker.path)'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let detected = LocalAgentDetection.detect(path: directory.path)
        XCTAssertEqual(detected.map(\.runtime), [.openclaw, .hermes])
        XCTAssertEqual(detected.map(\.executableURL), LocalAgentRuntime.allCases.map { directory.appendingPathComponent($0.rawValue) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRejectsRelativeDirectoriesNonExecutablesAndDirectoriesNamedLikeCLIs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAgentDetection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("hermes"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("hermes").path)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("openclaw"), withIntermediateDirectories: false)
        XCTAssertTrue(LocalAgentDetection.detect(path: ".:relative:\(directory.path)").isEmpty)
    }
}
