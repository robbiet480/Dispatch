#if os(macOS)
import DispatchKit
import Foundation

/// Configuration for the moderation tool. The server-to-server key is a
/// user-created credential and NEVER lives in the repo: it is read from
/// `~/.dispatch-mod/` or from environment variables at runtime.
///
/// Resolution order (env wins over file):
///   - `DISPATCH_MOD_KEY_ID`      — key ID from CloudKit Console (quick
///     override path; wins for ANY environment)
///   - `DISPATCH_MOD_KEY_PATH`    — path to the EC private key PEM
///   - `DISPATCH_MOD_CONTAINER`   — container ID (default iCloud.io.robbie.Dispatch)
///   - `DISPATCH_MOD_ENV`         — `development` (default) or `production`
///   - `~/.dispatch-mod/config.json` — {"keyID": "...", "keyIDProduction": "...",
///     "keyPath": "...", "container": "...", "environment": "..."}; keyPath
///     defaults to `~/.dispatch-mod/eckey.pem`.
///
/// Per-environment key IDs (verified live 2026-07-09): server-to-server
/// public keys are registered PER ENVIRONMENT in the Console, and each
/// registration gets its own key ID — the Development key ID returns
/// AUTHENTICATION_FAILED against Production until the same public key is
/// registered under Production. `keyIDProduction` holds the Production
/// registration's key ID and falls back to `keyID` when absent; the private
/// key (`keyPath`) is the same PEM for both.
struct ModConfig {
    static let defaultContainer = "iCloud.io.robbie.Dispatch"
    /// Apple Developer team that owns the container — only used by `setup`
    /// for `cktool` schema import/export (`DISPATCH_MOD_TEAM_ID` / "teamID"
    /// in config.json override).
    static let defaultTeamID = "UTQFCBPQRF"
    static let configDirectory = ("~/.dispatch-mod" as NSString).expandingTildeInPath

    var keyID: String
    var keyPath: String
    var container: String
    var environment: String
    var teamID: String

    struct ConfigFile: Decodable {
        var keyID: String?
        /// Key ID of the SAME public key registered under Production
        /// (registrations are per-environment). Falls back to `keyID`.
        var keyIDProduction: String?
        var keyPath: String?
        var container: String?
        var environment: String?
        var teamID: String?
    }

    enum ConfigError: Error, CustomStringConvertible {
        case missing(String)
        case badEnvironment(String)
        case unreadableKey(String)

        var description: String {
            switch self {
            case .missing(let what):
                """
                Missing \(what).

                dispatch-mod needs a CloudKit server-to-server key. Setup:
                  1. CloudKit Console → your container → Settings → Tokens & Keys →
                     create a Server-to-Server Key (see docs/moderation.md).
                  2. mkdir -p ~/.dispatch-mod && chmod 700 ~/.dispatch-mod
                  3. Save the private key as ~/.dispatch-mod/eckey.pem (chmod 600).
                  4. Write ~/.dispatch-mod/config.json:
                       {"keyID": "<key id from Console>"}
                     (container defaults to \(ModConfig.defaultContainer),
                      environment defaults to development).
                     Key registrations are PER ENVIRONMENT: for production,
                     register the same public key under Production too and add
                     its key ID as "keyIDProduction" (falls back to "keyID").
                Environment variables DISPATCH_MOD_KEY_ID / DISPATCH_MOD_KEY_PATH /
                DISPATCH_MOD_CONTAINER / DISPATCH_MOD_ENV override the file.
                """
            case .badEnvironment(let value):
                "Invalid environment \"\(value)\" — use development or production."
            case .unreadableKey(let path):
                "Couldn't read the private key at \(path). Check the path and permissions (chmod 600)."
            }
        }
    }

    static func load(
        env: [String: String] = ProcessInfo.processInfo.environment,
        environmentOverride: String? = nil
    ) throws -> ModConfig {
        let fileURL = URL(fileURLWithPath: configDirectory).appendingPathComponent("config.json")
        var file = ConfigFile()
        if let data = try? Data(contentsOf: fileURL) {
            file = (try? JSONDecoder().decode(ConfigFile.self, from: data)) ?? file
        }

        let environment = environmentOverride ?? env["DISPATCH_MOD_ENV"] ?? file.environment ?? "development"
        guard environment == "development" || environment == "production" else {
            throw ConfigError.badEnvironment(environment)
        }
        guard let keyID = resolveKeyID(environment: environment, env: env, file: file) else {
            throw ConfigError.missing(
                environment == "production"
                    ? "key ID for production (DISPATCH_MOD_KEY_ID, or keyIDProduction/keyID in "
                        + "~/.dispatch-mod/config.json — s2s key registrations are per-environment, "
                        + "see docs/moderation.md)"
                    : "key ID (DISPATCH_MOD_KEY_ID or keyID in ~/.dispatch-mod/config.json)")
        }
        let rawKeyPath = env["DISPATCH_MOD_KEY_PATH"] ?? file.keyPath
            ?? "\(configDirectory)/eckey.pem"
        let keyPath = (rawKeyPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: keyPath) else {
            throw ConfigError.missing("private key PEM at \(keyPath)")
        }
        return ModConfig(
            keyID: keyID,
            keyPath: keyPath,
            container: env["DISPATCH_MOD_CONTAINER"] ?? file.container ?? defaultContainer,
            environment: environment,
            teamID: env["DISPATCH_MOD_TEAM_ID"] ?? file.teamID ?? defaultTeamID
        )
    }

    /// Environment-aware key-ID resolution. Server-to-server key
    /// registrations are per-environment (each yields its own key ID), so
    /// production prefers `keyIDProduction`, falling back to `keyID`.
    /// `DISPATCH_MOD_KEY_ID` wins unconditionally (the quick override path).
    static func resolveKeyID(
        environment: String,
        env: [String: String],
        file: ConfigFile
    ) -> String? {
        if let id = env["DISPATCH_MOD_KEY_ID"], !id.isEmpty { return id }
        if environment == "production", let id = file.keyIDProduction, !id.isEmpty { return id }
        if let id = file.keyID, !id.isEmpty { return id }
        return nil
    }

    func makeSigner() throws -> CKWebServicesSigner {
        guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8) else {
            throw ConfigError.unreadableKey(keyPath)
        }
        return try CKWebServicesSigner(keyID: keyID, pemPrivateKey: pem)
    }
}#endif
