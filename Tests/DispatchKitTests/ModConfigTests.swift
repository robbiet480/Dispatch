#if os(macOS)
import XCTest
@testable import dispatch_mod

/// Per-environment key-ID resolution (docs/moderation.md §1): CloudKit
/// server-to-server public keys are registered PER ENVIRONMENT and each
/// registration yields its own key ID — verified live 2026-07-09, when the
/// Development key ID returned AUTHENTICATION_FAILED against Production
/// until the same public key was registered there under a new key ID.
final class ModConfigTests: XCTestCase {
    private func file(
        keyID: String? = nil,
        keyIDProduction: String? = nil
    ) -> ModConfig.ConfigFile {
        ModConfig.ConfigFile(keyID: keyID, keyIDProduction: keyIDProduction)
    }

    func testDevelopmentUsesKeyID() {
        XCTAssertEqual(
            ModConfig.resolveKeyID(
                environment: "development", env: [:],
                file: file(keyID: "DEV123", keyIDProduction: "PROD456")),
            "DEV123")
    }

    func testProductionPrefersKeyIDProduction() {
        XCTAssertEqual(
            ModConfig.resolveKeyID(
                environment: "production", env: [:],
                file: file(keyID: "DEV123", keyIDProduction: "PROD456")),
            "PROD456")
    }

    func testProductionFallsBackToKeyID() {
        XCTAssertEqual(
            ModConfig.resolveKeyID(
                environment: "production", env: [:],
                file: file(keyID: "DEV123")),
            "DEV123")
    }

    func testEnvOverrideWinsForAnyEnvironment() {
        // DISPATCH_MOD_KEY_ID is the documented quick path — it wins even
        // over keyIDProduction.
        for environment in ["development", "production"] {
            XCTAssertEqual(
                ModConfig.resolveKeyID(
                    environment: environment,
                    env: ["DISPATCH_MOD_KEY_ID": "ENV789"],
                    file: file(keyID: "DEV123", keyIDProduction: "PROD456")),
                "ENV789")
        }
    }

    func testEmptyStringsAreTreatedAsMissing() {
        XCTAssertEqual(
            ModConfig.resolveKeyID(
                environment: "production",
                env: ["DISPATCH_MOD_KEY_ID": ""],
                file: file(keyID: "DEV123", keyIDProduction: "")),
            "DEV123")
        XCTAssertNil(
            ModConfig.resolveKeyID(environment: "development", env: [:], file: file()))
    }

    func testConfigFileDecodesKeyIDProduction() throws {
        let json = Data("""
        {"keyID": "DEV123", "keyIDProduction": "PROD456"}
        """.utf8)
        let decoded = try JSONDecoder().decode(ModConfig.ConfigFile.self, from: json)
        XCTAssertEqual(decoded.keyID, "DEV123")
        XCTAssertEqual(decoded.keyIDProduction, "PROD456")
    }
}
#endif
