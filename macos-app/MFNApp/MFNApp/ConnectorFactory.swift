import MFNC24
import MFNCore
import MFNDKB
import MFNEasybank
import MFNN26
import MFNPayPal
import MFNTradeRepublic
import MFNYAXI

/// `ConnectorID` → connector of this build. The only place the app names connector packages.
enum ConnectorFactory {
    /// `nil` for banks without a connector in the app yet.
    static func make(_ connection: Connection, presenter: any AuthChallengePresenter) -> (any BankConnector)? {
        // FinTS connections (developer mode, see `BankAccess`) read their credentials per call.
        if BankAccess.isFinTS(connection) {
            guard BankAccess.fintsBanks.contains(connection.connectorID) else { return nil }
            return FinTSConnection(connection: connection, presenter: presenter)
        }
        let connector: (any BankConnector)? = switch connection.connectorID {
        case .easybank: EasybankConnector(connectionID: connection.id, presenter: presenter)
        case .c24: C24Connector(connectionID: connection.id, presenter: presenter)
        case .tradeRepublic: TradeRepublicConnector(connectionID: connection.id, presenter: presenter)
        case .n26: N26Connector(connectionID: connection.id, presenter: presenter)
        case .dkb: DKBConnector(connectionID: connection.id, presenter: presenter)
        // v11: visible web login, no stored credentials.
        case .paypal: PayPalConnector(connectionID: connection.id, presenter: presenter)
        // FinTS only (`fints-` connections above). An old web banking ING has no connector any
        // more: it keeps its data until it is merged or removed.
        case .ing: nil
        case .mock: nil
        // v10: accounts without a bank connection never get a connector (no sync).
        case .manual: nil
        // v12: any bank through YAXI with the user's own key. The bank login (Keychain) is only
        // read when the bank needs a new consent.
        case .yaxi: YAXIConnector(connectionID: connection.id, presenter: presenter) { [id = connection.id] in
            YAXISetup.bank(of: id)?.login(from: try CredentialStore().credentials(for: id))
        }
        }
        return connector
    }

    /// Banks the assistant offers as available: setup supported and a connector in this build.
    static func canSetUp(_ connector: ConnectorID) -> Bool {
        guard connector.supportsSetup else { return false }
        let probe = Connection(id: BankAccess.standard(connector).newConnectionID(), connectorID: connector, displayName: "")
        return make(probe, presenter: NoPresenter()) != nil
    }

    private struct NoPresenter: AuthChallengePresenter {
        func present(_ challenge: AuthChallenge) async throws -> AuthResponse { throw ConnectorError.cancelled }
    }
}
