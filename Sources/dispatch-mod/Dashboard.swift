#if os(macOS)
import DispatchKit
import Foundation

/// Localhost moderation dashboard. A deliberately tiny sequential HTTP/1.1
/// server on 127.0.0.1 — the private key never leaves this machine; the
/// static page calls the tool's own signing endpoints below.
///
/// Portability note (documented follow-up, not built now): the HTML/JS is
/// framework-free and talks only to `/api/*` JSON endpoints, so it ports to a
/// Cloudflare Worker later by reimplementing the four endpoints with the same
/// request signing (WebCrypto ECDSA P-256) and serving the page as a static
/// asset.
struct Dashboard {
    let client: CloudKitWebClient
    let port: UInt16

    func serve() throws {
        let serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { throw DashboardError.socket("socket() failed") }
        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1") // localhost ONLY
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverSocket)
            throw DashboardError.socket("couldn't bind 127.0.0.1:\(port) — is another dispatch-mod serve running?")
        }
        guard listen(serverSocket, 8) == 0 else {
            close(serverSocket)
            throw DashboardError.socket("listen() failed")
        }
        print("dispatch-mod dashboard: http://127.0.0.1:\(port) (\(client.environment)) — Ctrl-C to stop")

        while true {
            let connection = accept(serverSocket, nil, nil)
            guard connection >= 0 else { continue }
            handle(connection: connection)
            close(connection)
        }
    }

    enum DashboardError: Error, CustomStringConvertible {
        case socket(String)
        var description: String { if case .socket(let message) = self { message } else { "" } }
    }

    // MARK: - Request handling

    private func handle(connection: Int32) {
        guard let request = readRequest(connection) else { return }
        let parts = request.line.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = target.split(separator: "?").first.map(String.init) ?? target
        let query = queryItems(of: target)

        let response: (status: String, contentType: String, body: Data)
        do {
            response = try route(method: method, path: path, query: query)
        } catch {
            response = ("500 Internal Server Error", "application/json",
                        jsonData(["error": "\(error)"]))
        }
        var header = "HTTP/1.1 \(response.status)\r\n"
        header += "Content-Type: \(response.contentType); charset=utf-8\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(response.body)
        payload.withUnsafeBytes { _ = write(connection, $0.baseAddress, $0.count) }
    }

    private func route(
        method: String, path: String, query: [String: String]
    ) throws -> (String, String, Data) {
        switch (method, path) {
        case ("GET", "/"):
            return ("200 OK", "text/html", Data(Self.pageHTML.utf8))
        case ("GET", "/api/pending"):
            let pending = try client.pendingSubmissions().map { submission in
                [
                    "recordName": submission.recordName,
                    "prompt": submission.prompt,
                    "type": QuestionType(rawValue: submission.typeRaw).map(String.init(describing:)) ?? "unknown",
                    "choices": submission.choices.joined(separator: ", "),
                    "creditName": submission.creditName ?? "",
                    "submittedAt": CKWebServicesSigner.iso8601Date(submission.submittedAt),
                ]
            }
            return ("200 OK", "application/json", jsonData(pending))
        case ("GET", "/api/flags"):
            let flags = try client.flags().map { flag in
                [
                    "recordName": flag.recordName,
                    "catalogRecordName": flag.catalogRecordName,
                    "reason": flag.reason,
                    "flaggedAt": CKWebServicesSigner.iso8601Date(flag.flaggedAt),
                ]
            }
            return ("200 OK", "application/json", jsonData(flags))
        case ("POST", "/api/approve"):
            guard let id = query["id"] else { return badRequest("missing id") }
            let tags = (query["tags"] ?? "").split(separator: ",").map(String.init)
            let catalog = try client.approve(submissionRecordName: id, tags: tags)
            return ("200 OK", "application/json", jsonData(["approved": catalog.recordName]))
        case ("POST", "/api/reject"):
            guard let id = query["id"] else { return badRequest("missing id") }
            try client.reject(submissionRecordName: id)
            return ("200 OK", "application/json", jsonData(["rejected": id]))
        case ("POST", "/api/resolve-flag"):
            guard let id = query["id"] else { return badRequest("missing id") }
            try client.resolveFlag(recordName: id)
            return ("200 OK", "application/json", jsonData(["resolved": id]))
        default:
            return ("404 Not Found", "application/json", jsonData(["error": "not found"]))
        }
    }

    private func badRequest(_ message: String) -> (String, String, Data) {
        ("400 Bad Request", "application/json", jsonData(["error": message]))
    }

    private func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private func queryItems(of target: String) -> [String: String] {
        guard let questionMark = target.firstIndex(of: "?") else { return [:] }
        var items: [String: String] = [:]
        for pair in target[target.index(after: questionMark)...].split(separator: "&") {
            let sides = pair.split(separator: "=", maxSplits: 1)
            guard let key = sides.first.map(String.init) else { continue }
            let value = sides.count > 1 ? String(sides[1]) : ""
            items[key] = value.removingPercentEncoding ?? value
        }
        return items
    }

    private func readRequest(_ connection: Int32) -> (line: String, headers: String)? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(connection, &buffer, buffer.count)
        guard count > 0,
              let text = String(bytes: buffer[0..<count], encoding: .utf8),
              let firstLine = text.split(separator: "\r\n").first else { return nil }
        return (String(firstLine), text)
    }

    // MARK: - Embedded page (framework-free; see portability note above)

    static let pageHTML = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>dispatch-mod</title>
    <style>
      body { font-family: -apple-system, sans-serif; margin: 2rem; background: #111; color: #eee; }
      h1 { font-size: 1.3rem; } h2 { font-size: 1.05rem; margin-top: 2rem; }
      table { border-collapse: collapse; width: 100%; }
      th, td { text-align: left; padding: .45rem .6rem; border-bottom: 1px solid #333; font-size: .9rem; }
      button { padding: .3rem .8rem; margin-right: .4rem; border: 0; border-radius: 6px; cursor: pointer; }
      .approve { background: #2e7d32; color: #fff; } .reject { background: #b23b3b; color: #fff; }
      .muted { color: #888; } #status { margin: 1rem 0; color: #9ad; min-height: 1.2em; }
    </style></head><body>
    <h1>Dispatch question moderation</h1>
    <div id="status"></div>
    <h2>Pending submissions</h2>
    <table id="pending"><thead><tr><th>Prompt</th><th>Type</th><th>Choices</th>
    <th>Credit</th><th>Submitted</th><th></th></tr></thead><tbody></tbody></table>
    <h2>Flags</h2>
    <table id="flags"><thead><tr><th>Catalog record</th><th>Reason</th><th>Flagged</th><th></th></tr></thead><tbody></tbody></table>
    <script>
    const status = (m) => document.getElementById('status').textContent = m;
    async function api(path, opts) {
      const res = await fetch(path, opts);
      const body = await res.json();
      if (!res.ok) throw new Error(body.error || res.status);
      return body;
    }
    function esc(s) { const d = document.createElement('div'); d.textContent = s ?? ''; return d.innerHTML; }
    async function refresh() {
      status('Loading…');
      try {
        const [pending, flags] = await Promise.all([api('/api/pending'), api('/api/flags')]);
        document.querySelector('#pending tbody').innerHTML = pending.map(p => `
          <tr><td>${esc(p.prompt)}</td><td>${esc(p.type)}</td><td>${esc(p.choices)}</td>
          <td>${esc(p.creditName) || '<span class=muted>anonymous</span>'}</td><td>${esc(p.submittedAt)}</td>
          <td><button class="approve" onclick="act('approve','${p.recordName}')">Approve</button>
          <button class="reject" onclick="act('reject','${p.recordName}')">Reject</button></td></tr>`
        ).join('') || '<tr><td colspan=6 class=muted>Nothing pending.</td></tr>';
        document.querySelector('#flags tbody').innerHTML = flags.map(f => `
          <tr><td>${esc(f.catalogRecordName)}</td><td>${esc(f.reason)}</td><td>${esc(f.flaggedAt)}</td>
          <td><button class="reject" onclick="act('resolve-flag','${f.recordName}')">Resolve</button></td></tr>`
        ).join('') || '<tr><td colspan=4 class=muted>No flags.</td></tr>';
        status('');
      } catch (e) { status('Error: ' + e.message); }
    }
    async function act(kind, id) {
      status(kind + '…');
      try { await api('/api/' + kind + '?id=' + encodeURIComponent(id), {method: 'POST'}); await refresh(); }
      catch (e) { status('Error: ' + e.message); }
    }
    refresh();
    </script></body></html>
    """
}
#endif
