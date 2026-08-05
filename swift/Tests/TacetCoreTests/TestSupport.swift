import Darwin
import Foundation
import Network
@testable import TacetCore

/// Shared helpers for integration and e2e tests.
enum TestSupport {
    /// A currently-free high port. There is a tiny race between releasing the
    /// probe socket and the test binding it, which is acceptable in tests.
    static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        let port = CFSwapInt16BigToHost(bound.sin_port)
        close(fd)
        return port
    }

    /// Poll a check until it passes or the timeout elapses.
    static func waitUntil(timeout: TimeInterval = 5.0, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return check()
    }

    static func bodyText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

/// A minimal HTTP/1.1 mock server for faking whisper-server (and any endpoint
/// the e2e path touches). Responds to every received request via `responder`.
final class MiniHTTPServer {
    let port: UInt16
    private let listener: NWListener
    private let responder: (Data) -> (Int, Data)
    private(set) var requestCount = 0

    init(responder: @escaping (Data) -> (Int, Data)) throws {
        self.port = TestSupport.freePort()
        self.responder = responder
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw TacetServerError.bindFailed("bad test port")
        }
        listener = try NWListener(using: .tcp, on: p)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        var buf = Data()
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, _, _ in
                guard let self else { return }
                if let data, !data.isEmpty { buf.append(data) }
                self.requestCount += 1
                let (status, body) = self.responder(buf)
                var head = "HTTP/1.1 \(status) OK\r\n"
                head += "Content-Type: application/json\r\n"
                head += "Content-Length: \(body.count)\r\n"
                head += "Connection: close\r\n\r\n"
                var resp = Data(head.utf8)
                resp.append(body)
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        read()
    }

    /// Start the listener and wait until it is actually accepting connections.
    ///
    /// `NWListener.start` is asynchronous — it returns while the listener is
    /// still `.setup`/`.waiting`, so a test that connects immediately races it.
    /// On an idle machine the connect wins and everything passes, which is why
    /// this only ever appeared on CI: two different tests in DictateClientTests
    /// failed on 2026-08-05, each reporting a transport error ("connection was
    /// lost", "could not connect") instead of the response they asserted on.
    /// A flaky test in a required check is worse than a missing one — it
    /// teaches you to re-run rather than read.
    func start() {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            // .failed also signals: waiting out the full timeout on a listener
            // that will never be ready turns a clear error into a slow one.
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel() }
}
