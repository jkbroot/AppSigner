import Foundation

/// The outcome of signing one app in a batch.
public struct BatchResult: Equatable {
    public let ipa: URL
    public let output: URL?
    public let errorMessage: String?
    public var succeeded: Bool { output != nil }

    public init(ipa: URL, output: URL?, errorMessage: String?) {
        self.ipa = ipa; self.output = output; self.errorMessage = errorMessage
    }
}

/// Signs a list of apps one after another with the same settings.
///
/// A failure is recorded and the run continues — one unreadable or encrypted app should
/// not throw away the rest of the batch. The signing step is injectable so the batch
/// logic can be tested without signing anything.
public struct BatchSigner {
    public typealias SignFunction =
        (SigningRequest, @escaping (PipelineEvent) -> Void) throws -> SigningResult

    private let sign: SignFunction

    public init(sign: @escaping SignFunction = { try SigningPipeline().sign($0, progress: $1) }) {
        self.sign = sign
    }

    /// - Parameters:
    ///   - progress: called with the item index, its request, and each pipeline event.
    ///   - itemFinished: called once per item with its result, as soon as it finishes.
    @discardableResult
    public func run(_ requests: [SigningRequest],
                    progress: ((Int, SigningRequest, PipelineEvent) -> Void)? = nil,
                    itemFinished: ((Int, BatchResult) -> Void)? = nil) -> [BatchResult] {
        var results: [BatchResult] = []
        for (index, request) in requests.enumerated() {
            let result: BatchResult
            do {
                let signed = try sign(request) { event in progress?(index, request, event) }
                result = BatchResult(ipa: request.ipa, output: signed.outputURL, errorMessage: nil)
            } catch {
                result = BatchResult(ipa: request.ipa, output: nil,
                                     errorMessage: error.localizedDescription)
            }
            results.append(result)
            itemFinished?(index, result)
        }
        return results
    }
}
