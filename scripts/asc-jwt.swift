#!/usr/bin/swift
// Print a short-lived App Store Connect API JWT (for curl use).
// Reads scripts/asc-config.local + ~/.appstoreconnect/private_keys.
import CryptoKit
import Foundation

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let config = try! String(contentsOf: scriptDir.appendingPathComponent("asc-config.local"), encoding: .utf8)
var keyID = "", issuerID = ""
for line in config.split(separator: "\n") {
    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 {
        if parts[0] == "ASC_KEY_ID" { keyID = parts[1] }
        if parts[0] == "ASC_ISSUER_ID" { issuerID = parts[1] }
    }
}
let keyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".appstoreconnect/private_keys/AuthKey_\(keyID).p8")
let key = try! P256.Signing.PrivateKey(pemRepresentation: String(contentsOf: keyURL, encoding: .utf8))
func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
let now = Int(Date().timeIntervalSince1970)
let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#
let payload = #"{"iss":"\#(issuerID)","iat":\#(now),"exp":\#(now + 900),"aud":"appstoreconnect-v1"}"#
let input = b64url(Data(header.utf8)) + "." + b64url(Data(payload.utf8))
let sig = try! key.signature(for: Data(input.utf8))
print(input + "." + b64url(sig.rawRepresentation))
