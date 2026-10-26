import Foundation
import Network

/// The C11 isolation test site: one page that writes or reads a cookie, localStorage, an
/// IndexedDB value and a service worker registration, and reports what it did in its title.
///
/// - `/?mode=write&tag=T` stores `T` everywhere and registers `/sw.js`; title `written:T`.
/// - `/?mode=read` reports what it sees; title `read:c=<cookie>;l=<localStorage>;i=<IndexedDB>;sw=<count>`
///   with `-` for nothing.
///
/// Served from 127.0.0.1 (a secure context, so service workers work over plain HTTP). The same
/// files serve the manual check in the dev app (`python3 -m http.server` over `app/.build/c11-site`).
enum ProfileIsolationSite {
    static let indexHTML = """
    <!doctype html><meta charset="utf-8"><title>loading</title>
    <body>C11 isolation page</body>
    <script>
    (async () => {
      const q = new URLSearchParams(location.search);
      const mode = q.get('mode') || 'read', tag = q.get('tag') || '';
      const openDB = () => new Promise((resolve, reject) => {
        const r = indexedDB.open('c11', 1);
        r.onupgradeneeded = () => r.result.createObjectStore('kv');
        r.onsuccess = () => resolve(r.result);
        r.onerror = () => reject(r.error);
      });
      const run = (db, access, body) => new Promise((resolve, reject) => {
        const t = db.transaction('kv', access);
        const request = body(t.objectStore('kv'));
        t.oncomplete = () => resolve(request.result);
        t.onerror = () => reject(t.error);
      });
      try {
        if (mode === 'write') {
          document.cookie = 'c11=' + tag + '; max-age=3600; path=/';
          localStorage.setItem('c11', tag);
          const db = await openDB();
          await run(db, 'readwrite', s => s.put(tag, 'c11'));
          db.close();
          await navigator.serviceWorker.register('/sw.js');
          await navigator.serviceWorker.ready;
          document.title = 'written:' + tag;
        } else {
          const cookie = document.cookie.match(/(?:^|; )c11=([^;]*)/);
          const db = await openDB();
          const stored = await run(db, 'readonly', s => s.get('c11'));
          db.close();
          const registrations = await navigator.serviceWorker.getRegistrations();
          document.title = 'read:c=' + (cookie ? cookie[1] : '-') + ';l=' + (localStorage.getItem('c11') || '-')
            + ';i=' + (stored || '-') + ';sw=' + registrations.length;
        }
      } catch (e) {
        document.title = 'error:' + e;
      }
    })();
    </script>
    """

    static let serviceWorkerJS = "self.addEventListener('fetch', () => {});\n"

    /// The title a read reports when it sees `tag` in every store (and one service worker).
    static func sawEverything(_ tag: String) -> String { "read:c=\(tag);l=\(tag);i=\(tag);sw=1" }
    /// The title a read reports in a context that has none of the site's data.
    static let sawNothing = "read:c=-;l=-;i=-;sw=0"
}

/// A minimal HTTP/1.0 server for `ProfileIsolationSite` on 127.0.0.1 with a free port.
final class ProfileIsolationServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.openarc.tests.c11-site")
    /// The port the server listens on (valid after `start`).
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening; returns once the port is known.
    func start() async throws {
        let listener = self.listener
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.serve(connection, received: Data())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.port = port
    }

    func stop() { listener.cancel() }

    func url(_ query: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/?\(query)")!
    }

    private static func serve(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
            var buffer = received
            if let data { buffer.append(data) }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if isComplete || error != nil { connection.cancel() } else { serve(connection, received: buffer) }
                return
            }
            let target = text.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
            let path = target.split(separator: "?").first.map(String.init) ?? "/"
            let (status, type, body): (String, String, String)
            switch path {
            case "/": (status, type, body) = ("200 OK", "text/html; charset=utf-8", ProfileIsolationSite.indexHTML)
            case "/sw.js": (status, type, body) = ("200 OK", "text/javascript", ProfileIsolationSite.serviceWorkerJS)
            default: (status, type, body) = ("404 Not Found", "text/plain", "not found")
            }
            let payload = Data(body.utf8)
            let head = "HTTP/1.0 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// Lets exactly one caller through (a continuation resumed once).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
