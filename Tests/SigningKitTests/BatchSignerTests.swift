import XCTest
@testable import SigningKit

final class BatchSignerTests: XCTestCase {
    private func request(_ name: String) -> SigningRequest {
        SigningRequest(ipa: URL(fileURLWithPath: "/tmp/\(name).ipa"),
                       profileURL: URL(fileURLWithPath: "/tmp/p.mobileprovision"),
                       identitySHA1: "ABC")
    }

    private func result(_ name: String) -> SigningResult {
        SigningResult(outputURL: URL(fileURLWithPath: "/tmp/\(name)_Signed.ipa"),
                      teamIdentifier: "TEAM", authority: "Someone", signedComponentCount: 1)
    }

    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "binary is encrypted" }
    }

    func testSignsEveryRequestInOrder() {
        var seen: [String] = []
        let signer = BatchSigner { request, _ in
            seen.append(request.ipa.lastPathComponent)
            return self.result(request.ipa.deletingPathExtension().lastPathComponent)
        }
        let results = signer.run([request("a"), request("b"), request("c")])

        XCTAssertEqual(seen, ["a.ipa", "b.ipa", "c.ipa"])
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        XCTAssertEqual(results.map { $0.output?.lastPathComponent },
                       ["a_Signed.ipa", "b_Signed.ipa", "c_Signed.ipa"])
    }

    func testAFailureIsRecordedAndTheBatchContinues() {
        let signer = BatchSigner { request, _ in
            if request.ipa.lastPathComponent == "b.ipa" { throw Boom() }
            return self.result(request.ipa.deletingPathExtension().lastPathComponent)
        }
        let results = signer.run([request("a"), request("b"), request("c")])

        XCTAssertEqual(results.count, 3, "one bad file does not abort the rest")
        XCTAssertTrue(results[0].succeeded)
        XCTAssertFalse(results[1].succeeded)
        XCTAssertEqual(results[1].errorMessage, "binary is encrypted")
        XCTAssertNil(results[1].output)
        XCTAssertTrue(results[2].succeeded)
    }

    func testReportsProgressAndCompletionPerItem() {
        var finished: [(Int, Bool)] = []
        var events: [String] = []
        let signer = BatchSigner { request, progress in
            progress(.unpacking)
            return self.result(request.ipa.deletingPathExtension().lastPathComponent)
        }
        _ = signer.run([request("a"), request("b")],
                       progress: { index, _, event in events.append("\(index):\(event.description)") },
                       itemFinished: { index, result in finished.append((index, result.succeeded)) })

        XCTAssertEqual(events, ["0:Unpacking IPA", "1:Unpacking IPA"])
        XCTAssertEqual(finished.map(\.0), [0, 1])
        XCTAssertTrue(finished.allSatisfy(\.1))
    }

    func testEmptyBatchDoesNothing() {
        XCTAssertTrue(BatchSigner { _, _ in self.result("x") }.run([]).isEmpty)
    }
}
