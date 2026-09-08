import XCTest
@testable import SigningKit

final class DebPackageTests: XCTestCase {
    private var fm: FileManager { .default }

    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("deb-\(UUID().uuidString)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Writes an `ar` archive — the container format a .deb uses.
    private func makeAr(members: [(String, URL)], at out: URL) throws {
        var data = Data("!<arch>\n".utf8)
        for (name, url) in members {
            let payload = try Data(contentsOf: url)
            var header = name.padding(toLength: 16, withPad: " ", startingAt: 0)
            header += "0".padding(toLength: 12, withPad: " ", startingAt: 0)
            header += "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            header += "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            header += "100644".padding(toLength: 8, withPad: " ", startingAt: 0)
            header += String(payload.count).padding(toLength: 10, withPad: " ", startingAt: 0)
            header += "`\n"
            data.append(Data(header.utf8))
            data.append(payload)
            if payload.count % 2 == 1 { data.append(0x0A) }
        }
        try data.write(to: out)
    }

    /// Builds a tweak .deb. `rootless` uses the /var/jb layout; `compression` is a tar flag.
    private func makeDeb(rootless: Bool = false, compression: String = "-J") throws -> URL {
        let dir = try tempDir()
        let payload = dir.appendingPathComponent("payload")
        let prefix = rootless ? "var/jb/Library" : "Library"
        let dylibDir = payload.appendingPathComponent("\(prefix)/MobileSubstrate/DynamicLibraries")
        try write("DYLIB-BYTES", to: dylibDir.appendingPathComponent("DemoTweak.dylib"))
        try write("""
        <?xml version="1.0"?><plist version="1.0"><dict><key>Filter</key><dict>\
        <key>Bundles</key><array><string>com.google.ios.youtube</string></array></dict></dict></plist>
        """, to: dylibDir.appendingPathComponent("DemoTweak.plist"))
        try write("RES", to: payload.appendingPathComponent("\(prefix)/Application Support/Demo.bundle/data.txt"))

        let control = dir.appendingPathComponent("controlroot/control")
        try write("""
        Package: com.demo.tweak
        Name: Demo Tweak
        Version: 1.2.3
        Author: Someone <a@b.c>
        Depends: mobilesubstrate, firmware (>= 14.0)
        Description: a demo

        """, to: control)

        let runner = ProcessRunner()
        let controlTar = dir.appendingPathComponent("control.tar.gz")
        try runner.runThrowing("/usr/bin/tar", ["-czf", controlTar.path, "-C",
                                                control.deletingLastPathComponent().path, "control"])
        let dataTar = dir.appendingPathComponent(compression == "-J" ? "data.tar.xz" : "data.tar.gz")
        try runner.runThrowing("/usr/bin/tar", [compression, "-cf", dataTar.path, "-C", payload.path,
                                                rootless ? "var" : "Library"])
        let debianBinary = dir.appendingPathComponent("debian-binary")
        try write("2.0\n", to: debianBinary)

        let deb = dir.appendingPathComponent("demo.deb")
        try makeAr(members: [("debian-binary", debianBinary),
                             ("control.tar.gz", controlTar),
                             (dataTar.lastPathComponent, dataTar)], at: deb)
        return deb
    }

    // MARK: Tests

    func testParsesControlMetadata() throws {
        let contents = try DebPackage.extract(deb: try makeDeb(), to: try tempDir())
        XCTAssertEqual(contents.info.identifier, "com.demo.tweak")
        XCTAssertEqual(contents.info.name, "Demo Tweak")
        XCTAssertEqual(contents.info.version, "1.2.3")
        XCTAssertEqual(contents.info.author, "Someone <a@b.c>")
        XCTAssertTrue(contents.info.dependencies.contains("mobilesubstrate"))
        XCTAssertTrue(contents.requiresSubstrate)
    }

    func testFindsDylibsAndResourceBundles() throws {
        let contents = try DebPackage.extract(deb: try makeDeb(), to: try tempDir())
        XCTAssertEqual(contents.dylibs.map(\.lastPathComponent), ["DemoTweak.dylib"])
        XCTAssertEqual(contents.bundles.map(\.lastPathComponent), ["Demo.bundle"])
    }

    func testReadsTargetBundleIDsFromTheFilterPlist() throws {
        let contents = try DebPackage.extract(deb: try makeDeb(), to: try tempDir())
        XCTAssertEqual(contents.targetBundleIDs, ["com.google.ios.youtube"])
    }

    func testSupportsRootlessLayout() throws {
        let contents = try DebPackage.extract(deb: try makeDeb(rootless: true), to: try tempDir())
        XCTAssertEqual(contents.dylibs.map(\.lastPathComponent), ["DemoTweak.dylib"])
        XCTAssertEqual(contents.bundles.map(\.lastPathComponent), ["Demo.bundle"])
    }

    func testSupportsGzipPayload() throws {
        let contents = try DebPackage.extract(deb: try makeDeb(compression: "-z"), to: try tempDir())
        XCTAssertEqual(contents.dylibs.count, 1)
    }

    func testRejectsSomethingThatIsNotADeb() throws {
        let bogus = try tempDir().appendingPathComponent("x.deb")
        try write("not a deb", to: bogus)
        XCTAssertThrowsError(try DebPackage.extract(deb: bogus, to: try tempDir()))
    }
}

extension DebPackageTests {
    /// ElleKit-style packages ship a CydiaSubstrate.framework rather than a loose dylib.
    func testFindsFrameworksInThePayload() throws {
        let dir = try tempDir()
        let payload = dir.appendingPathComponent("payload")
        let fw = payload.appendingPathComponent("Library/Frameworks/CydiaSubstrate.framework")
        try write("FWBIN", to: fw.appendingPathComponent("CydiaSubstrate"))
        try write("Package: ellekit\nVersion: 1.1.3\n", to: dir.appendingPathComponent("controlroot/control"))

        let runner = ProcessRunner()
        let controlTar = dir.appendingPathComponent("control.tar.gz")
        try runner.runThrowing("/usr/bin/tar", ["-czf", controlTar.path, "-C",
                                                dir.appendingPathComponent("controlroot").path, "control"])
        let dataTar = dir.appendingPathComponent("data.tar.gz")
        try runner.runThrowing("/usr/bin/tar", ["-czf", dataTar.path, "-C", payload.path, "Library"])
        let debianBinary = dir.appendingPathComponent("debian-binary")
        try write("2.0\n", to: debianBinary)
        let deb = dir.appendingPathComponent("ellekit.deb")
        try makeAr(members: [("debian-binary", debianBinary), ("control.tar.gz", controlTar),
                             ("data.tar.gz", dataTar)], at: deb)

        let contents = try DebPackage.extract(deb: deb, to: try tempDir())
        XCTAssertEqual(contents.frameworks.map(\.lastPathComponent), ["CydiaSubstrate.framework"])
        XCTAssertTrue(contents.dylibs.isEmpty, "the framework binary is not listed as a loose dylib")
    }
}
