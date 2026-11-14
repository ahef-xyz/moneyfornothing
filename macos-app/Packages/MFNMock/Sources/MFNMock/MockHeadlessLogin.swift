import Foundation
import MFNCore

/// A headless web login (protocol v4) that runs without any bank: the hidden web view loads
/// `about:blank`, the script reports status, asks for a code through `mfn.requestCode` and
/// completes by setting a URL fragment. Lets the human try the whole flow in the demo
/// (`MFN_DEMO=headless`, easybank mock).
public enum MockHeadlessLogin {
    public static let completionURL = "about:blank#mfn-demo-ok"
    /// Code the script rejects with `authFailed` (like the mock's "0000" rule).
    public static let rejectedCode = "000000"

    public static let script = """
    if (state === null) {
      mfn.status("Demo: Anmeldung läuft …");
      await new Promise(function (resolve) { setTimeout(resolve, 1000); });
      var code = await mfn.requestCode("Demo-Code eingeben (beliebige 6 Ziffern, \(rejectedCode) wird abgelehnt)", 6);
      if (code === "\(rejectedCode)") { throw new Error("authFailed: demo code rejected"); }
      mfn.status("Demo: Code angenommen, Sitzung wird übernommen …");
      await new Promise(function (resolve) { setTimeout(resolve, 800); });
      location.hash = "mfn-demo-ok";
      return { step: "done" };
    }
    return state;
    """

    public static var request: WebLoginRequest {
        WebLoginRequest(
            url: URL(string: "about:blank") ?? URL(fileURLWithPath: "/"),
            completion: .urlPrefix(completionURL),
            cookieDomains: [],
            message: "Demo-Anmeldung",
            automation: WebLoginAutomation(script: script, message: "Demo: Verbindung wird aufgebaut …", timeout: 120)
        )
    }

    public static var challenge: AuthChallenge { .webLogin(request) }
}

extension MockDataset {
    /// `demoConnectors`, but the easybank mock logs in headless (`MockHeadlessLogin`).
    public func demoConnectorsWithHeadlessLogin(presenter: (any AuthChallengePresenter)?, latency: Duration = .milliseconds(400)) -> [(Connection, MockConnector)] {
        demoConnectors(presenter: presenter, latency: latency).map { connection, connector in
            var connector = connector
            if connection.id == MockConnections.easybank { connector.scenario = .requiresApproval(MockHeadlessLogin.challenge) }
            return (connection, connector)
        }
    }
}
