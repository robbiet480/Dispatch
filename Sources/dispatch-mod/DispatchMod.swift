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
      list                     Pending submissions and open flags
      approve <recordName>     Copy a submission into the catalog, then delete it
                               (--tags a,b to attach catalog tags)
      reject <recordName>      Delete a submission without publishing
      serve                    Localhost dashboard (--port N, default 8787)
      help                     Show this help

    OPTIONS:
      --env development|production   CloudKit environment (default development)
      --tags a,b,c                   approve only: comma-separated tags
      --port N                       serve only: listen port (127.0.0.1 only)

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
                try run(envOverride) { client in
                    let pending = try client.pendingSubmissions()
                    print("Pending submissions (\(pending.count)):")
                    for submission in pending {
                        let type = QuestionType(rawValue: submission.typeRaw)
                            .map(String.init(describing:)) ?? "unknown(\(submission.typeRaw))"
                        var line = "  \(submission.recordName)  [\(type)]  \(submission.prompt)"
                        if !submission.choices.isEmpty {
                            line += "  {\(submission.choices.joined(separator: " | "))}"
                        }
                        if let credit = submission.creditName { line += "  — \(credit)" }
                        print(line)
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
                guard let recordName = arguments.first else {
                    fail("approve needs a submission recordName (see `dispatch-mod list`)")
                }
                try run(envOverride) { client in
                    let catalog = try client.approve(submissionRecordName: recordName, tags: tags)
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
            case "serve":
                let port = UInt16(optionValue("--port", in: &arguments) ?? "") ?? 8787
                try run(envOverride) { client in
                    try Dashboard(client: client, port: port).serve()
                }
            default:
                fail("Unknown subcommand \"\(subcommand)\".\n\n\(helpText)")
            }
        } catch {
            fail("\(error)")
        }
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
