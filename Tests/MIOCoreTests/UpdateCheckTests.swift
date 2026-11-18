import Foundation
import XCTest
import MIOCore

final class UpdateCheckTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertLessThan(AppVersion("0.2.0")!, AppVersion("v0.10.0")!)
        XCTAssertLessThan(AppVersion("1.9")!, AppVersion("1.9.1")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1.0.0")!)
        XCTAssertNil(AppVersion("1.x"))
        XCTAssertNil(AppVersion(""))
    }

    private func feed(tag: String = "v0.3.0", draft: Bool = false, pre: Bool = false,
                      asset: String = "AdvancedMIO-0.3.0.zip", url: String = "https://github.com/a/b/releases/download/v0.3.0/AdvancedMIO-0.3.0.zip") -> Data {
        Data("""
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(pre),"body":"notes",
         "assets":[{"name":"checksums.txt","browser_download_url":"https://x/c"},{"name":"\(asset)","browser_download_url":"\(url)"}]}
        """.utf8)
    }

    func testParsesReleaseAndPicksZip() {
        let info = ReleaseFeed.parse(feed())
        XCTAssertEqual(info?.version, AppVersion("0.3.0"))
        XCTAssertEqual(info?.assetName, "AdvancedMIO-0.3.0.zip")
    }

    func testRejectsDraftPrereleaseBadTagMissingAssetAndInsecureURL() {
        XCTAssertNil(ReleaseFeed.parse(feed(draft: true)))
        XCTAssertNil(ReleaseFeed.parse(feed(pre: true)))
        XCTAssertNil(ReleaseFeed.parse(feed(tag: "nightly")))
        XCTAssertNil(ReleaseFeed.parse(feed(asset: "other.zip")))
        XCTAssertNil(ReleaseFeed.parse(feed(url: "http://example.com/AdvancedMIO.zip")))
    }
}
