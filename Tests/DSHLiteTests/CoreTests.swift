import XCTest
@testable import DSHLiteCore

final class CoreTests: XCTestCase {
    func testShellQuoteProtectsMetacharacters() {
        let value = "@deepseek-ai/dsh; touch /tmp/pwned 'quoted'"
        let quoted = LaunchSpec.shellQuote(value)
        XCTAssertEqual(quoted, "'@deepseek-ai/dsh; touch /tmp/pwned '\''quoted'\'''")
    }

    func testSettingsValidation() throws {
        XCTAssertThrowsError(try Settings(packageSpec: "  \n").validate())
        XCTAssertThrowsError(try Settings(runtime: "custom", customExecutable: "/definitely/missing").validate())
        XCTAssertNoThrow(try Settings().validate())
    }

    func testDSHUpdateCommandUsesLoginShellAndSafePackageArgument() throws {
        let spec = "@deepseek-ai/dsh; echo should-not-run 'quoted'"
        let settings = Settings(packageSpec: spec, proxyURL: "http://127.0.0.1:7890")
        let command = try DSHUpdateCommand(settings: settings, environment: ["PATH": "/usr/bin"])

        XCTAssertEqual(command.executable.path, "/bin/zsh")
        XCTAssertEqual(command.arguments.first, "-lic")
        XCTAssertTrue(command.arguments[1].hasPrefix("exec npm install -g -- '") )
        XCTAssertTrue(command.arguments[1].contains("; echo should-not-run"))
        XCTAssertEqual(command.environment["http_proxy"], "http://127.0.0.1:7890")
        XCTAssertEqual(command.environment["npm_config_cache"], AppPaths.supportDirectory.appendingPathComponent("npm-cache").path)
    }

    func testDSHUpdateCommandSeparatesPackageSpecFromNpmOptions() throws {
        let command = try DSHUpdateCommand(settings: Settings(packageSpec: "-malicious-option"), environment: ["PATH": "/usr/bin"])
        XCTAssertEqual(command.arguments[1], "exec npm install -g -- '-malicious-option'")
    }

    func testDSHUpdateCommandRejectsCustomRuntimeAndInvalidPackage() {
        XCTAssertThrowsError(try DSHUpdateCommand(settings: Settings(runtime: "custom"))) { error in
            XCTAssertEqual(error as? DSHUpdateError, .unavailableForCustomRuntime)
        }
        XCTAssertThrowsError(try DSHUpdateCommand(settings: Settings(packageSpec: "bad\nvalue"))) { error in
            guard case .invalidSettings = error as? DSHUpdateError else {
                return XCTFail("应返回设置校验错误")
            }
        }
    }

    func testDSHUpdateStatesAreEquatable() {
        XCTAssertEqual(DSHUpdateState.idle, .idle)
        XCTAssertNotEqual(DSHUpdateState.running, .succeeded)
        XCTAssertEqual(
            DSHUpdateState.failed(exitCode: 1, reason: "failed"),
            DSHUpdateState.failed(exitCode: 1, reason: "failed")
        )
    }

    func testSettingsDecodeUsesDefaultsForMissingFields() throws {
        let data = Data(#"{"packageSpec":"@deepseek-ai/dsh@next"}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(settings.packageSpec, "@deepseek-ai/dsh@next")
        XCTAssertEqual(settings.runtime, "auto")
        XCTAssertTrue(settings.autoRestart)
        XCTAssertEqual(settings.trustedHosts, [])
        XCTAssertNil(settings.fixedPort)
    }

    func testTrustedHostsNormalizeAndDeduplicate() throws {
        XCTAssertEqual(
            try Settings.parseTrustedHosts(" Gateway.Example.com, gateway.example.com:443\n127.0.0.1:3080,\n"),
            ["gateway.example.com", "gateway.example.com:443", "127.0.0.1:3080"]
        )
        XCTAssertNoThrow(try Settings(trustedHosts: ["example.com", "127.0.0.1:443"]).validate())
    }

    func testTrustedHostsRejectURLPartsWhitespaceAndInvalidPorts() {
        for value in [
            "https://example.com", "example.com/path", "user@example.com",
            "example.com?token=x", "example.com#fragment", "example .com",
            "example.com:0", "example.com:65536", "example.com:abc", "[::1]"
        ] {
            XCTAssertThrowsError(try Settings(trustedHosts: [value]).validate(), value)
        }
    }

    func testFixedPortParsingAndValidation() throws {
        XCTAssertNil(try Settings.parseFixedPort(""))
        XCTAssertEqual(try Settings.parseFixedPort(" 3080 "), 3080)
        XCTAssertThrowsError(try Settings(fixedPort: 0).validate())

        for value in ["0", "65536", "3080.0", "abc", "３０８０"] {
            XCTAssertThrowsError(try Settings.parseFixedPort(value), value)
        }
    }

    func testBackendCommandSupportsFixedZeroTrustUpstreamPort() {
        let command = BackendSupervisor.makeWebCommand(
            port: 3080,
            packageSpec: "@deepseek-ai/dsh",
            customCommand: nil,
            trustedHosts: ["ai.alaxrpg.dpdns.org"]
        )
        XCTAssertTrue(command.contains("web --host 127.0.0.1 --port 3080 --no-open"))
        XCTAssertTrue(command.contains("--trusted-host 'ai.alaxrpg.dpdns.org'"))
    }

    func testBackendCommandAddsRepeatedTrustedHostFlagsSafely() {
        let command = BackendSupervisor.makeWebCommand(
            port: 43123,
            packageSpec: "@deepseek-ai/dsh; echo pwned",
            customCommand: nil,
            trustedHosts: ["gateway.example.com", "gateway.example.com:8443", "x; touch /tmp/pwned"]
        )
        XCTAssertTrue(command.hasPrefix("exec npx --yes -- '@deepseek-ai/dsh; echo pwned' web --host 127.0.0.1 --port 43123 --no-open"))
        XCTAssertEqual(command.components(separatedBy: "--trusted-host").count - 1, 3)
        XCTAssertTrue(command.contains("--trusted-host 'gateway.example.com'"))
        XCTAssertTrue(command.contains("--trusted-host 'gateway.example.com:8443'"))
        XCTAssertTrue(command.contains("--trusted-host 'x; touch /tmp/pwned'"))
        XCTAssertFalse(command.contains("--host gateway.example.com"))
    }

    func testBackendCommandSeparatesPackageSpecFromNpxOptions() {
        let command = BackendSupervisor.makeWebCommand(
            port: 43123,
            packageSpec: "--package=unexpected",
            customCommand: nil,
            trustedHosts: []
        )
        XCTAssertEqual(
            command,
            "exec npx --yes -- '--package=unexpected' web --host 127.0.0.1 --port 43123 --no-open"
        )
    }

    func testLoopbackURLDetectionRejectsExternalURL() {
        XCTAssertNotNil(ServerAddressDetector.detectURL(in: "ready http://127.0.0.1:43123/"))
        XCTAssertNil(ServerAddressDetector.detectURL(in: "ready https://example.com:43123/"))
    }

    func testLogRedactionCoversHeadersKeysAndURLs() {
        let message = "Authorization: Basic dXNlcjpwYXNz Authorization: Bearer bearer-secret "
            + "token=token-secret access_token: access-secret _authToken=_auth-secret "
            + "NPM_TOKEN=npm-secret api-key: key-secret "
            + "https://user:password@example.com/path?token=query-secret&next=ok"
        let redacted = LogStore.redact(message)

        for secret in [
            "dXNlcjpwYXNz", "bearer-secret", "token-secret", "access-secret",
            "_auth-secret", "npm-secret", "key-secret", "user:password", "query-secret"
        ] {
            XCTAssertFalse(redacted.contains(secret), "日志不应包含敏感值：\(secret)")
        }
        XCTAssertTrue(redacted.contains("Authorization: Basic [REDACTED]"))
        XCTAssertTrue(redacted.contains("Authorization: Bearer [REDACTED]"))
        XCTAssertTrue(redacted.contains("?token=[REDACTED]&next=ok"))
        XCTAssertTrue(redacted.contains("https://[REDACTED]@example.com"))
    }
}
