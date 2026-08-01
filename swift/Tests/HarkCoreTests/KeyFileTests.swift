import XCTest
@testable import HarkCore

/// Tests for the key-file read/generate logic. Every test redirects
/// KeyFile.pathOverride to a throwaway directory under the system temp dir so
/// the real `~/.config/hark/key` is never touched.
final class KeyFileTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyFileTests-\(UUID().uuidString)")
        KeyFile.pathOverride = dir.appendingPathComponent("key")
    }

    override func tearDown() {
        KeyFile.pathOverride = nil
        dir = nil
        super.tearDown()
    }

    /// Write raw bytes to the overridden key file, creating its directory first.
    private func writeKeyFile(_ content: String) {
        try! FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: KeyFile.path)
    }

    func testLoadNilWhenAbsent() {
        XCTAssertNil(KeyFile.load())
    }

    func testEnsureCreatesAndPersists() {
        let key = KeyFile.ensure()
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(KeyFile.load(), key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: KeyFile.path.path))
    }

    func testEnsureIdempotent() {
        let first = KeyFile.ensure()
        let second = KeyFile.ensure()
        XCTAssertEqual(first, second)
    }

    func testLoadTrimsTrailingNewline() {
        writeKeyFile("abc123\n")
        XCTAssertEqual(KeyFile.load(), "abc123")
    }

    func testEnsurePrefersExistingFile() {
        writeKeyFile("persisted\n")
        XCTAssertEqual(KeyFile.ensure(), "persisted")
        // The pre-existing value wins; the file is not regenerated/clobbered.
        XCTAssertEqual(KeyFile.load(), "persisted")
    }
}
