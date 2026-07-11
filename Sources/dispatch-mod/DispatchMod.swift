#if os(macOS)
import DispatchKit
import Foundation

/// `dispatch-mod` — moderation CLI for the Dispatch community question
/// catalog (plan 20). Talks to CloudKit Web Services with a server-to-server
/// key; the ONLY writer of `CatalogQuestion` records anywhere in the project.
@main
struct DispatchMod {
    static let helpText = """
    dispatch-mod — moderate the Dispatch community question catalog

    USAGE: dispatch-mod <subcommand> [options]

    SUBCOMMANDS:
      list                     Pending submissions and open flags, with a
                               per-submitter summary (⚠️ FLOOD above the
                               threshold — see --flood-threshold); duplicates
                               of catalog entries or older pending submissions
                               are marked ⚠️ DUPLICATE
      approve <recordName>     Copy a submission into the catalog, then delete it
                               (--tags a,b to attach catalog tags). Refuses
                               duplicates of existing catalog entries unless
                               --allow-duplicate is passed.
      reject <recordName>      Delete a submission without publishing
      reject-user <user>       Delete ALL pending submissions from one creator
                               (userRecordName from `list`). Prints them and
                               asks for confirmation; --yes to skip. Never
                               touches approved catalog entries.
      backfill-fingerprints    Stamp promptFingerprint onto catalog entries
                               that lack it (pre-plan-42 records; safe to
                               re-run)
      serve                    Localhost dashboard (--port N, default 8787)
      import <seed.json>       Bulk-load a curated seed file into the catalog
                               (--dry-run to validate and preview only; prompts
                               already in the catalog are skipped, so re-runs
                               are safe — see docs/catalog/README.md)
      setup                    Bootstrap a CloudKit environment: import the
                               repo-canonical schema.ckdb via `xcrun cktool`
                               (types, indexes, roles; Development only —
                               Production schema deploys via the Console),
                               verify with probes, print remaining manual steps
                               (--export to snapshot the live schema instead;
                               see `dispatch-mod setup --help`)
      help                     Show this help

    OPTIONS:
      --env development|production   CloudKit environment (default development)
      --tags a,b,c                   approve only: comma-separated tags
      --allow-duplicate              approve only: publish despite a duplicate
      --port N                       serve only: listen port (127.0.0.1 only)
      --dry-run                      import only: no network, no writes
      --flood-threshold N            list only: pending submissions per creator
                                     before the ⚠️ FLOOD marker (default 10)
      --yes                          reject-user only: skip confirmation

    CONFIG (key NEVER lives in the repo — see docs/moderation.md):
      ~/.dispatch-mod/config.json    {"keyID": "...", "keyPath": "...",
                                      "container": "...", "environment": "..."}
      ~/.dispatch-mod/eckey.pem      EC (prime256v1) private key from Console
      Env overrides: DISPATCH_MOD_KEY_ID, DISPATCH_MOD_KEY_PATH,
                     DISPATCH_MOD_CONTAINER, DISPATCH_MOD_ENV
    """

    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let subcommand = arguments.first, subcommand != "--help", subcommand != "-h",
              subcommand != "help" else {
            print(helpText)
            return
        }
        arguments.removeFirst()

        let envOverride = optionValue("--env", in: &arguments)
        do {
            switch subcommand {
            case "list":
                let floodThreshold = Int(optionValue("--flood-threshold", in: &arguments) ?? "")
                    ?? defaultFloodThreshold
                try run(envOverride) { client in
                    let pending = try client.pendingSubmissions()
                    // Plan 42: mark content duplicates (normalized-prompt
                    // identity) against the catalog and within the queue.
                    let duplicates = CatalogDedupe.duplicateMatches(
                        pending: pending, catalog: (try? client.catalogQuestions()) ?? []
                    )
                    print("Pending submissions (\(pending.count)):")
                    for submission in pending {
                        let type = QuestionType(rawValue: submission.typeRaw)
                            .map(String.init(describing:)) ?? "unknown(\(submission.typeRaw))"
                        var line = "  \(submission.recordName)  [\(type)]  \(submission.prompt)"
                        if !submission.choices.isEmpty {
                            line += "  {\(submission.choices.joined(separator: " | "))}"
                        }
                        if let credit = submission.creditName { line += "  — \(credit)" }
                        switch duplicates[submission.recordName] {
                        case .catalogEntry(let recordName):
                            line += "  ⚠️ DUPLICATE of \(recordName)"
                        case .pendingSubmission(let recordName):
                            line += "  ⚠️ DUPLICATE of pending \(recordName)"
                        case nil:
                            break
                        }
                        print(line)
                    }
                    // Plan 38 flood detection: group by CloudKit's creator
                    // metadata, client-side over the full pending fetch. The
                    // per-device throttle is bypassable friction; THIS is
                    // where a scripted flood actually gets caught.
                    if !pending.isEmpty {
                        print("Submitters:")
                        for (user, count) in submitterCounts(pending) {
                            var line = "  \(user)  ×\(count)"
                            if count > floodThreshold {
                                line += "  ⚠️ FLOOD (>\(floodThreshold) pending — "
                                    + "`dispatch-mod reject-user \(user)` to bulk-clean)"
                            }
                            print(line)
                        }
                    }
                    let flags = try client.flags()
                    print("Open flags (\(flags.count)):")
                    for flag in flags {
                        print("  \(flag.recordName)  on \(flag.catalogRecordName): \(flag.reason)")
                    }
                }
            case "approve":
                let tags = (optionValue("--tags", in: &arguments) ?? "")
                    .split(separator: ",").map(String.init)
                let allowDuplicate = flag("--allow-duplicate", in: &arguments)
                guard let recordName = arguments.first else {
                    fail("approve needs a submission recordName (see `dispatch-mod list`)")
                }
                try run(envOverride) { client in
                    let catalog = try client.approve(
                        submissionRecordName: recordName, tags: tags,
                        allowDuplicate: allowDuplicate
                    )
                    print("Approved → CatalogQuestion \(catalog.recordName): \(catalog.prompt)")
                }
            case "reject":
                guard let recordName = arguments.first else {
                    fail("reject needs a submission recordName (see `dispatch-mod list`)")
                }
                try run(envOverride) { client in
                    try client.reject(submissionRecordName: recordName)
                    print("Rejected (deleted) \(recordName)")
                }
            case "reject-user":
                // Bulk cleanup for a flooding creator (plan 38). Destructive,
                // so it prints the full list and confirms; deletes one by one
                // with per-record verification (never trust an unverified
                // batch success — the plan-20 lesson). Only ever touches
                // SubmittedQuestion: approved catalog entries are outside the
                // moderation queue by construction.
                let skipConfirmation = flag("--yes", in: &arguments)
                guard let user = arguments.first else {
                    fail("reject-user needs a creator userRecordName (see `dispatch-mod list`)")
                }
                try run(envOverride) { client in
                    let pending = try client.pendingSubmissions()
                        .filter { $0.createdUserRecordName == user }
                    guard !pending.isEmpty else {
                        print("No pending submissions from \(user). "
                            + "(Queries lag writes — see docs/moderation.md on eventual consistency.)")
                        return
                    }
                    print("Pending submissions from \(user) (\(pending.count)):")
                    for submission in pending {
                        print("  \(submission.recordName)  \(submission.prompt)")
                    }
                    if !skipConfirmation {
                        print("Delete ALL \(pending.count) submission(s) from \(user)? [y/N] ", terminator: "")
                        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
                        guard answer == "y" || answer == "yes" else {
                            print("Aborted — nothing deleted.")
                            return
                        }
                    }
                    var deleted = 0
                    for submission in pending {
                        try client.reject(submissionRecordName: submission.recordName)
                        deleted += 1
                        print("  − \(submission.recordName)")
                    }
                    print("Rejected \(deleted) submission(s) from \(user).")
                }
            case "serve":
                let port = UInt16(optionValue("--port", in: &arguments) ?? "") ?? 8787
                try run(envOverride) { client in
                    try Dashboard(client: client, port: port).serve()
                }
            case "catalog":
                try run(envOverride) { client in
                    let entries = try client.catalogEntries()
                    print("Catalog entries (\(entries.count)):")
                    for entry in entries {
                        let prompt = entry.fields["prompt"]?.stringValue ?? "?"
                        print("  \(entry.recordName)  \(prompt)")
                    }
                }
            case "whoami":
                // Diagnostic: creates and immediately deletes a probe
                // SubmittedQuestion to learn the server key's user record
                // name (needed to assign it a custom security role).
                try run(envOverride) { client in
                    print(try client.serverUserRecordName())
                }
            case "lookup":
                // Strongly-consistent fetch by recordName (any record type) —
                // diagnostic for eventual-consistency confusion in queries and
                // the Console UI. Prints the raw record dictionary.
                guard let recordName = arguments.first else {
                    fail("lookup needs a recordName")
                }
                try run(envOverride) { client in
                    let raw = try client.rawLookup(recordName: recordName)
                    print(raw)
                }
            case "backfill-fingerprints":
                try run(envOverride) { client in
                    let result = try client.backfillFingerprints { entry in
                        print("  + \(entry.recordName)  \(entry.prompt)")
                    }
                    print("Stamped \(result.stamped) entr\(result.stamped == 1 ? "y" : "ies"); "
                        + "\(result.alreadyStamped) already had fingerprints.")
                }
            case "setup":
                if arguments.contains("--help") || arguments.contains("-h") {
                    print(Setup.helpText)
                    return
                }
                try Setup.run(
                    environmentOverride: envOverride,
                    export: flag("--export", in: &arguments),
                    strict: flag("--strict", in: &arguments)
                )
            case "import":
                let dryRun = flag("--dry-run", in: &arguments)
                guard let path = arguments.first else {
                    fail("import needs a seed file path (see docs/catalog/README.md)")
                }
                let drafts = try CatalogSeed.parse(Data(contentsOf: URL(fileURLWithPath: path)))
                if dryRun {
                    print("Seed file OK — \(drafts.count) question(s):")
                    for draft in drafts { print("  " + describe(draft)) }
                    print("Dry run — nothing written.")
                    return
                }
                try run(envOverride) { client in
                    // Plan 42: skip-set keys on the shared dedupe
                    // normalization (case + whitespace + trailing
                    // punctuation), same identity the approve path enforces.
                    let existing = Set(try client.catalogQuestions()
                        .map { CatalogDedupe.normalizedPrompt($0.prompt) })
                    let new = drafts.filter {
                        !existing.contains(CatalogDedupe.normalizedPrompt($0.prompt))
                    }
                    if new.count < drafts.count {
                        print("Skipping \(drafts.count - new.count) question(s) already in the catalog.")
                    }
                    // The catalog sorts approvedAt descending; stagger the
                    // timestamps so file order is preserved, first entry newest.
                    let base = Date()
                    let questions = new.enumerated().map { index, draft in
                        draft.catalogQuestion(
                            recordName: UUID().uuidString,
                            approvedAt: base.addingTimeInterval(-Double(index))
                        )
                    }
                    try client.createCatalogQuestions(questions) { created in
                        print("  + \(created.prompt)")
                    }
                    print("Imported \(questions.count) question(s).")
                }
            default:
                fail("Unknown subcommand \"\(subcommand)\".\n\n\(helpText)")
            }
        } catch {
            fail("\(error)")
        }
    }

    /// Flood marker threshold (plan 38): twice the client-side daily cap, so
    /// a legitimate reinstall/multi-device user never trips it and a script
    /// does immediately. `--flood-threshold N` overrides per invocation.
    static let defaultFloodThreshold = 10

    /// Pending-submission counts per creator, most prolific first. Creator
    /// metadata should always be present on queried records; a missing one
    /// (defensive) groups under "(unknown)".
    static func submitterCounts(_ pending: [SubmittedQuestion]) -> [(user: String, count: Int)] {
        var counts: [String: Int] = [:]
        for submission in pending {
            counts[submission.createdUserRecordName ?? "(unknown)", default: 0] += 1
        }
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { (user: $0.key, count: $0.value) }
    }

    private static func run(_ envOverride: String?, _ body: (CloudKitWebClient) throws -> Void) throws {
        let config = try ModConfig.load(environmentOverride: envOverride)
        let client = CloudKitWebClient(
            signer: try config.makeSigner(),
            container: config.container,
            environment: config.environment
        )
        if config.environment == "production" {
            print("⚠️  Operating on the PRODUCTION environment.")
        }
        try body(client)
    }

    private static func describe(_ draft: CatalogSeedDraft) -> String {
        let type = QuestionType(rawValue: draft.typeRaw)
            .map(String.init(describing:)) ?? "unknown(\(draft.typeRaw))"
        var line = "[\(type)] \(draft.prompt)"
        if !draft.choices.isEmpty { line += "  {\(draft.choices.joined(separator: " | "))}" }
        if !draft.tags.isEmpty { line += "  #\(draft.tags.joined(separator: " #"))" }
        if let credit = draft.credit { line += "  — \(credit)" }
        return line
    }

    private static func flag(_ name: String, in arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }

    private static func optionValue(_ name: String, in arguments: inout [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}
#else
@main
struct DispatchMod {
    static func main() {
        // dispatch-mod is a macOS-only moderation tool; never part of iOS builds.
    }
}
#endif
