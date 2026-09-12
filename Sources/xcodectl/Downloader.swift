//
// Copyright (c) 2026 Daniel Bauke
//

import Foundation

/// Parallel ranged download on URLSession: N connections, each writing its slice straight into a
/// preallocated file. A small state file makes a killed run resume where it stopped.
final class Downloader: NSObject, URLSessionDataDelegate {
    init(url: URL, cookieHeader: String, destination: URL, connections: Int = Downloader.defaultConnections) {
        self.url = url
        self.cookieHeader = cookieHeader
        self.destination = destination
        self.connections = max(1, connections)
    }

    struct State: Codable {
        var url: String
        var total: Int64
        var starts: [Int64]
        var ends: [Int64] // inclusive
        var done: [Int64] // next byte to write, per range

        var isComplete: Bool {
            zip(done, ends).allSatisfy { $0 == $1 + 1 }
        }

        var downloaded: Int64 {
            zip(done, starts).reduce(0) { $0 + ($1.0 - $1.1) }
        }
    }

    static let defaultConnections = 16

    let url: URL
    let cookieHeader: String
    let destination: URL
    let connections: Int

    // MARK: - Driver

    func run(progress: @escaping (Double) -> Void) async throws {
        let total = try await probeSize()
        var ranges = connections
        while true {
            do {
                try await download(total: total, ranges: ranges, progress: progress)
                return
            } catch is RangeUnsupported where ranges > 1 {
                ranges = 1 // CDN answered 200 to a Range request: start over as one stream
                try? FileManager.default.removeItem(at: stateURL)
            }
        }
    }

    // MARK: - URLSessionDataDelegate (serial delegate queue)

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
    {
        guard let http = response as? HTTPURLResponse else {
            fail(Fail("no HTTP response"))
            return completionHandler(.cancel)
        }
        do { try Self.checkAuthorized(http) } catch { fail(error)
            return completionHandler(.cancel)
        }
        let wantedRange = dataTask.originalRequest?.value(forHTTPHeaderField: "Range") != nil
        switch http.statusCode {
        case 206 where wantedRange,
             200 where !wantedRange:
            completionHandler(.allow)

        case 200:
            fail(RangeUnsupported())
            completionHandler(.cancel)

        default:
            fail(Fail("Apple's CDN returned HTTP \(http.statusCode) while downloading"))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let i = index(dataTask)
        lock.withLock {
            guard failure == nil, let handle = handles[i] else {
                return
            }
            do {
                try handle.write(contentsOf: data)
                state.done[i] += Int64(data.count)
            } catch {
                failure = Fail("cannot write to \(partURL.path): \(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let i = index(task)
        let (finished, alreadyFailed) = lock.withLock { (state.done[i] == state.ends[i] + 1, failure != nil) }
        lock.withLock { try? handles[i]?.close()
            handles[i] = nil
        }
        if alreadyFailed {
            return
        }
        if error == nil, finished {
            return
        }
        if let error, (error as NSError).code == NSURLErrorCancelled {
            return
        }

        let attempt = (attempts[i] ?? 0) + 1
        attempts[i] = attempt
        guard attempt <= 5 else {
            fail(Fail("range \(i) failed after 5 attempts: \(error?.localizedDescription ?? "short read")"))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2 * attempt)) { [weak self] in
            guard let self, lock.withLock({ self.failure == nil }) else {
                return
            }
            do { try startTask(i) } catch { fail(error) }
        }
    }

    private struct RangeUnsupported: Error {}
    private struct Unauthorized: Error {}

    private let lock = NSLock()
    private var state: State!
    private var handles: [Int: FileHandle] = [:]
    private var attempts: [Int: Int] = [:]
    private var failure: Error?
    private var session: URLSession!

    private var partURL: URL {
        destination.appendingPathExtension("part")
    }

    private var stateURL: URL {
        destination.appendingPathExtension("state")
    }

    private static func checkAuthorized(_ http: HTTPURLResponse) throws {
        let html = (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/html")
        if http.url?.path.contains("unauthorized") == true || http.statusCode == 401 || http.statusCode == 403 || html {
            throw Fail(
                "Apple rejected the download ticket: run `xcodectl login` again (runners: re-export the session)")
        }
    }

    /// HEAD with the ticket cookie. Rejected sessions redirect to /unauthorized/ with a 200 HTML page.
    private func probeSize() async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        let (_, response) = try await Session.isolatedSession(timeout: 30).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Fail("no HTTP response from Apple's CDN")
        }
        try Self.checkAuthorized(http)
        guard http.statusCode == 200
        else {
            throw Fail("Apple's CDN returned HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        guard http.expectedContentLength > 0 else {
            throw Fail("Apple's CDN did not report the file size")
        }
        return http.expectedContentLength
    }

    private func download(total: Int64, ranges: Int, progress: @escaping (Double) -> Void) async throws {
        try prepareState(total: total, ranges: ranges)
        failure = nil
        attempts = [:]
        session = Session.isolatedSession(timeout: 60, connections: ranges, delegate: self)
        defer { session.invalidateAndCancel()
            closeHandles()
        }

        for i in 0 ..< state.starts.count where state.done[i] <= state.ends[i] {
            try startTask(i)
        }
        var tick = 0
        while true {
            try await Task.sleep(nanoseconds: 250_000_000)
            let (snapshot, error) = lock.withLock { (state!, failure) }
            if let error {
                saveState()
                throw error
            }
            progress(Double(snapshot.downloaded) / Double(total))
            if snapshot.isComplete {
                break
            }
            tick += 1
            if tick % 4 == 0 {
                saveState()
            }
        }
        closeHandles()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partURL, to: destination)
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func prepareState(total: Int64, ranges: Int) throws {
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(State.self, from: data),
           saved.url == url.absoluteString, saved.total == total, saved.starts.count == ranges,
           (try? partURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ Int64($0) == total }) == true
        {
            state = saved
            return
        }
        let chunk = total / Int64(ranges)
        var starts: [Int64] = [], ends: [Int64] = []
        for i in 0 ..< ranges {
            starts.append(Int64(i) * chunk)
            ends.append(i == ranges - 1 ? total - 1 : Int64(i + 1) * chunk - 1)
        }
        state = State(url: url.absoluteString, total: total, starts: starts, ends: ends, done: starts)
        try Paths.ensureCache()
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partURL)
        try handle.truncate(atOffset: UInt64(total))
        try handle.close()
    }

    private func saveState() {
        let snapshot = lock.withLock { state! }
        try? JSONEncoder().encode(snapshot).write(to: stateURL, options: .atomic)
    }

    private func closeHandles() {
        lock.withLock {
            handles.values.forEach { try? $0.close() }
            handles.removeAll()
        }
    }

    private func startTask(_ i: Int) throws {
        let (start, end, ranged) = lock.withLock { (
            state.done[i],
            state.ends[i],
            state.starts.count > 1 || state.done[i] > 0) }
        let handle = try FileHandle(forWritingTo: partURL)
        try handle.seek(toOffset: UInt64(start))
        lock.withLock { handles[i] = handle }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if ranged {
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        task.taskDescription = String(i)
        task.resume()
    }

    private func index(_ task: URLSessionTask) -> Int {
        Int(task.taskDescription ?? "0") ?? 0
    }

    private func fail(_ error: Error) {
        lock.withLock {
            if failure == nil {
                failure = error
            }
        }
    }
}
