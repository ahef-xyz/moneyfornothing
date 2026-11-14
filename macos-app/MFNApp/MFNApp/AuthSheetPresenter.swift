import Foundation
import MFNCore
import Observation

/// Bridges `AuthChallengePresenter` (called by connectors from any task) to a SwiftUI sheet.
///
/// Several connections may ask at once (DKB, Trade Republic, C24 during ⌘R); requests queue
/// up and are shown one after another. Requests of a connection that is being set up in the
/// "Bank hinzufügen" assistant are shown inline there instead (`inlineConnections`).
@MainActor
@Observable
final class AuthSheetPresenter: AuthChallengePresenter {
    struct Request: Identifiable {
        let id = UUID()
        /// The asking connection: name for the sheet, ID for credentials and web data store.
        let connection: Connection
        let challenge: AuthChallenge
        fileprivate let continuation: CheckedContinuation<AuthResponse, any Error>

        var connectionName: String { connection.displayName }
    }

    private(set) var queue: [Request] = []
    /// Connections whose requests the setup assistant shows itself.
    var inlineConnections: Set<ConnectionID> = []

    /// Next request for the global sheet.
    var current: Request? { queue.first { !inlineConnections.contains($0.connection.id) } }

    /// Open request of one connection (setup assistant, sidebar hint).
    func request(for connection: ConnectionID) -> Request? {
        queue.first { $0.connection.id == connection }
    }

    /// Connector-facing entry point without a connection; connectors get `scoped(to:)`.
    nonisolated func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
        try Self.checkInteractionAllowed(challenge)
        return try await enqueue(challenge, connection: Connection(id: "unknown", connectorID: .mock, displayName: ""))
    }

    /// Automatic syncs never ask the user (no sheet, no headless login with push or SMS): the
    /// engine marks the bank "Anmeldung nötig" and waits for a manual sync.
    nonisolated static func checkInteractionAllowed(_ challenge: AuthChallenge) throws {
        guard AuthInteraction.isAllowed else { throw ConnectorError.authRequired(challenge) }
    }

    func enqueue(_ challenge: AuthChallenge, connection: Connection) async throws -> AuthResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Request(connection: connection, challenge: challenge, continuation: continuation))
            }
        } onCancel: {
            // The connector's task was cancelled (bank removed, setup cancelled): drop its request.
            Task { @MainActor in self.cancel(connection: connection.id) }
        }
    }

    func respond(to id: UUID, _ response: AuthResponse) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(returning: response)
    }

    func fail(_ id: UUID, with error: ConnectorError) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(throwing: error)
    }

    func cancel(_ id: UUID) {
        fail(id, with: .cancelled)
    }

    /// Answers the request of the global sheet.
    func respond(_ response: AuthResponse) {
        guard let current else { return }
        respond(to: current.id, response)
    }

    func cancel() {
        guard let current else { return }
        cancel(current.id)
    }

    /// Cancels every open request of one connection.
    func cancel(connection: ConnectionID) {
        for request in queue where request.connection.id == connection {
            cancel(request.id)
        }
    }

    /// Locking the app cancels every open approval.
    func cancelAll() {
        for request in queue { cancel(request.id) }
    }

    /// A presenter bound to one connection, so the sheet can say which bank is asking and the
    /// web login knows whose credentials and web data store to use.
    nonisolated func scoped(to connection: Connection) -> any AuthChallengePresenter {
        Scoped(base: self, connection: connection)
    }

    private struct Scoped: AuthChallengePresenter {
        let base: AuthSheetPresenter
        let connection: Connection
        func present(_ challenge: AuthChallenge) async throws -> AuthResponse {
            try AuthSheetPresenter.checkInteractionAllowed(challenge)
            return try await base.enqueue(challenge, connection: connection)
        }
    }
}
