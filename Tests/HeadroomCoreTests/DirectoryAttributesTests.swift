import XCTest
import Darwin
@testable import HeadroomCore

final class DirectoryAttributesTests: XCTestCase {
    func testBatchedMeasurementMatchesStatAcrossPagesAndNestedDirectories() throws {
        let fixture = try Fixture()
        let deps = fixture.target.appendingPathComponent("debug/deps")
        let files = FileManager.default
        for number in 0..<550 {
            try Data().write(to: deps.appendingPathComponent("dependency-\(number).d"))
        }
        let nestedFile = deps.appendingPathComponent("library-🍏.rlib")
        try Data(repeating: 1, count: 8192).write(to: nestedFile)
        let shared = fixture.base.appendingPathComponent("shared")
        try Data(repeating: 2, count: 4096).write(to: shared)
        try files.linkItem(at: shared, to: deps.appendingPathComponent("hard-link.rlib"))
        try files.createSymbolicLink(at: deps.appendingPathComponent("symbolic-link"), withDestinationURL: shared)

        let directory = open(deps.path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { return XCTFail("Could not open fixture directory") }
        defer { close(directory) }
        let entries = try XCTUnwrap(DirectoryAttributes.read(directory))
        XCTAssertEqual(entries.count, 554)
        XCTAssertGreaterThan(try XCTUnwrap(entries.first { $0.name == nestedFile.lastPathComponent }?.file).bytes, 0)
        XCTAssertEqual(try XCTUnwrap(entries.first { $0.name == "hard-link.rlib" }?.file).bytes, 0)
        XCTAssertNil(entries.first { $0.name == "symbolic-link" }?.file)

        let standard = try FileInspection.measure(fixture.target.path, allowLinks: true)
        let batched = try FileInspection.measure(fixture.target.path, allowLinks: true, batchAttributes: true)
        XCTAssertEqual(batched.identity, standard.identity)
        XCTAssertEqual(batched.bytes, standard.bytes)
        XCTAssertEqual(batched.files, standard.files)
        XCTAssertEqual(batched.latestWrite, standard.latestWrite)
        XCTAssertEqual(batched.latestFileWrite, standard.latestFileWrite)
        XCTAssertThrowsError(try FileInspection.measure(fixture.target.path, batchAttributes: true))
    }

    func testBatchedMeasurementRejectsSpecialFiles() throws {
        let fixture = try Fixture()
        XCTAssertEqual(mkfifo(fixture.target.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try FileInspection.measure(fixture.target.path, batchAttributes: true)) { error in
            XCTAssertEqual(error.localizedDescription, "Output contains a special filesystem object.")
        }
    }
}
