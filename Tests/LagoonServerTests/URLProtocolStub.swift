import Foundation

/// Thread-safe `URLProtocol` stub shared by the networking tests.
///
/// Requests never leave the process: `install(_:)` registers a handler that
/// returns a canned `HTTPURLResponse`, and `capturedRequests` records what was
/// actually sent (including the request body, which URLSession exposes via
/// `httpBodyStream` rather than `httpBody`).
final class URLProtocolStub: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    struct CapturedRequest {
        let request: URLRequest
        let body: Data?
    }

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var captured: [CapturedRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        Self.handler = handler
        captured = []
    }

    static var capturedRequests: [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        captured = []
    }

    private static func record(_ request: URLRequest, body: Data?) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        captured.append(CapturedRequest(request: request, body: body))
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Read the body while the stream is still fresh; URLSession hands the
        // body to URLProtocol as an input stream.
        let body = request.bodyData
        guard let handler = Self.record(request, body: body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// `httpBody` is usually nil inside a URLProtocol; the bytes live on the stream.
    var bodyData: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
