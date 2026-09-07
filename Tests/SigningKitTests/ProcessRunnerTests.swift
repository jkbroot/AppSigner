import XCTest
@testable import SigningKit

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStdoutAndZeroExit() throws {
        let r = try ProcessRunner().run("/bin/echo", ["hello world"])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testNonZeroExitCaptured() throws {
        let r = try ProcessRunner().run("/usr/bin/false", [])
        XCTAssertNotEqual(r.exitCode, 0)
    }

    func testRunThrowingThrowsOnFailure() {
        XCTAssertThrowsError(try ProcessRunner().runThrowing("/usr/bin/false", []))
    }

    func testRunThrowingSucceeds() throws {
        try ProcessRunner().runThrowing("/bin/echo", ["ok"])
    }
}

extension ProcessRunnerTests {
    func testRunsInWorkingDirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("marker.txt"))
        let r = try ProcessRunner().run("/bin/ls", [], cwd: dir)
        XCTAssertTrue(r.stdout.contains("marker.txt"), "ls in cwd should list marker.txt, got: \(r.stdout)")
    }
}

extension ProcessRunnerTests {
    func testRunStreamingEmitsLinesInOrder() throws {
        var lines: [String] = []
        let code = try ProcessRunner().runStreaming("/bin/sh", ["-c", "printf 'a\\nb\\nc\\n'"]) { lines.append($0) }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(lines, ["a", "b", "c"])
    }
}
