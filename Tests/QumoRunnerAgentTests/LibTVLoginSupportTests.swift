import XCTest

final class LibTVLoginSupportTests: XCTestCase {
    func testParsesNumericAccountIDAndAccountNameFromCLIInfo() {
        let metadata = LibTVAccountMetadataParser.parse(
            output: #"prefix {"user":{"nickname":"用户昵称"},"activeAccount":{"accountId":5001033,"accountName":"趣摩AI"}} suffix"#,
            fallbackAccountRef: "fallback-id",
            fallbackDisplayName: "fallback-name"
        )

        XCTAssertEqual(metadata.accountRef, "5001033")
        XCTAssertEqual(metadata.displayName, "趣摩AI")
    }

    func testLoginURLAllowsOnlyOfficialHTTPSHosts() {
        XCTAssertEqual(
            LibTVLoginURLValidator.firstOfficialURL(in: "open https://www.liblib.art/zh?callback_url=http%3A%2F%2F127.0.0.1")?.host,
            "www.liblib.art"
        )
        XCTAssertNil(LibTVLoginURLValidator.firstOfficialURL(in: "open http://www.liblib.art/zh"))
        XCTAssertNil(LibTVLoginURLValidator.firstOfficialURL(in: "open https://liblib.art.example.com/steal"))
        XCTAssertEqual(
            LibTVLoginURLValidator.firstOfficialURL(in: "ignore https://evil.example/a then https://passport.liblib.tv/login")?.host,
            "passport.liblib.tv"
        )
    }
}
