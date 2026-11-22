import Foundation
import Testing
@testable import MFNCore

@Suite struct ProtocolV4Tests {
    @Test func v3JSONDecodesWithoutAutomation() throws {
        let json = #"{"url":"https://example.com/login","completion":{"urlPrefix":{"_0":"https://example.com/home"}},"cookieDomains":["example.com"],"message":"m","storageKeys":[]}"#
        let request = try JSONDecoder().decode(WebLoginRequest.self, from: Data(json.utf8))
        #expect(request.automation == nil)
    }

    @Test func automationRoundTrips() throws {
        let request = WebLoginRequest(
            url: URL(string: "https://example.com/login")!,
            completion: .cookiesPresent(["sid"]),
            cookieDomains: ["example.com"],
            message: "m",
            automation: WebLoginAutomation(script: "return state;", message: "Anmeldung …", timeout: 120)
        )
        let decoded = try JSONDecoder().decode(WebLoginRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test func credentialsAreRedacted() {
        let credentials = BankCredentials(["username": "alice@example.com", "password": "hunter2"])
        #expect(!credentials.description.contains("hunter2"))
        #expect(!String(reflecting: credentials).contains("alice"))
    }

    @Test func completenessFollowsFields() {
        #expect(!BankCredentials(["phoneNumber": "+49170", "pin": "12a4"]).isComplete(for: .tradeRepublic))
        #expect(!BankCredentials(["phoneNumber": "+49170", "pin": "12345"]).isComplete(for: .tradeRepublic))
        #expect(BankCredentials(["phoneNumber": "+49170", "pin": "1234"]).isComplete(for: .tradeRepublic))
        // v5: C24 logs in by QR code only and needs no stored credentials.
        #expect(ConnectorID.allCases.filter(\.supportsSetup).filter { $0 != .c24 && $0 != .paypal }.allSatisfy { !$0.credentialFields.isEmpty })
        #expect(ConnectorID.c24.credentialFields.isEmpty)
        #expect(BankCredentials().isComplete(for: .c24))
    }
}
