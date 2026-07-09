#!/usr/bin/swift
// Set a TestFlight build's "What to Test" notes via the App Store Connect API.
//
//   swift scripts/tf-notes.swift <build-number> <notes-file>
//
// Polls until the build appears and finishes processing (uploads take
// 5-15 min to become visible), then writes the en-US whatsNew text.
// Credentials: scripts/asc-config.local + ~/.appstoreconnect/private_keys.
import CryptoKit
import Foundation

let bundleID = "io.robbie.Dispatch"

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

guard CommandLine.arguments.count == 3 else { fail("usage: tf-notes.swift <build-number> <notes-file>") }
let buildNumber = CommandLine.arguments[1]
guard let notes = try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8),
      !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("notes file missing or empty") }

// --- credentials ---------------------------------------------------------
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
guard let config = try? String(contentsOf: scriptDir.appendingPathComponent("asc-config.local"), encoding: .utf8) else {
    fail("scripts/asc-config.local not found")
}
var keyID = "", issuerID = ""
for line in config.split(separator: "\n") {
    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 {
        if parts[0] == "ASC_KEY_ID" { keyID = parts[1] }
        if parts[0] == "ASC_ISSUER_ID" { issuerID = parts[1] }
    }
}
guard !keyID.isEmpty, !issuerID.isEmpty else { fail("ASC_KEY_ID/ASC_ISSUER_ID missing from asc-config.local") }
let keyPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".appstoreconnect/private_keys/AuthKey_\(keyID).p8")
guard let pem = try? String(contentsOf: keyPath, encoding: .utf8),
      let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
    fail("cannot read/parse \(keyPath.path)")
}

// --- JWT (ES256, 15-minute expiry, re-minted per request batch) ----------
func b64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func makeToken() -> String {
    let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#
    let now = Int(Date().timeIntervalSince1970)
    let payload = #"{"iss":"\#(issuerID)","iat":\#(now),"exp":\#(now + 900),"aud":"appstoreconnect-v1"}"#
    let signingInput = b64url(Data(header.utf8)) + "." + b64url(Data(payload.utf8))
    let signature = try! privateKey.signature(for: Data(signingInput.utf8))
    return signingInput + "." + b64url(signature.rawRepresentation)
}

// --- minimal synchronous API client --------------------------------------
func request(_ method: String, _ path: String, body: [String: Any]? = nil) -> [String: Any] {
    var req = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com\(path)")!)
    req.httpMethod = method
    req.setValue("Bearer \(makeToken())", forHTTPHeaderField: "Authorization")
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try! JSONSerialization.data(withJSONObject: body)
    }
    let semaphore = DispatchSemaphore(value: 0)
    var result: [String: Any] = [:]
    var status = 0
    URLSession.shared.dataTask(with: req) { data, response, _ in
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let data, !data.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { result = json }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    if status >= 400 { fail("\(method) \(path) -> HTTP \(status): \(result)") }
    return result
}

// --- find app, poll for the build, set notes ------------------------------
let apps = request("GET", "/v1/apps?filter[bundleId]=\(bundleID)")["data"] as? [[String: Any]] ?? []
guard let appID = apps.first?["id"] as? String else { fail("app \(bundleID) not found") }

print("waiting for build \(buildNumber) to appear and finish processing...")
var buildID: String?
for attempt in 1...60 { // up to 30 minutes
    let builds = request("GET", "/v1/builds?filter[app]=\(appID)&filter[version]=\(buildNumber)&sort=-uploadedDate&limit=1")["data"] as? [[String: Any]] ?? []
    if let build = builds.first,
       let attrs = build["attributes"] as? [String: Any],
       let state = attrs["processingState"] as? String {
        if state == "VALID" { buildID = build["id"] as? String; break }
        if state == "FAILED" || state == "INVALID" { fail("build \(buildNumber) processing state: \(state)") }
        print("  [\(attempt)] processing (\(state))...")
    } else {
        print("  [\(attempt)] not visible yet...")
    }
    Thread.sleep(forTimeInterval: 30)
}
guard let buildID else { fail("build \(buildNumber) never became VALID (30 min timeout)") }

let locs = request("GET", "/v1/builds/\(buildID)/betaBuildLocalizations")["data"] as? [[String: Any]] ?? []
let enLoc = locs.first { (($0["attributes"] as? [String: Any])?["locale"] as? String)?.hasPrefix("en") == true }
if let locID = enLoc?["id"] as? String {
    _ = request("PATCH", "/v1/betaBuildLocalizations/\(locID)", body: [
        "data": ["type": "betaBuildLocalizations", "id": locID, "attributes": ["whatsNew": notes]]
    ])
} else {
    _ = request("POST", "/v1/betaBuildLocalizations", body: [
        "data": ["type": "betaBuildLocalizations",
                 "attributes": ["locale": "en-US", "whatsNew": notes],
                 "relationships": ["build": ["data": ["type": "builds", "id": buildID]]]]
    ])
}
print("what-to-test notes set on build \(buildNumber).")
