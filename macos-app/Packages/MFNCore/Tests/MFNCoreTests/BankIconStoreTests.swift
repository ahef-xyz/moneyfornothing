import Foundation
import Testing
@testable import MFNCore

@Suite struct BankIconStoreTests {
    let base = URL(string: "https://www.example-bank.de/start")!

    @Test func prefersAppleTouchIconThenLargestSize() {
        let html = """
        <head>
          <link rel="icon" href="/fav-16.png" sizes="16x16">
          <link rel='icon' type='image/png' href='https://cdn.example-bank.de/fav-96.png' sizes='96x96'>
          <LINK REL="apple-touch-icon" HREF="touch.png">
          <link rel="stylesheet" href="/site.css">
        </head>
        """
        let urls = BankIconStore.iconCandidates(inHTML: html, base: base).map(\.absoluteString)
        #expect(urls == [
            "https://www.example-bank.de/touch.png",
            "https://cdn.example-bank.de/fav-96.png",
            "https://www.example-bank.de/fav-16.png",
        ])
    }

    @Test func resolvesRelativeToRedirectedPageAndSkipsUnsafeLinks() {
        let html = """
        <link rel="shortcut icon" href="/resource/crblob/1/favicon-data.png">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="http://insecure.example/fav.png">
        <link rel="icon" type="image/svg+xml" href="/fav.svg" sizes="512x512">
        """
        let urls = BankIconStore.iconCandidates(inHTML: html, base: base).map(\.absoluteString)
        #expect(urls == [
            "https://www.example-bank.de/resource/crblob/1/favicon-data.png",
            "https://www.example-bank.de/fav.svg",
        ])
    }

    @Test func dropsIconLinksOffTheBanksDomain() {
        let html = """
        <link rel="icon" href="https://tracker.example-other.com/fav.png" sizes="512x512">
        <link rel="icon" href="https://example-bank.de.evil.example/fav.png" sizes="256x256">
        <link rel="icon" href="https://static.example-bank.de/fav.png" sizes="32x32">
        """
        let urls = BankIconStore.iconCandidates(inHTML: html, base: base).map(\.absoluteString)
        #expect(urls == ["https://static.example-bank.de/fav.png"])
    }

    @Test func sameSiteRuleUsesRegistrableDomain() throws {
        let site = try #require(BankIconStore.registrableDomain(of: base))
        #expect(site == "example-bank.de")
        #expect(BankIconStore.isAllowed(URL(string: "https://example-bank.de/a")!, site: site))
        #expect(BankIconStore.isAllowed(URL(string: "https://cdn.www.example-bank.de/a")!, site: site))
        #expect(!BankIconStore.isAllowed(URL(string: "http://www.example-bank.de/a")!, site: site))
        #expect(!BankIconStore.isAllowed(URL(string: "https://notexample-bank.de/a")!, site: site))
        #expect(!BankIconStore.isAllowed(URL(string: "https://example-bank.de.evil.example/a")!, site: site))
    }

    @Test func recognisesImagesButNotErrorPages() {
        #expect(BankIconStore.looksLikeImage(Data([0x89, 0x50, 0x4E, 0x47, 0x0D]), mimeType: "image/png"))
        #expect(BankIconStore.looksLikeImage(Data([0x00, 0x00, 0x01, 0x00, 0x01]), mimeType: "image/x-icon"))
        #expect(!BankIconStore.looksLikeImage(Data("<html>404</html>".utf8), mimeType: "text/html"))
        #expect(!BankIconStore.looksLikeImage(Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "text/html"))
    }

    @Test func everyBankHasAnHTTPSHomepage() {
        for connector in ConnectorID.allCases where connector != .mock && connector != .manual && connector != .yaxi {
            #expect(BankIconStore.homepage(for: connector)?.scheme == "https")
        }
        #expect(BankIconStore.homepage(for: .mock) == nil)
        // v10: an account without a bank connection has no favicon.
        #expect(BankIconStore.homepage(for: .manual) == nil)
        // v12: YAXI reaches many banks; no single homepage, no extra host.
        #expect(BankIconStore.homepage(for: .yaxi) == nil)
    }
}
