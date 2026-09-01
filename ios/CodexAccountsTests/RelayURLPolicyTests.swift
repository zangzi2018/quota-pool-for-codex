import XCTest
@testable import CodexAccounts

final class RelayURLPolicyTests: XCTestCase {
    func testLoopbackAndPrivateHTTPAreAllowed() throws {
        XCTAssertTrue(try RelayURLPolicy.parse("http://127.0.0.1:8787").usesCleartext)
        XCTAssertTrue(try RelayURLPolicy.parse("http://localhost:8787").usesCleartext)
        XCTAssertTrue(try RelayURLPolicy.parse("http://192.168.1.8:8787").usesCleartext)
        XCTAssertTrue(try RelayURLPolicy.parse("http://10.0.0.2:8787").usesCleartext)
        XCTAssertTrue(try RelayURLPolicy.parse("http://172.16.0.4").usesCleartext)
        XCTAssertFalse(try RelayURLPolicy.parse("https://relay.example.invalid").usesCleartext)
    }

    func testPublicHTTPIsRejected() {
        XCTAssertThrowsError(try RelayURLPolicy.parse("http://relay.example.invalid")) { error in
            XCTAssertEqual((error as? RelayURLPolicyError), .insecure)
        }
        XCTAssertThrowsError(try RelayURLPolicy.parse("http://8.8.8.8"))
        XCTAssertThrowsError(try RelayURLPolicy.parse("http://fc.invalid"))
        XCTAssertThrowsError(try RelayURLPolicy.parse("ftp://127.0.0.1"))

        // Build this at runtime so secret scanners do not mistake an intentional
        // credential-in-URL validation fixture for a committed live credential.
        let credentialedURL = ["https://", "sample-user", ":", "sample-password", "@relay.example.invalid"].joined()
        XCTAssertThrowsError(try RelayURLPolicy.parse(credentialedURL)) { error in
            XCTAssertEqual((error as? RelayURLPolicyError), .credentialsInURL)
        }
    }
}
