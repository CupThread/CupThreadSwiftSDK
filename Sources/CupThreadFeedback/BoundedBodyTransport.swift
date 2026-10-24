import Foundation

// MARK: - Bounded body transfer

/// Streams a response body and enforces a hard byte cap on the delegate queue.
///
/// `URLSession.data(from:)` buffers the entire body before the caller can
/// reject it, and URLSession transparently decompresses `Content-Encoding`, so
/// a small compressed response can expand into memory well past
/// `maxResponseBytes` before a post-hoc size check runs. This transport sees
/// every delivered chunk, cancels the task as soon as the accumulated bytes
/// cross the cap, and resumes the caller with
/// `URLError(.cannotDecodeContentData)` — so the cap applies during transfer,
/// to the bytes URLSession actually delivers.
final class BoundedBodyTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct PendingBody {
        let cap: Int
        var data: Data
        var continuation: CheckedContinuation<Data, Error>?
    }

    private let lock = NSLock()
    private var pending: [Int: PendingBody] = [:]

    /// Downloads `url`, failing as soon as the delivered body exceeds
    /// `maxBytes` (inclusive: a body exactly at the cap is accepted).
    func fetch(_ url: URL, using session: URLSession, maxBytes: Int) async throws -> Data {
        let task = session.dataTask(with: url)
        return try await withCheckedThrowingContinuation { continuation in
            register(task, maxBytes: maxBytes, continuation: continuation)
            task.resume()
        }
    }

    private func register(
        _ task: URLSessionTask,
        maxBytes: Int,
        continuation: CheckedContinuation<Data, Error>
    ) {
        let cap = max(0, maxBytes)
        var body = PendingBody(cap: cap, data: Data(), continuation: continuation)
        body.data.reserveCapacity(min(cap, 64 * 1_024))
        lock.lock()
        pending[task.taskIdentifier] = body
        lock.unlock()
    }

    private func finish(_ task: URLSessionTask, with result: Result<Data, any Error>) {
        lock.lock()
        guard let body = pending.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()
        body.continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(dataTask, with: .failure(URLError(.badServerResponse)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var body = pending[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        // The remaining allowance is non-negative on entry, so an oversized
        // chunk (or a clamped-to-zero injected cap) is rejected without any
        // arithmetic overflow.
        guard data.count <= body.cap - body.data.count else {
            pending.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            dataTask.cancel()
            body.continuation?.resume(throwing: URLError(.cannotDecodeContentData))
            return
        }
        body.data.append(data)
        pending[dataTask.taskIdentifier] = body
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            finish(task, with: .failure(error))
            return
        }
        lock.lock()
        let data = pending[task.taskIdentifier]?.data ?? Data()
        lock.unlock()
        finish(task, with: .success(data))
    }
}
