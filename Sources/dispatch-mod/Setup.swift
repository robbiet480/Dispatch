#if os(macOS)
import DispatchKit
import Foundation

/// `dispatch-mod setup` — one-command CloudKit environment bootstrap.
///
/// Drives `xcrun cktool` to import the repo-canonical schema
/// (`Sources/dispatch-mod/schema.ckdb`) into the requested environment,
/// verifies the result with the same list-shaped probes the moderation
/// commands use, then prints the manual steps that CloudKit tooling
/// cannot express.
///
/// Expressibility findings (2026-07-09; cktool grammar cross-checked
/// against apple/sample-cloudkit-tooling and real `cktool export-schema`
/// output — see docs/moderation.md "Automated setup"):
///   - Field indexes: `QUERYABLE` / `SORTABLE` / `SEARCHABLE` annotations
///     directly after the field type. EXPRESSIBLE.
///   - The creator-metadata index trap: the schema language spells the field
///     `"___createdBy" REFERENCE QUERYABLE` (the Console UI calls it
///     `createdUserRecordName`, server errors call it `createdBy`). EXPRESSIBLE.
///   - Custom security roles + grants: `CREATE ROLE moderator;` and
///     `GRANT CREATE, WRITE TO moderator`. EXPRESSIBLE.
///   - Role → USER assignment: appears nowhere in the grammar or any known
///     export. NOT EXPRESSIBLE — Console only, once per environment.
///   - `cktool reset-schema` exists but is destructive (wipes Development
///     data); setup never invokes it.
enum Setup {
    static let helpText = """
    dispatch-mod setup — bootstrap a CloudKit environment for the question catalog

    USAGE: dispatch-mod setup [--env development|production] [--export]

    Imports Sources/dispatch-mod/schema.ckdb (record types, indexes — including
    the ___createdBy/createdUserRecordName queryable index — the moderator
    security role and all grants) into the environment via `xcrun cktool`,
    verifies with read probes through the server-to-server key, then prints
    the remaining manual steps (management-token minting and the per-environment
    moderator role→user assignment, which no CloudKit tooling can automate).

    OPTIONS:
      --env development|production   Target environment (default development)
      --export                       Instead of importing, snapshot the
                                     environment's CURRENT schema over
                                     Sources/dispatch-mod/schema.ckdb (requires
                                     a management token; never destructive)

    REQUIREMENTS:
      - Xcode with cktool (`xcrun cktool version`)
      - A CloudKit MANAGEMENT token for schema import/export
        (setup detects absence and prints minting instructions)
      - The server-to-server key (~/.dispatch-mod/) for verification probes

    Setup is idempotent and additive-only: it never runs `cktool reset-schema`
    and never deletes records.
    """

    /// Repo-canonical schema file, located relative to this source file so
    /// `swift run dispatch-mod setup` works from any cwd inside the checkout.
    static var schemaURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("schema.ckdb")
    }

    static func run(environmentOverride: String?, export: Bool) throws {
        // Config is optional for the cktool half (container/team have
        // defaults); the s2s key is only needed for verification probes.
        let config = try? ModConfig.load(environmentOverride: environmentOverride)
        let environment = try validatedEnvironment(
            environmentOverride ?? config?.environment ?? "development")
        let container = config?.container ?? ModConfig.defaultContainer
        let teamID = config?.teamID ?? ModConfig.defaultTeamID

        print("dispatch-mod setup — container \(container), environment \(environment), team \(teamID)")
        if environment == "production" {
            print("⚠️  Operating on the PRODUCTION environment.")
        }

        // 1. cktool availability.
        let version = cktool(["version"])
        guard version.status == 0 else {
            throw SetupError.plain("""
            `xcrun cktool` is unavailable. Install/select a full Xcode (13+):
              sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
            """)
        }
        print("✓ cktool available (\(version.output.trimmingCharacters(in: .whitespacesAndNewlines)))")

        // 2. Management token detection (get-teams is the cheapest
        //    token-requiring call and touches no container).
        let teams = cktool(["get-teams"])
        let haveToken = teams.status == 0
        if haveToken {
            print("✓ CloudKit management token found")
        } else {
            print("✗ No CloudKit management token — schema \(export ? "export" : "import") skipped")
        }

        var schemaApplied = false
        if haveToken {
            let common = [
                "--team-id", teamID,
                "--container-id", container,
                "--environment", environment,
            ]
            if export {
                let result = cktool(["export-schema"] + common + ["--output-file", schemaURL.path])
                guard result.status == 0 else {
                    throw SetupError.cktool("export-schema", result.output)
                }
                print("✓ Exported current \(environment) schema → \(schemaURL.path)")
                print("  Review the diff and commit it — this file is the canonical schema.")
                return
            }
            guard FileManager.default.fileExists(atPath: schemaURL.path) else {
                throw SetupError.plain("schema file missing at \(schemaURL.path)")
            }
            let validate = cktool(["validate-schema"] + common + ["--file", schemaURL.path])
            guard validate.status == 0 else {
                throw SetupError.cktool("validate-schema", validate.output)
            }
            print("✓ Schema validated against \(environment)")
            let importResult = cktool(["import-schema"] + common + ["--file", schemaURL.path])
            guard importResult.status == 0 else {
                throw SetupError.cktool("import-schema", importResult.output)
            }
            schemaApplied = true
            print("✓ Schema imported into \(environment) (types, indexes, roles, grants)")
        } else if export {
            print("Cannot export without a management token (instructions below).")
        }

        // 3. Verification probes via the server-to-server key: the same
        //    list queries the moderation commands use. These exercise the
        //    queryable ___recordID indexes, the sortable timestamp indexes,
        //    and — because the s2s identity is subject to creator-scoped
        //    reads until the moderator role is assigned — surface the
        //    "Field 'createdBy' is not marked queryable" trap if the
        //    ___createdBy index is missing.
        var serverUser: String?
        if let config {
            let client = CloudKitWebClient(
                signer: try config.makeSigner(),
                container: config.container,
                environment: environment
            )
            probe("CatalogQuestion query (recordName queryable + approvedAt sortable)") {
                _ = try client.catalogEntries()
            }
            probe("SubmittedQuestion query (___createdBy queryable + submittedAt sortable)") {
                _ = try client.pendingSubmissions()
            }
            probe("QuestionFlag query (___createdBy queryable + flaggedAt sortable)") {
                _ = try client.flags()
            }
            serverUser = try? client.serverUserRecordName()
        } else {
            print("~ Verification probes skipped — no server-to-server key configured (docs/moderation.md §1)")
        }

        printChecklist(
            haveToken: haveToken,
            schemaApplied: schemaApplied,
            environment: environment,
            container: container,
            serverUser: serverUser
        )
    }

    // MARK: - Manual-steps checklist

    private static func printChecklist(
        haveToken: Bool,
        schemaApplied: Bool,
        environment: String,
        container: String,
        serverUser: String?
    ) {
        print("\nRemaining manual steps (things cktool cannot do):")
        var step = 1
        func item(_ text: String) {
            print("\n\(step). \(text)")
            step += 1
        }

        if !haveToken {
            item("""
            Mint a CloudKit MANAGEMENT token (needed for schema import/export):
                 CloudKit Console (https://icloud.developer.apple.com/dashboard/account/tokens)
                 → Tokens & Keys → Management Tokens → ＋, then save it locally:
                   xcrun cktool save-token --type management
                 (keychain by default; or export CLOUDKIT_MANAGEMENT_TOKEN)
                 Then re-run: swift run dispatch-mod setup --env \(environment)
            """)
        }
        if !schemaApplied {
            item("""
            Schema not imported this run. Until it is, follow the manual Console
                 checklist in docs/moderation.md §2–§3 (record types, permission
                 matrix, indexes — including createdUserRecordName).
            """)
        }
        let identity = serverUser.map { "user record name: \($0)" }
            ?? "run `swift run dispatch-mod whoami --env \(environment)` to get the user record name"
        item("""
        Assign the `moderator` role to the server key's user (NOT automatable —
             the .ckdb grammar has no role→user statement; assignment is
             per-environment and does not deploy with the schema):
               CloudKit Console → \(container) → \(environment) → Schema →
               Security Roles → moderator → assign the key's user
               (\(identity)).
        """)
        item("""
        Verify the permission matrix from a SECOND Apple ID (owner accounts can
             have elevated access): a Development build signed into another
             account must NOT be able to read SubmittedQuestion records
             (docs/moderation.md §3a).
        """)
        if environment == "development" {
            item("""
            Production bootstrap, when ready:
                 swift run dispatch-mod setup --env production
                 then repeat the moderator role→user assignment there (the key's
                 identity may DIFFER per environment — re-run whoami with
                 --env production).
            """)
        }
        print("""

        Verify end-to-end: `swift run dispatch-mod list --env \(environment)` (empty
        listing = signature + indexes OK), then approve a test submission and
        confirm with `swift run dispatch-mod catalog --env \(environment)`.
        """)
    }

    // MARK: - Helpers

    private static func probe(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
            print("✓ probe OK: \(label)")
        } catch {
            print("✗ probe FAILED: \(label)\n    \(error)")
        }
    }

    private static func validatedEnvironment(_ value: String) throws -> String {
        guard value == "development" || value == "production" else {
            throw SetupError.plain("Invalid environment \"\(value)\" — use development or production.")
        }
        return value
    }

    /// Runs `xcrun cktool <args>`, capturing interleaved stdout+stderr.
    private static func cktool(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["cktool"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (127, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    enum SetupError: Error, CustomStringConvertible {
        case plain(String)
        case cktool(String, String)

        var description: String {
            switch self {
            case .plain(let message):
                message
            case .cktool(let subcommand, let output):
                "cktool \(subcommand) failed:\n\(output)"
            }
        }
    }
}
#endif
