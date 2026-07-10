#!/usr/bin/swift
// Push the App Store listing (metadata, screenshots, review details, age
// rating, build attach) to App Store Connect from the listing kit in
// docs/app-store/ — the markdown is the single source of truth; this script
// carries no listing copy of its own.
//
//   swift scripts/asc-listing.swift [--apply] [--build <number>]
//                                   [--screenshots-dir <dir>] [--skip-screenshots]
//
// DEFAULT IS DRY-RUN: with no --apply flag the script prints the full plan
// of API calls (no network access at all, credentials not required) and
// exits. The API key role (App Manager required) cannot be verified through
// the API, so nothing executes until a human passes --apply.
//
// ############################################################################
// #  HARD CONSTRAINT — THIS SCRIPT NEVER SUBMITS FOR REVIEW.                 #
// #  There is deliberately NO code path that touches reviewSubmissions,     #
// #  appStoreVersionSubmissions, or any submit endpoint — no flag, no env   #
// #  var. The terminal step prints "ready for manual submission in App      #
// #  Store Connect"; a human presses the button. Do not add submission.     #
// ############################################################################
//
// Idempotent: every resource is fetch-then-patch (versions, localizations,
// review details, screenshot sets); screenshots already present with the
// same fileName+fileSize are skipped, so re-runs never duplicate.
//
// Credentials (only needed with --apply): scripts/asc-config.local
// (gitignored) + ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 —
// same pattern as upload-testflight.sh / tf-notes.swift. Optional contact
// keys for the review details (see docs/app-store/asc-automation.md):
//   ASC_CONTACT_FIRST / ASC_CONTACT_LAST / ASC_CONTACT_PHONE / ASC_CONTACT_EMAIL
//
// API shapes verified against developer.apple.com/documentation/appstoreconnectapi
// on 2026-07-10: asset upload = reserve (POST /v1/appScreenshots with
// fileName/fileSize + appScreenshotSet relationship) → PUT chunks per
// uploadOperations (method/url/offset/length/requestHeaders) → commit
// (PATCH uploaded=true + MD5 sourceFileChecksum). ScreenshotDisplayType has
// NO 6.9" case — APP_IPHONE_67 is the current largest-iPhone slot (ASC's
// media manager labels it 6.9"); APP_IPHONE_61 covers the 6.1"/6.3" class.
// Age rating hangs off appInfo, not appStoreVersion.
import CryptoKit
import Foundation

let bundleID = "io.robbie.Dispatch"
let locale = "en-US"
let repoRoot = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()

func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }
func warn(_ msg: String) { FileHandle.standardError.write(Data(("WARNING: " + msg + "\n").utf8)) }

// --- arguments ------------------------------------------------------------
var apply = false
var buildNumber: String?
var screenshotsDir = repoRoot.appendingPathComponent("docs/app-store/screenshots")
var skipScreenshots = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args.removeFirst() {
    case "--apply": apply = true
    case "--dry-run": apply = false
    case "--build":
        guard !args.isEmpty else { fail("--build needs a number") }
        buildNumber = args.removeFirst()
    case "--screenshots-dir":
        guard !args.isEmpty else { fail("--screenshots-dir needs a path") }
        screenshotsDir = URL(fileURLWithPath: args.removeFirst())
    case "--skip-screenshots": skipScreenshots = true
    case let other: fail("unknown argument: \(other)")
    }
}

// --- listing kit (single source of truth) ----------------------------------
struct ListingKit {
    var name = "", subtitle = "", privacyPolicyURL = "", supportURL = "", marketingURL = ""
    var description = "", keywords = "", promotionalText = "", whatsNew = ""
    var reviewNotes = ""
}

/// First fenced code block following the given heading line prefix.
func fencedBlock(after heading: String, in text: String) -> String? {
    guard let headingRange = text.range(of: heading) else { return nil }
    let rest = text[headingRange.upperBound...]
    guard let open = rest.range(of: "```\n") else { return nil }
    let afterOpen = rest[open.upperBound...]
    guard let close = afterOpen.range(of: "```") else { return nil }
    return String(afterOpen[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Identity-table lookup: `| <field> | \`value\` | ... |`.
func tableValue(field: String, in text: String) -> String? {
    for line in text.split(separator: "\n") where line.hasPrefix("| \(field) ") {
        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 2 else { continue }
        return cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }
    return nil
}

func loadListingKit() -> ListingKit {
    let listingURL = repoRoot.appendingPathComponent("docs/app-store/listing.md")
    let reviewURL = repoRoot.appendingPathComponent("docs/app-store/review-notes.md")
    guard let listing = try? String(contentsOf: listingURL, encoding: .utf8) else {
        fail("cannot read \(listingURL.path)")
    }
    guard let review = try? String(contentsOf: reviewURL, encoding: .utf8) else {
        fail("cannot read \(reviewURL.path)")
    }
    var kit = ListingKit()
    kit.name = tableValue(field: "App name (ASC)", in: listing) ?? ""
    kit.subtitle = tableValue(field: "Subtitle", in: listing) ?? ""
    kit.privacyPolicyURL = tableValue(field: "Privacy Policy URL", in: listing) ?? ""
    kit.supportURL = tableValue(field: "Support URL", in: listing) ?? ""
    kit.marketingURL = tableValue(field: "Marketing URL", in: listing) ?? ""
    kit.description = fencedBlock(after: "## Description", in: listing) ?? ""
    kit.keywords = fencedBlock(after: "## Keywords", in: listing) ?? ""
    kit.promotionalText = fencedBlock(after: "## Promotional text", in: listing) ?? ""
    kit.whatsNew = fencedBlock(after: "## What's New", in: listing) ?? ""
    kit.reviewNotes = fencedBlock(after: "## Paste-ready reviewer notes", in: review) ?? ""

    // Limits enforced here so a kit edit can't silently 409 the upload.
    func check(_ label: String, _ value: String, _ limit: Int, required: Bool = true) {
        if value.isEmpty { if required { fail("listing kit: \(label) missing/empty") } ; return }
        if value.count > limit {
            fail("listing kit: \(label) is \(value.count) chars (limit \(limit)) — trim the markdown")
        }
    }
    check("name", kit.name, 30)
    check("subtitle", kit.subtitle, 30)
    check("keywords", kit.keywords, 100)
    check("promotional text", kit.promotionalText, 170, required: false)
    check("description", kit.description, 4000)
    check("what's new", kit.whatsNew, 4000, required: false)
    if kit.reviewNotes.count > 4000 {
        warn("review notes are \(kit.reviewNotes.count) chars; ASC caps notes at 4000 — truncating "
            + "at the last paragraph boundary. Trim docs/app-store/review-notes.md to control the cut.")
        var cut = String(kit.reviewNotes.prefix(4000))
        if let lastBreak = cut.range(of: "\n\n", options: .backwards) {
            cut = String(cut[..<lastBreak.lowerBound])
        }
        kit.reviewNotes = cut
    }
    return kit
}

/// Marketing version from project.yml (both targets carry the same value).
func marketingVersion() -> String {
    guard let yml = try? String(contentsOf: repoRoot.appendingPathComponent("project.yml"),
                                encoding: .utf8) else { fail("cannot read project.yml") }
    for line in yml.split(separator: "\n") where line.contains("MARKETING_VERSION:") {
        return line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)
    }
    fail("MARKETING_VERSION not found in project.yml")
}

// --- screenshots ------------------------------------------------------------
/// Verified enum values (ScreenshotDisplayType, fetched 2026-07-10): the API
/// has no APP_IPHONE_69/63 — 67 is the current largest slot, 61 the 6.1/6.3
/// class. Rig slugs (scripts/screenshots.sh) map accordingly. Order matters:
/// longest prefix first so "iphone-17-pro-max" never matches "iphone-17".
let displayTypeMapping: [(slugPrefix: String, displayType: String)] = [
    ("iphone-17-pro-max", "APP_IPHONE_67"),
    ("iphone-17", "APP_IPHONE_61"),
]

struct Shot {
    var url: URL
    var fileName: String
    var fileSize: Int
    var displayType: String
}

func discoverShots() -> [Shot] {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: screenshotsDir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
    var shots: [Shot] = []
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where file.pathExtension.lowercased() == "png" {
        let name = file.lastPathComponent
        guard let mapping = displayTypeMapping.first(where: { name.hasPrefix($0.slugPrefix) }) else {
            warn("no display-type mapping for \(name); skipping")
            continue
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        shots.append(Shot(url: file, fileName: name, fileSize: size,
                          displayType: mapping.displayType))
    }
    return shots
}

// --- credentials + API client ----------------------------------------------
var keyID = "", issuerID = ""
var contact: (first: String, last: String, phone: String, email: String) = ("", "", "", "")
var privateKey: P256.Signing.PrivateKey?

func loadCredentials() {
    let configURL = repoRoot.appendingPathComponent("scripts/asc-config.local")
    guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
        fail("scripts/asc-config.local not found (required for --apply)")
    }
    for line in config.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        switch parts[0] {
        case "ASC_KEY_ID": keyID = parts[1]
        case "ASC_ISSUER_ID": issuerID = parts[1]
        case "ASC_CONTACT_FIRST": contact.first = parts[1]
        case "ASC_CONTACT_LAST": contact.last = parts[1]
        case "ASC_CONTACT_PHONE": contact.phone = parts[1]
        case "ASC_CONTACT_EMAIL": contact.email = parts[1]
        default: break
        }
    }
    guard !keyID.isEmpty, !issuerID.isEmpty else { fail("ASC_KEY_ID/ASC_ISSUER_ID missing") }
    let keyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".appstoreconnect/private_keys/AuthKey_\(keyID).p8")
    guard let pem = try? String(contentsOf: keyPath, encoding: .utf8),
          let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
        fail("cannot read/parse \(keyPath.path)")
    }
    privateKey = key
}

func b64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func makeToken() -> String {
    guard let privateKey else { fail("internal: token requested without credentials") }
    let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#
    let now = Int(Date().timeIntervalSince1970)
    let payload = #"{"iss":"\#(issuerID)","iat":\#(now),"exp":\#(now + 900),"aud":"appstoreconnect-v1"}"#
    let input = b64url(Data(header.utf8)) + "." + b64url(Data(payload.utf8))
    let sig = try! privateKey.signature(for: Data(input.utf8))
    return input + "." + b64url(sig.rawRepresentation)
}

var stepNumber = 0
func announce(_ what: String) {
    stepNumber += 1
    print("[\(apply ? "APPLY" : "PLAN")] \(stepNumber). \(what)")
}

/// One ASC API call. Dry-run prints and returns an empty object — callers
/// substitute placeholder IDs so the printed plan stays complete.
@discardableResult
func call(_ method: String, _ path: String, body: [String: Any]? = nil,
          tolerate404: Bool = false, tolerateFailure: Bool = false,
          describe: String) -> [String: Any] {
    announce("\(describe)\n         \(method) \(path)"
        + (body.map { "\n         body: \(summarize($0))" } ?? ""))
    guard apply else { return [:] }
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
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result = json
        }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    if status == 404, tolerate404 { return [:] }
    guard (200..<300).contains(status) else {
        let errors = (result["errors"] as? [[String: Any]]) ?? []
        let detail = errors.compactMap { $0["detail"] as? String }.joined(separator: "; ")
        let message = "\(method) \(path) -> HTTP \(status): \(detail.isEmpty ? "\(result)" : detail)"
        if tolerateFailure { warn(message + " — continuing (tolerated)"); return [:] }
        fail(message)
    }
    return result
}

func summarize(_ body: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: body),
          var text = String(data: data, encoding: .utf8) else { return "<body>" }
    if text.count > 220 { text = text.prefix(200) + "… (\(text.count) chars)" }
    return text
}

func dataArray(_ response: [String: Any]) -> [[String: Any]] {
    response["data"] as? [[String: Any]] ?? []
}
func dataID(_ response: [String: Any], placeholder: String) -> String {
    ((response["data"] as? [String: Any])?["id"] as? String) ?? "<\(placeholder)>"
}
func firstID(_ response: [String: Any], placeholder: String) -> String? {
    if apply { return dataArray(response).first?["id"] as? String }
    return "<\(placeholder)>"
}

// --- main -------------------------------------------------------------------
let kit = loadListingKit()
let version = marketingVersion()
let shots = skipScreenshots ? [] : discoverShots()

print("""
Dispatch — App Store listing automation (\(apply ? "APPLY" : "DRY-RUN — pass --apply to execute"))
  version:      \(version)
  build:        \(buildNumber ?? "(not attaching — pass --build <n>)")
  screenshots:  \(shots.isEmpty ? (skipScreenshots ? "skipped" : "none found in \(screenshotsDir.path)") : "\(shots.count) file(s)")
  NOTE: this tool NEVER submits for review — that final step is manual, by design.

""")

if apply { loadCredentials() }

// 1. App lookup.
let appResponse = call("GET", "/v1/apps?filter[bundleId]=\(bundleID)",
                       describe: "Resolve app ID for \(bundleID)")
guard let appID = firstID(appResponse, placeholder: "app-id") else { fail("app not found for \(bundleID)") }

// 2. Fetch-or-create the version (idempotent: filter first, POST only on miss).
let versionsResponse = call(
    "GET", "/v1/apps/\(appID)/appStoreVersions?filter[versionString]=\(version)&filter[platform]=IOS",
    describe: "Look up App Store version \(version)")
var versionID: String
if let existing = firstID(versionsResponse, placeholder: "version-id"), apply {
    versionID = existing
    announce("Version \(version) already exists (\(versionID)) — reusing, no duplicate created")
} else if apply {
    let created = call("POST", "/v1/appStoreVersions", body: [
        "data": [
            "type": "appStoreVersions",
            "attributes": ["platform": "IOS", "versionString": version],
            "relationships": ["app": ["data": ["type": "apps", "id": appID]]],
        ],
    ], describe: "Create App Store version \(version)")
    versionID = dataID(created, placeholder: "version-id")
} else {
    versionID = "<version-id>"
    announce("If missing: POST /v1/appStoreVersions (platform IOS, versionString \(version))")
}

// 3. Version localization: fetch en-US, create if absent, then PATCH the copy.
let versionLocalizations = call(
    "GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations",
    describe: "Fetch version localizations")
var versionLocID = "<version-localization-id>"
if apply {
    if let existing = dataArray(versionLocalizations).first(where: {
        (($0["attributes"] as? [String: Any])?["locale"] as? String) == locale
    })?["id"] as? String {
        versionLocID = existing
    } else {
        let created = call("POST", "/v1/appStoreVersionLocalizations", body: [
            "data": [
                "type": "appStoreVersionLocalizations",
                "attributes": ["locale": locale],
                "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionID]]],
            ],
        ], describe: "Create \(locale) version localization")
        versionLocID = dataID(created, placeholder: "version-localization-id")
    }
}
var versionLocAttributes: [String: Any] = [
    "description": kit.description,
    "keywords": kit.keywords,
    "supportUrl": kit.supportURL,
    "marketingUrl": kit.marketingURL,
]
if !kit.promotionalText.isEmpty { versionLocAttributes["promotionalText"] = kit.promotionalText }
call("PATCH", "/v1/appStoreVersionLocalizations/\(versionLocID)", body: [
    "data": ["type": "appStoreVersionLocalizations", "id": versionLocID,
             "attributes": versionLocAttributes],
], describe: "Set \(locale) description/keywords/promotional/support/marketing URLs from listing.md")
if !kit.whatsNew.isEmpty {
    // Separate PATCH: ASC rejects whatsNew on an app's first-ever version
    // ("cannot be edited at this time"), so a combined PATCH would sink the
    // whole localization update. Tolerated — a warning, not a failure.
    call("PATCH", "/v1/appStoreVersionLocalizations/\(versionLocID)", body: [
        "data": ["type": "appStoreVersionLocalizations", "id": versionLocID,
                 "attributes": ["whatsNew": kit.whatsNew]],
    ], tolerateFailure: true,
       describe: "Set \(locale) what's-new from listing.md (tolerated: rejected on a first release)")
}

// 4. App-info localization (name, subtitle, privacy policy URL) + age rating.
//    Apps can carry two appInfos (live + editable); PATCHing the live one
//    409s harmlessly, so try each and stop after the first success.
let appInfos = call("GET", "/v1/apps/\(appID)/appInfos", describe: "Fetch appInfos")
let appInfoIDs = apply ? dataArray(appInfos).compactMap { $0["id"] as? String } : ["<app-info-id>"]
for appInfoID in appInfoIDs {
    let locs = call("GET", "/v1/appInfos/\(appInfoID)/appInfoLocalizations",
                    describe: "Fetch appInfo localizations (\(appInfoID))")
    var infoLocID = "<app-info-localization-id>"
    if apply {
        guard let existing = dataArray(locs).first(where: {
            (($0["attributes"] as? [String: Any])?["locale"] as? String) == locale
        })?["id"] as? String else { continue }
        infoLocID = existing
    }
    call("PATCH", "/v1/appInfoLocalizations/\(infoLocID)", body: [
        "data": ["type": "appInfoLocalizations", "id": infoLocID, "attributes": [
            "name": kit.name,
            "subtitle": kit.subtitle,
            "privacyPolicyUrl": kit.privacyPolicyURL,
        ]],
    ], describe: "Set name/subtitle/privacy-policy URL from listing.md (editable appInfo only; the live one rejects the PATCH)")

    // Age rating: everything None/false per listing.md § Age rating
    // questionnaire (expected 4+). Only the classic questionnaire fields are
    // set; newer declarations (advertising, UGC, health topics …) have ASC
    // semantics the kit doesn't cover — finish those by hand, once.
    let declaration = call("GET", "/v1/appInfos/\(appInfoID)/ageRatingDeclaration",
                           describe: "Fetch age-rating declaration")
    let declarationID = apply ? dataID(declaration, placeholder: "age-rating-id") : "<age-rating-id>"
    call("PATCH", "/v1/ageRatingDeclarations/\(declarationID)", body: [
        "data": ["type": "ageRatingDeclarations", "id": declarationID, "attributes": [
            "alcoholTobaccoOrDrugUseOrReferences": "NONE",
            "contests": "NONE",
            "gambling": false,
            "gamblingSimulated": "NONE",
            "horrorOrFearThemes": "NONE",
            "matureOrSuggestiveThemes": "NONE",
            "medicalOrTreatmentInformation": "NONE",
            "profanityOrCrudeHumor": "NONE",
            "sexualContentGraphicAndNudity": "NONE",
            "sexualContentOrNudity": "NONE",
            "unrestrictedWebAccess": false,
            "violenceCartoonOrFantasy": "NONE",
            "violenceRealistic": "NONE",
            "violenceRealisticProlongedGraphicOrSadistic": "NONE",
        ]],
    ], tolerateFailure: true,
       describe: "Set age-rating declarations (all None/false per listing.md; expected 4+; "
        + "tolerated: ASC may require the newer questionnaire attributes — ageAssurance, "
        + "messagingAndChat, advertising, etc. — which need human answers in ASC)")
    if apply { break } // editable appInfo handled; don't touch the second copy
}

// 5. Screenshots: get-or-create the set per display type, skip files already
//    present (fileName+fileSize match), reserve → PUT chunks → commit (MD5).
if !shots.isEmpty {
    let setsResponse = call(
        "GET", "/v1/appStoreVersionLocalizations/\(versionLocID)/appScreenshotSets",
        describe: "Fetch existing screenshot sets")
    for displayType in displayTypeMapping.map(\.displayType) {
        let shotsForType = shots.filter { $0.displayType == displayType }
        if shotsForType.isEmpty { continue }
        var setID = "<screenshot-set-id:\(displayType)>"
        var existingFiles: Set<String> = []
        if apply {
            if let existing = dataArray(setsResponse).first(where: {
                (($0["attributes"] as? [String: Any])?["screenshotDisplayType"] as? String) == displayType
            })?["id"] as? String {
                setID = existing
            } else {
                let created = call("POST", "/v1/appScreenshotSets", body: [
                    "data": [
                        "type": "appScreenshotSets",
                        "attributes": ["screenshotDisplayType": displayType],
                        "relationships": ["appStoreVersionLocalization":
                            ["data": ["type": "appStoreVersionLocalizations", "id": versionLocID]]],
                    ],
                ], describe: "Create screenshot set \(displayType)")
                setID = dataID(created, placeholder: "screenshot-set-id")
            }
            let existing = call("GET", "/v1/appScreenshotSets/\(setID)/appScreenshots?limit=50",
                                describe: "List existing screenshots in \(displayType)")
            for shot in dataArray(existing) {
                if let attrs = shot["attributes"] as? [String: Any],
                   let name = attrs["fileName"] as? String, let size = attrs["fileSize"] as? Int {
                    existingFiles.insert("\(name):\(size)")
                }
            }
        } else {
            announce("Get-or-create screenshot set \(displayType); skip files already uploaded")
        }
        for shot in shotsForType {
            if existingFiles.contains("\(shot.fileName):\(shot.fileSize)") {
                announce("Skip \(shot.fileName) — already uploaded (same name+size)")
                continue
            }
            let reservation = call("POST", "/v1/appScreenshots", body: [
                "data": [
                    "type": "appScreenshots",
                    "attributes": ["fileName": shot.fileName, "fileSize": shot.fileSize],
                    "relationships": ["appScreenshotSet":
                        ["data": ["type": "appScreenshotSets", "id": setID]]],
                ],
            ], describe: "Reserve upload for \(shot.fileName) (\(shot.fileSize) bytes, \(displayType))")
            let screenshotID = dataID(reservation, placeholder: "screenshot-id")
            guard let fileData = try? Data(contentsOf: shot.url) else { fail("cannot read \(shot.url.path)") }
            if apply {
                let attrs = (reservation["data"] as? [String: Any])?["attributes"] as? [String: Any]
                let operations = attrs?["uploadOperations"] as? [[String: Any]] ?? []
                for op in operations {
                    guard let urlString = op["url"] as? String, let url = URL(string: urlString),
                          let offset = op["offset"] as? Int, let length = op["length"] as? Int else {
                        fail("malformed uploadOperation for \(shot.fileName)")
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = (op["method"] as? String) ?? "PUT"
                    for header in (op["requestHeaders"] as? [[String: String]]) ?? [] {
                        if let name = header["name"], let value = header["value"] {
                            req.setValue(value, forHTTPHeaderField: name)
                        }
                    }
                    req.httpBody = fileData.subdata(in: offset..<(offset + length))
                    let semaphore = DispatchSemaphore(value: 0)
                    var status = 0
                    URLSession.shared.dataTask(with: req) { _, response, _ in
                        status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        semaphore.signal()
                    }.resume()
                    semaphore.wait()
                    guard (200..<300).contains(status) else {
                        fail("chunk upload for \(shot.fileName) (offset \(offset)) -> HTTP \(status)")
                    }
                }
            } else {
                announce("PUT chunk(s) of \(shot.fileName) per uploadOperations (unauthenticated blob URLs)")
            }
            let checksum = Insecure.MD5.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
            call("PATCH", "/v1/appScreenshots/\(screenshotID)", body: [
                "data": ["type": "appScreenshots", "id": screenshotID,
                         "attributes": ["uploaded": true, "sourceFileChecksum": checksum]],
            ], describe: "Commit \(shot.fileName) (MD5 \(checksum))")
        }
    }
}

// 6. Review details (contact from config, notes from review-notes.md).
//    Fetch-then-patch; the to-one relationship 404s before first creation.
let reviewDetail = call("GET", "/v1/appStoreVersions/\(versionID)/appStoreReviewDetail",
                        tolerate404: true, describe: "Fetch review details")
let existingReviewID = (reviewDetail["data"] as? [String: Any])?["id"] as? String
var reviewAttributes: [String: Any] = ["notes": kit.reviewNotes, "demoAccountRequired": false]
if !contact.first.isEmpty { reviewAttributes["contactFirstName"] = contact.first }
if !contact.last.isEmpty { reviewAttributes["contactLastName"] = contact.last }
if !contact.phone.isEmpty { reviewAttributes["contactPhone"] = contact.phone }
if !contact.email.isEmpty { reviewAttributes["contactEmail"] = contact.email }
if apply, contact.email.isEmpty {
    warn("ASC_CONTACT_* keys missing from asc-config.local — review contact left untouched")
}
if apply, existingReviewID == nil {
    call("POST", "/v1/appStoreReviewDetails", body: [
        "data": [
            "type": "appStoreReviewDetails",
            "attributes": reviewAttributes,
            "relationships": ["appStoreVersion":
                ["data": ["type": "appStoreVersions", "id": versionID]]],
        ],
    ], describe: "Create review details (contact + notes from review-notes.md)")
} else {
    let patchID = existingReviewID ?? "<review-detail-id>"
    call("PATCH", "/v1/appStoreReviewDetails/\(patchID)", body: [
        "data": ["type": "appStoreReviewDetails", "id": patchID,
                 "attributes": reviewAttributes],
    ], describe: "Update review details (or POST on first run — contact + notes from review-notes.md)")
}

// 7. Attach the build (optional).
if let buildNumber {
    let builds = call(
        "GET", "/v1/builds?filter[app]=\(appID)&filter[version]=\(buildNumber)&filter[processingState]=VALID",
        describe: "Look up processed build \(buildNumber)")
    guard let buildID = firstID(builds, placeholder: "build-id") else {
        fail("build \(buildNumber) not found or not finished processing")
    }
    call("PATCH", "/v1/appStoreVersions/\(versionID)/relationships/build", body: [
        "data": ["type": "builds", "id": buildID],
    ], describe: "Attach build \(buildNumber) to version \(version)")
}

// 8. Terminal step — BY DESIGN there is no submission call in this tool.
print("""

Done. Listing is staged: ready for manual submission in App Store Connect.
(This tool never submits for review — open App Store Connect, review every
field, complete the newer age-rating questions + App Privacy labels by hand
per docs/app-store/privacy-labels.md, then press Submit yourself.)
""")
