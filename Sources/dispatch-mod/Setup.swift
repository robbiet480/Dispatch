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
///   - Schema import/validate against PRODUCTION: rejected by the service
///     ("endpoint not applicable in the environment 'production'", verified
///     empirically 2026-07-09). NOT EXPRESSIBLE — promotion is Console-only
///     via "Deploy Schema Changes" (docs/moderation.md §3c).
///   - `cktool reset-schema` exists but is destructive (wipes Development
///     data); setup never invokes it.
enum Setup {
    static let helpText = """
    dispatch-mod setup — bootstrap a CloudKit environment for the question catalog

    USAGE: dispatch-mod setup [--env development|production] [--export] [--strict]

    Imports Sources/dispatch-mod/schema.ckdb (record types, indexes — including
    the ___createdBy/createdUserRecordName queryable index — the moderator
    security role and all grants) into the environment via `xcrun cktool`,
    verifies with read probes through the server-to-server key, then prints
    the remaining manual steps (management-token minting and the per-environment
    moderator role→user assignment, which no CloudKit tooling can automate).

    Schema import applies to DEVELOPMENT only: Production rejects cktool
    schema import/validate ("endpoint not applicable in the environment
    'production'"). `--env production` therefore skips the import and prints
    the Console-only promotion step (Deploy Schema Changes → Production,
    docs/moderation.md §3c); the verification probes and checklist still run.

    The schema file is resolved relative to this source file (via #filePath),
    so setup must run from a source checkout (e.g. `swift run dispatch-mod setup`).

    OPTIONS:
      --env development|production   Target environment (default development)
      --export                       Instead of importing, snapshot the
                                     environment's CURRENT schema over
                                     Sources/dispatch-mod/schema.ckdb (requires
                                     a management token; never destructive)
      --strict                       Exit nonzero if ANY verification probe
                                     fails, even failures that are expected
                                     before the moderator role→user assignment
                                     (unexpected probe failures always exit
                                     nonzero)

    REQUIREMENTS:
      - Xcode with cktool (`xcrun cktool version`)
      - A CloudKit MANAGEMENT token for schema import/export
        (setup detects absence and prints minting instructions)
      - The server-to-server key (~/.dispatch-mod/) for verification probes

    Setup never runs `cktool reset-schema` and never deletes records. NOTE:
    `cktool import-schema` replaces the environment's WHOLE schema with the
    file's contents, so schema.ckdb must contain every record type in the
    container (CloudKit refuses imports that would drop types active in
    Production; run `setup --export` to snapshot the full live schema first).
    """

    /// Repo-canonical schema file, located relative to this source file so
    /// `swift run dispatch-mod setup` works from any cwd inside the checkout.
    static var schemaURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("schema.ckdb")
    }

    static func run(environmentOverride: String?, export: Bool, strict: Bool = false) throws {
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
            let detail = teams.output.trimmingCharacters(in: .whitespacesAndNewlines)
            print("✗ No CloudKit management token — schema \(export ? "export" : "import") skipped")
            if !detail.isEmpty {
                // Surface cktool's own words so a network/auth failure is not
                // misdiagnosed as a missing token.
                print("    cktool get-teams (exit \(teams.status)): \(detail)")
            }
        }

        var schemaApplied = false
        if haveToken, environment == "production", !export {
            // Verified empirically 2026-07-09: Production rejects cktool
            // schema import/validate with "endpoint not applicable in the
            // environment 'production'". Promotion is Console-only.
            print("""
            ~ Schema import skipped: cktool cannot import or validate schema against
              Production. Promote the Development schema in the Console instead:
                CloudKit Console → \(container) → Development → Schema →
                Deploy Schema Changes → Production   (docs/moderation.md §3c)
              The verification probes and checklist below still apply to production.
            """)
        } else if haveToken {
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
                var output = importResult.output
                if output.contains("delete a record type") {
                    // Discovered on the real container 2026-07-09:
                    // import-schema REPLACES the environment's schema with the
                    // file's contents, so record types missing from the file
                    // are scheduled for deletion (CloudKit refuses when they
                    // are active in Production).
                    output += """

                    schema.ckdb does not contain every record type in this container.
                    Snapshot the live schema first, merge, and retry:
                        swift run dispatch-mod setup --export
                    """
                }
                throw SetupError.cktool("import-schema", output)
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
        var unexpectedProbeFailures = 0
        var expectedProbeFailures = 0
        if let config {
            let client = CloudKitWebClient(
                signer: try config.makeSigner(),
                container: config.container,
                environment: environment
            )
            // The server key is role-bound, not a superuser: until the Console
            // moderator role→user assignment (checklist below), creator-scoped
            // reads make the SubmittedQuestion/QuestionFlag probes fail on a
            // fresh environment. That is expected and does NOT mean the schema
            // import broke.
            let roleHint = "expected on a fresh environment until the moderator "
                + "role→user assignment (see checklist below)"
            if !probe("CatalogQuestion query (recordName queryable + approvedAt sortable)", {
                _ = try client.catalogEntries()
            }) {
                unexpectedProbeFailures += 1
            }
            if !probe("SubmittedQuestion query (___createdBy queryable + submittedAt sortable)",
                      expectedFailureHint: roleHint, {
                _ = try client.pendingSubmissions()
            }) {
                expectedProbeFailures += 1
            }
            if !probe("QuestionFlag query (___createdBy queryable + flaggedAt sortable)",
                      expectedFailureHint: roleHint, {
                _ = try client.flags()
            }) {
                expectedProbeFailures += 1
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

        if unexpectedProbeFailures > 0 {
            throw SetupError.plain(
                "\(unexpectedProbeFailures) verification probe(s) failed unexpectedly (see ✗ lines above).")
        }
        if strict, expectedProbeFailures > 0 {
            throw SetupError.plain("""
            --strict: \(expectedProbeFailures) probe(s) failed. If the moderator \
            role→user assignment is done, this is a real failure; otherwise re-run \
            after completing the checklist.
            """)
        }
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
            if environment == "production" {
                item("""
                Deploy the schema to Production via the Console (cktool cannot —
                     import/validate-schema are rejected in Production):
                       CloudKit Console → \(container) → Development → Schema →
                       Deploy Schema Changes → Production   (docs/moderation.md §3c)
                """)
            } else {
                item("""
                Schema not imported this run. Until it is, follow the manual Console
                     checklist in docs/moderation.md §2–§3 (record types, permission
                     matrix, indexes — including createdUserRecordName).
                """)
            }
        }
        if environment == "production" {
            item("""
            Register the server key's PUBLIC key in Production (key registrations
                 are PER ENVIRONMENT — the Development key ID returns
                 AUTHENTICATION_FAILED against Production, and the Production
                 registration yields a DIFFERENT key ID):
                   CloudKit Console → \(container) → Production →
                   Server-to-Server Keys → ＋, paste the public half of the
                   same private key:
                     openssl ec -in ~/.dispatch-mod/eckey.pem -pubout
                   then save the new key ID as "keyIDProduction" in
                   ~/.dispatch-mod/config.json (or export DISPATCH_MOD_KEY_ID
                   for one-off runs).
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
            Production bootstrap, when ready (schema promotion is Console-only —
                 cktool cannot import/validate schema against Production):
                 a. CloudKit Console → \(container) → Development → Schema →
                    Deploy Schema Changes → Production   (docs/moderation.md §3c)
                 b. register the same s2s public key under Production (key
                    registrations are per-environment; the new key ID goes in
                    "keyIDProduction" in ~/.dispatch-mod/config.json):
                      openssl ec -in ~/.dispatch-mod/eckey.pem -pubout
                 c. swift run dispatch-mod setup --env production
                    (verification probes + this checklist for production)
                 d. repeat the moderator role→user assignment there (the key's
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

    /// Runs a verification probe. Returns true on success. On failure, prints
    /// the error plus `expectedFailureHint` (when given) so pre-role-assignment
    /// failures aren't misread as a broken schema import.
    @discardableResult
    private static func probe(
        _ label: String,
        expectedFailureHint: String? = nil,
        _ body: () throws -> Void
    ) -> Bool {
        do {
            try body()
            print("✓ probe OK: \(label)")
            return true
        } catch {
            print("✗ probe FAILED: \(label)\n    \(error)")
            if let expectedFailureHint {
                print("    (\(expectedFailureHint))")
            }
            return false
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
