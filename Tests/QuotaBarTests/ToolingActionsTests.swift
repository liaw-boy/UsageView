import Foundation
import XCTest
@testable import QuotaBarCore

/// Records every command instead of running it, so tests never touch the real CLIs.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(tool: String, args: [String])] = []
    var result = CommandResult(status: 0, output: "ok")

    func run(_ tool: String, _ args: [String], timeout: TimeInterval) async -> CommandResult {
        lock.lock(); calls.append((tool, args)); lock.unlock()
        return result
    }
}

final class ToolingActionsTests: XCTestCase {
    private var home: URL!
    private var runner: FakeRunner!
    private var actions: ToolingActions!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("acts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        runner = FakeRunner()
        actions = ToolingActions(home: home, env: [:], runner: runner)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func item(_ tool: ToolID, _ kind: ToolingKind, name: String, location: String? = nil,
                      status: ToolingStatus = .enabled, shared: [ToolID] = [], spec: String? = nil) -> ToolingItem {
        ToolingItem(tool: tool, kind: kind, name: name, detail: "", location: location,
                    status: status, sharedWith: shared, spec: spec)
    }

    // MARK: - Validation

    func testNameValidationRejectsInjectionAndPathTricks() {
        for bad in ["", "a b", "../evil", "a;rm -rf /", "-flag", "a$(whoami)", "a/b", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try ToolingActions.validateName(bad), bad)
        }
        XCTAssertNoThrow(try ToolingActions.validateName("my-server_1.2@mkt"))
    }

    func testURLValidationRequiresHTTPSExceptLocalhost() {
        XCTAssertThrowsError(try ToolingActions.validateURL("http://evil.com/mcp"))
        XCTAssertThrowsError(try ToolingActions.validateURL("file:///etc/passwd"))
        XCTAssertThrowsError(try ToolingActions.validateURL("notaurl"))
        XCTAssertNoThrow(try ToolingActions.validateURL("https://example.com/mcp"))
        XCTAssertNoThrow(try ToolingActions.validateURL("http://localhost:3000/mcp"))
    }

    func testCommandSplittingRejectsLeadingFlag() {
        XCTAssertThrowsError(try ToolingActions.splitCommand("--help"))
        XCTAssertEqual(try ToolingActions.splitCommand(" npx  -y pkg "), ["npx", "-y", "pkg"])
    }

    // MARK: - Removal policy

    func testOnlyItemsInsideKnownFoldersCanBeTrashed() {
        let inside = home.appendingPathComponent(".claude/skills/demo").path
        let outside = home.appendingPathComponent("Documents/demo").path
        let nested = home.appendingPathComponent(".claude/skills/a/b").path
        XCTAssertEqual(actions.removalMethod(for: item(.claudeCode, .skill, name: "demo", location: inside)), .trash)
        XCTAssertNil(actions.removalMethod(for: item(.claudeCode, .skill, name: "demo", location: outside)))
        XCTAssertNil(actions.removalMethod(for: item(.claudeCode, .skill, name: "demo", location: nested)))
        XCTAssertNil(actions.removalMethod(for: item(.claudeCode, .skill, name: "demo", location: nil)))
    }

    func testRemovalMethodPerKind() {
        XCTAssertEqual(actions.removalMethod(for: item(.opencode, .plugin, name: "p", spec: "pkg")),
                       .cli("opencode plugin remove pkg"))
        XCTAssertEqual(actions.removalMethod(for: item(.opencode, .plugin, name: "auto.js",
                                                       location: home.appendingPathComponent(".config/opencode/plugins/auto.js").path)),
                       .trash)
        XCTAssertEqual(actions.removalMethod(for: item(.opencode, .mcp, name: "m")), .editOpenCodeConfig)
        XCTAssertEqual(actions.removalMethod(for: item(.claudeCode, .mcp, name: "m")),
                       .cli("claude mcp remove --scope user m"))
        XCTAssertNil(actions.removalMethod(for: item(.codex, .mcp, name: "m")))
    }

    func testRemovingUnsupportedItemThrowsAndRunsNothing() async {
        await XCTAssertThrowsErrorAsync(try await actions.remove(item(.codex, .mcp, name: "m")))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // MARK: - opencode.json editing

    func testRemovingOpenCodeMCPBacksUpAndKeepsCommentsAndSiblings() throws {
        let file = try write(".config/opencode/opencode.jsonc", """
        {
          // my servers
          "mcp": { "servers": { "keep": { "type": "local" }, "drop": { "type": "remote" } } },
          "model": "anthropic/x"
        }
        """)
        let item = ToolingItem(tool: .opencode, kind: .mcp, name: "drop", detail: "remote · e.com",
                               location: file.path, status: .enabled, sharedWith: [], spec: "mcp.servers.drop")
        let acts = actions!
        let result = try awaitValue { try await acts.remove(item) }
        XCTAssertTrue(result.contains("drop"))

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("// my servers"))
        XCTAssertFalse(text.contains("\"drop\""))
        let servers = (JSONCText.object(text)?["mcp"] as? [String: Any])?["servers"] as? [String: Any]
        XCTAssertEqual(servers?.keys.sorted(), ["keep"])

        let backups = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.contains("usageview-bak") }
        XCTAssertEqual(backups.count, 1)
    }

    func testRemovingMissingOpenCodeMCPFailsWithoutWriting() throws {
        let file = try write(".config/opencode/opencode.json", #"{"mcp":{"servers":{"keep":{}}}}"#)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try actions.removeConfigKey(path: ["mcp", "servers", "nope"], in: file))
        XCTAssertEqual(before, try Data(contentsOf: file))
    }

    // MARK: - CLI argument building

    func testAddRemoteMCPPassesHeadersAsSeparateArguments() async throws {
        _ = try await actions.addMCP(name: "srv", spec: .remote(url: "https://e.com/mcp", headers: ["Authorization": "Bearer x"]), for: .opencode)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.tool, "opencode")
        XCTAssertEqual(call.args, ["mcp", "add", "--global", "--url", "https://e.com/mcp", "--header", "Authorization=Bearer x", "srv"])
    }

    func testAddLocalMCPPutsCommandAfterDoubleDash() async throws {
        _ = try await actions.addMCP(name: "srv", spec: .local(command: "npx -y pkg", env: ["K": "v"]), for: .claudeCode)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.tool, "claude")
        XCTAssertEqual(call.args, ["mcp", "add", "--scope", "user", "--transport", "stdio", "-e", "K=v", "srv", "--", "npx", "-y", "pkg"])
    }

    func testInvalidInputNeverReachesTheCLI() async {
        await XCTAssertThrowsErrorAsync(try await actions.addMCP(name: "bad name", spec: .remote(url: "https://e.com", headers: [:]), for: .opencode))
        await XCTAssertThrowsErrorAsync(try await actions.addMCP(name: "ok", spec: .remote(url: "http://evil.com", headers: [:]), for: .opencode))
        await XCTAssertThrowsErrorAsync(try await actions.addPlugin("--version", for: .opencode))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testFailedCommandSurfacesItsOutput() async {
        runner.result = CommandResult(status: 1, output: "boom")
        await XCTAssertThrowsErrorAsync(try await actions.addPlugin("pkg", for: .opencode)) { error in
            XCTAssertEqual((error as? ToolingActionError)?.errorDescription, "boom")
        }
    }

    // MARK: - Skills

    func testInstallSkillRequiresSkillFileAndNeverOverwrites() throws {
        let src = home.appendingPathComponent("src/demo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        XCTAssertThrowsError(try actions.installSkill(from: src, for: .opencode))

        try "---\nname: demo\n---".write(to: src.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        _ = try actions.installSkill(from: src, for: .opencode)
        let dest = home.appendingPathComponent(".config/opencode/skills/demo/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))

        XCTAssertThrowsError(try actions.installSkill(from: src, for: .opencode)) { error in
            guard case .alreadyExists = error as? ToolingActionError else { return XCTFail("expected alreadyExists") }
        }
    }

    // MARK: - Toggle / authorize gating

    func testToggleAndAuthorizeOnlyWhereSupported() async {
        XCTAssertTrue(actions.canToggle(item(.claudeCode, .plugin, name: "p@m")))
        XCTAssertFalse(actions.canToggle(item(.opencode, .plugin, name: "p")))
        await XCTAssertThrowsErrorAsync(try await actions.setEnabled(item(.opencode, .plugin, name: "p"), enabled: false))

        let remote = ToolingItem(tool: .opencode, kind: .mcp, name: "m", detail: "remote · e.com",
                                 location: nil, status: .enabled, sharedWith: [])
        XCTAssertTrue(actions.canAuthorize(remote))
        XCTAssertThrowsError(try actions.authorize(item(.claudeCode, .mcp, name: "m")) { _ in true })
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testAuthorizeHandsAnInteractiveCommandToTheTerminal() throws {
        let remote = ToolingItem(tool: .opencode, kind: .mcp, name: "sentry", detail: "remote · e.com",
                                 location: nil, status: .enabled, sharedWith: [])
        var received: String?
        _ = try actions.authorize(remote) { received = $0; return true }
        XCTAssertEqual(received, "opencode mcp auth sentry")
        XCTAssertTrue(runner.calls.isEmpty, "OAuth must not be captured in a pipe")

        XCTAssertThrowsError(try actions.authorize(remote) { _ in false })
    }
}

/// Bridges an async call into a synchronous test body.
func awaitValue<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = UnsafeResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task { await box.store(Result { try await work() }); sem.signal() }
    sem.wait()
    return try box.get()
}

final class UnsafeResultBox<T: Sendable>: @unchecked Sendable {
    private var result: Result<T, Error>?
    func store(_ r: Result<T, Error>) { result = r }
    func get() throws -> T {
        guard let result else { throw ToolingActionError.failed("no result") }
        return try result.get()
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "expected an error" : message, file: file, line: line)
    } catch {
        handler(error)
    }
}
