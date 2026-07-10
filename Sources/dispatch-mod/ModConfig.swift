#if os(macOS)
import DispatchKit
import Foundation

/// Configuration for the moderation tool. The server-to-server key is a
/// user-created credential and NEVER lives in the repo: it is read from
/// `~/.dispatch-mod/` or from environment variables at runtime.
///
/// Resolution order (env wins over file):
///   - `DISPATCH_MOD_KEY_ID`      — key ID from CloudKit Console
///   - `DISPATCH_MOD_KEY_PATH`    — path to the EC private key PEM
///   - `DISPATCH_MOD_CONTAINER`   — container ID (default iCloud.io.robbie.Dispatch)
///   - `DISPATCH_MOD_ENV`         — `development` (default) or `production`
///   - `~/.dispatch-mod/config.json` — {"keyID": "...", "keyPath": "...",
///     "container": "...", "environment": "..."}; keyPath defaults to
///     `~/.dispatch-mod/eckey.pem`.
struct ModConfig {
    static let defaultContainer = "iCloud.io.robbie.Dispatch"
    static let configDirectory = ("~/.dispatch-mod" as NSString).expandingTildeInPath

    var keyID: String
    var keyPath: String
    var container: String
    var environment: String

    struct ConfigFile: Decodable {
        var keyID: String?
        var keyPath: String?
        var container: String?
        var environment: String?
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
        var file = ConfigFile(keyID: nil, keyPath: nil, container: nil, environment: nil)
        if let data = try? Data(contentsOf: fileURL) {
            file = (try? JSONDecoder().decode(ConfigFile.self, from: data)) ?? file
        }

        guard let keyID = env["DISPATCH_MOD_KEY_ID"] ?? file.keyID, !keyID.isEmpty else {
            throw ConfigError.missing("key ID (DISPATCH_MOD_KEY_ID or keyID in ~/.dispatch-mod/config.json)")
        }
        let rawKeyPath = env["DISPATCH_MOD_KEY_PATH"] ?? file.keyPath
            ?? "\(configDirectory)/eckey.pem"
        let keyPath = (rawKeyPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: keyPath) else {
            throw ConfigError.missing("private key PEM at \(keyPath)")
        }
        let environment = environmentOverride ?? env["DISPATCH_MOD_ENV"] ?? file.environment ?? "development"
        guard environment == "development" || environment == "production" else {
            throw ConfigError.badEnvironment(environment)
        }
        return ModConfig(
            keyID: keyID,
            keyPath: keyPath,
            container: env["DISPATCH_MOD_CONTAINER"] ?? file.container ?? defaultContainer,
            environment: environment
        )
    }

    func makeSigner() throws -> CKWebServicesSigner {
        guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8) else {
            throw ConfigError.unreadableKey(keyPath)
        }
        return try CKWebServicesSigner(keyID: keyID, pemPrivateKey: pem)
    }
}#endif
