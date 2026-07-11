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

    /// Random per-run session token. Embedded in the served page and required
    /// (via `X-Dispatch-Mod-Token`) on every `/api/*` POST, so a hostile web
    /// page can't drive the signing endpoints cross-origin (CSRF) and a
    /// DNS-rebinding page can't call them either (it can never read the token:
    /// rebinding defeats the same-origin *check* on responses it triggers, but
    /// the token only ships in OUR page served from OUR socket).
    let sessionToken = Dashboard.makeSessionToken()

    static func makeSessionToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
    }

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

        var response: (status: String, contentType: String, body: Data)
        // DNS-rebinding guard: a rebound hostname resolves to us but carries
        // the attacker's Host header. Only our literal loopback origin passes.
        if headerValue("Host", in: request.headers) != "127.0.0.1:\(port)" {
            response = ("403 Forbidden", "application/json",
                        jsonData(["error": "bad Host header (use http://127.0.0.1:\(port))"]))
        } else if method == "POST", path.hasPrefix("/api/"),
                  headerValue("X-Dispatch-Mod-Token", in: request.headers) != sessionToken {
            // CSRF guard: mutating endpoints require the per-run token that
            // only the page served by this process knows.
            response = ("403 Forbidden", "application/json",
                        jsonData(["error": "missing or invalid session token"]))
        } else {
            do {
                response = try route(method: method, path: path, query: query)
            } catch {
                response = ("500 Internal Server Error", "application/json",
                            jsonData(["error": "\(error)"]))
            }
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
            let page = Self.pageHTML.replacingOccurrences(of: "__SESSION_TOKEN__", with: sessionToken)
            return ("200 OK", "text/html", Data(page.utf8))
        case ("GET", "/api/pending"):
            let pending = try client.pendingSubmissions().map { submission in
                [
                    "recordName": submission.recordName,
                    "prompt": submission.prompt,
                    "type": QuestionType(rawValue: submission.typeRaw).map(String.init(describing:)) ?? "unknown",
                    "choices": submission.choices.joined(separator: ", "),
                    "creditName": submission.creditName ?? "",
                    "submittedAt": CKWebServicesSigner.iso8601Date(submission.submittedAt),
                    // Plan 38: CloudKit creator metadata for flood detection.
                    // Untrusted output like every other field — the page only
                    // ever esc()'s it or binds it via closures.
                    "submitter": submission.createdUserRecordName ?? "",
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
        case ("POST", "/api/reject-user"):
            // Plan 38 bulk cleanup: delete every pending submission from one
            // creator, one by one with per-record verification (reject()
            // verifies each modify response). Same session-token gate as the
            // other mutating endpoints. Only ever touches SubmittedQuestion.
            guard let user = query["user"], !user.isEmpty else { return badRequest("missing user") }
            let targets = try client.pendingSubmissions()
                .filter { $0.createdUserRecordName == user }
            for submission in targets {
                try client.reject(submissionRecordName: submission.recordName)
            }
            return ("200 OK", "application/json",
                    jsonData(["rejectedUser": user, "count": targets.count] as [String: Any]))
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

    private func headerValue(_ name: String, in rawHeaders: String) -> String? {
        for line in rawHeaders.split(separator: "\r\n").dropFirst() {
            let sides = line.split(separator: ":", maxSplits: 1)
            guard sides.count == 2,
                  sides[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
            else { continue }
            return sides[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
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
      .flood { color: #f6b73c; font-weight: 600; }
      code { font-size: .8rem; color: #bbb; }
    </style></head><body>
    <h1>Dispatch question moderation</h1>
    <div id="status"></div>
    <h2>Submitters</h2>
    <table id="submitters"><thead><tr><th>User</th><th>Pending</th><th></th><th></th></tr></thead><tbody></tbody></table>
    <h2>Pending submissions</h2>
    <table id="pending"><thead><tr><th>Prompt</th><th>Type</th><th>Choices</th>
    <th>Credit</th><th>Submitter</th><th>Submitted</th><th></th></tr></thead><tbody></tbody></table>
    <h2>Flags</h2>
    <table id="flags"><thead><tr><th>Catalog record</th><th>Reason</th><th>Flagged</th><th></th></tr></thead><tbody></tbody></table>
    <script>
    const TOKEN = '__SESSION_TOKEN__';
    const status = (m) => document.getElementById('status').textContent = m;
    async function api(path, opts) {
      const res = await fetch(path, Object.assign({headers: {'X-Dispatch-Mod-Token': TOKEN}}, opts));
      const body = await res.json();
      if (!res.ok) throw new Error(body.error || res.status);
      return body;
    }
    function esc(s) { const d = document.createElement('div'); d.textContent = s ?? ''; return d.innerHTML; }
    // Record names are untrusted public-DB input: they only ever reach the
    // page as esc()'d text or as data bound via addEventListener closures —
    // never interpolated into inline handlers or attributes.
    function bindActions(tbody, rows, actions) {
      rows.forEach((row, i) => {
        tbody.rows[i].querySelectorAll('button').forEach((button, j) => {
          const [kind, idField] = actions[j];
          button.addEventListener('click', () => act(kind, row[idField]));
        });
      });
    }
    async function refresh() {
      status('Loading…');
      try {
        const [pending, flags] = await Promise.all([api('/api/pending'), api('/api/flags')]);
        // Plan 38 flood detection: group pending by CloudKit creator
        // metadata; >FLOOD_THRESHOLD from one user gets a loud marker and a
        // one-click bulk reject. User record names are untrusted like every
        // other value — esc()'d text and closure-bound data only.
        const FLOOD_THRESHOLD = 10;
        const bySubmitter = new Map();
        pending.forEach(p => {
          const key = p.submitter || '(unknown)';
          bySubmitter.set(key, (bySubmitter.get(key) || 0) + 1);
        });
        const submitters = [...bySubmitter.entries()]
          .map(([user, count]) => ({user, count}))
          .sort((a, b) => b.count - a.count || a.user.localeCompare(b.user));
        const submittersBody = document.querySelector('#submitters tbody');
        submittersBody.innerHTML = submitters.map(s => `
          <tr><td><code>${esc(s.user)}</code></td><td>${s.count}</td>
          <td>${s.count > FLOOD_THRESHOLD ? '<span class=flood>⚠️ FLOOD</span>' : ''}</td>
          <td><button class="reject">Reject all</button></td></tr>`
        ).join('') || '<tr><td colspan=4 class=muted>No pending submitters.</td></tr>';
        submitters.forEach((s, i) => {
          submittersBody.rows[i].querySelector('button')
            .addEventListener('click', () => rejectUser(s.user, s.count));
        });
        const pendingBody = document.querySelector('#pending tbody');
        pendingBody.innerHTML = pending.map(p => `
          <tr><td>${esc(p.prompt)}</td><td>${esc(p.type)}</td><td>${esc(p.choices)}</td>
          <td>${esc(p.creditName) || '<span class=muted>anonymous</span>'}</td>
          <td><code>${esc(p.submitter) || '<span class=muted>?</span>'}</code></td><td>${esc(p.submittedAt)}</td>
          <td><button class="approve">Approve</button>
          <button class="reject">Reject</button></td></tr>`
        ).join('') || '<tr><td colspan=7 class=muted>Nothing pending.</td></tr>';
        bindActions(pendingBody, pending, [['approve', 'recordName'], ['reject', 'recordName']]);
        const flagsBody = document.querySelector('#flags tbody');
        flagsBody.innerHTML = flags.map(f => `
          <tr><td>${esc(f.catalogRecordName)}</td><td>${esc(f.reason)}</td><td>${esc(f.flaggedAt)}</td>
          <td><button class="reject">Resolve</button></td></tr>`
        ).join('') || '<tr><td colspan=4 class=muted>No flags.</td></tr>';
        bindActions(flagsBody, flags, [['resolve-flag', 'recordName']]);
        status('');
      } catch (e) { status('Error: ' + e.message); }
    }
    async function act(kind, id) {
      status(kind + '…');
      try { await api('/api/' + kind + '?id=' + encodeURIComponent(id), {method: 'POST'}); await refresh(); }
      catch (e) { status('Error: ' + e.message); }
    }
    async function rejectUser(user, count) {
      if (!confirm(`Delete ALL ${count} pending submission(s) from ${user}? Approved catalog entries are untouched.`)) return;
      status('reject-user…');
      try {
        const result = await api('/api/reject-user?user=' + encodeURIComponent(user), {method: 'POST'});
        await refresh();
        status(`Rejected ${result.count} submission(s) from ${user}.`);
      } catch (e) { status('Error: ' + e.message); }
    }
    refresh();
    </script></body></html>
    """
}
#endif
