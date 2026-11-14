# PROTOCOL – BankConnector v6

Version: 9
Eingefroren am: 2026-11-10

Dieses Dokument ist der einzige Freeze-Marker. Keine Git-Tags.
Beim Einfrieren: `Version: <n>`, Datum eintragen, `STATUS.md` auf `Protokoll eingefroren: ja` setzen.
Danach gilt: jede Änderung an den Signaturen unten oder an den Modellen in `MFNCore/Models` braucht einen Versions-Bump hier und die Freigabe des Menschen. Subagents tragen Wünsche in `PROPOSALS.md` ein.

## Signaturen (Kopie aus CLAUDE.md §4 – bei Änderungen beide Stellen pflegen)

```swift
public protocol BankConnector: Sendable {
    var id: ConnectorID { get }
    func accounts() async throws -> [Account]
    func balance(for account: Account) async throws -> Balance
    func transactions(for account: Account, since: Date?) async throws -> [Transaction]
    func cardStatements(for account: Account) async throws -> [CardStatement]
    func securities(for account: Account) async throws -> [SecurityPosition]
}

public protocol AuthChallengePresenter: Sendable {
    func present(_ challenge: AuthChallenge) async throws -> AuthResponse
}

public enum ConnectorError: Error, Sendable {
    case authRequired(AuthChallenge), authFailed, sessionExpired, rateLimited(retryAfter: TimeInterval),
         bankUnavailable, formatChanged(detail: String), unsupportedAccount, cancelled
}
```

## Ergänzende Typen (in `MFNCore`)

```swift
public enum AuthChallenge: Hashable, Codable, Sendable {
    case decoupled(message: String, pollInterval: TimeInterval)
    case code(prompt: String, length: Int)
    case pushConfirm(message: String)
    case webLogin(WebLoginRequest)
}
public struct WebLoginRequest: Hashable, Codable, Sendable {
    var url: URL
    var completion: Completion          // .urlPrefix(String) | .cookiesPresent([String])
    var cookieDomains: [String]
    var message: String
    var storageKeys: [StorageKey]       // v2, Default []; fehlt das Feld im JSON (v1), wird [] dekodiert
    var automation: WebLoginAutomation? // v4, Default nil; fehlt im v3-JSON → nil
}
public struct WebLoginAutomation: Hashable, Codable, Sendable {   // v4
    var script: String                  // Rumpf einer async JS-Funktion(credentials, state, url)
    var message: String                 // Anzeige, bis das Skript mfn.status(…) setzt
    var timeout: TimeInterval           // Default 300 s, danach .cancelled
}
public struct CredentialField { key, label, kind (.text/.email/.phone/.secret), prompt, length?, isNumeric }  // v4
public struct BankCredentials { values: [String: String] }   // v4, description redacted, nur Keychain
extension ConnectorID { var credentialFields: [CredentialField]; var supportsSetup: Bool }  // v4
public struct CredentialStore { credentials(for:), set(_:for:), delete(for:) }  // v4, Keychain "credentials.<connectionID>"
// ConnectorID: .ing, .dkb, .tradeRepublic, .c24, .easybank, .n26 (v4), .mock
public struct StorageKey: Hashable, Codable, Sendable {   // v2, deklariert als WebLoginRequest.StorageKey + Typealias
    var key: String                     // Storage-Key bzw. bei .javaScript der Übergabename
    var source: Source                  // .sessionStorage | .localStorage | .javaScript (v3)
    var domain: String                  // Host, dessen Seite den Wert hält (Storage ist pro Origin)
    var expression: String?             // v3, nur .javaScript: auszuwertender Ausdruck; fehlt im v2-JSON → nil
    static func javaScript(key:expression:domain:) -> StorageKey   // v3
}
public enum AuthResponse: Hashable, Sendable { case confirmed, code(String), webSession([SessionCookie]) }  // description redacted
public struct SessionCookie: Hashable, Codable, Sendable { name, value, domain, path, expires?, isSecure, isHTTPOnly }  // value redacted
```

**Web-Login und Web Storage (v2, v3):**
- v3: `source: .javaScript` wertet `expression` auf einer Seite von `domain` aus (für Werte, die eine Web-App nur im Speicher
  hält, z. B. `window.VeriBranch.Config.UniqueKey` bei easybank). Strings unverändert, Zahlen/Bool als Text, Objekte als JSON;
  `null`/`undefined`/Fehler → Eintrag entfällt. Der Ausdruck stammt aus dem Connector, nie aus der Seite.
- Nach Erfüllen von `completion` liest die App jeden `storageKeys`-Eintrag per `WKWebView.evaluateJavaScript`
  (`sessionStorage.getItem` / `localStorage.getItem`) auf einer Seite von `domain` (Host exakt) und liefert den **Rohwert**
  in `.webSession` als `SessionCookie(name: key, value: <Rohwert>, domain: domain, isHTTPOnly: false)` hinter den Cookies.
  Fehlt der Key (oder ist er leer), entfällt der Eintrag. Kein neuer `AuthResponse`-Fall.
- `.cookiesPresent(names)`: jeder Name darf durch ein Cookie der `cookieDomains` **oder** einen gefundenen Storage-Eintrag
  erfüllt werden – in der App (Abschluss des Logins) und in `WebLoginSession` (sonst `authFailed`).
- Storage-Werte sind Geheimnisse wie Cookies: nur Keychain (zusammen mit den Cookies), redacted, nie geloggt.
  Interpretation (JSON, Token) ausschließlich im Connector.
- Cookies kommen aus `WKHTTPCookieStore` (inkl. HttpOnly und skriptgesetzter Cookies wie `aws-waf-token`), gefiltert auf
  `cookieDomains` samt Subdomains.

`ConnectorError` ist zusätzlich `Hashable` und `Codable` (Sync-Status wird persistiert).
`ConnectorError.forbidsAutomaticRetry`: `authFailed`, `authRequired`, `cancelled`, `formatChanged`, `unsupportedAccount`.

**Headless-Login (v4):**
- Ist `WebLoginRequest.automation` gesetzt, zeigt die App **keine** Web-Ansicht. Sie lädt `url` in einem unsichtbaren
  `WKWebView` (persistenter Datenspeicher pro Verbindung, Session-Cookies werden nach dem Login daraus gelöscht – siehe CLAUDE.md §6) und führt nach **jedem** Laden des Hauptframes `automation.script` per
  `callAsyncJavaScript` in einer isolierten Content World aus. Argumente: `credentials` (Objekt Feld-Key → Wert aus
  `CredentialStore`), `state` (Rückgabe des vorigen Laufs, anfangs `null`), `url` (aktuelle Seite).
- Brücke `mfn` in derselben Content World: `mfn.status(text)` (Anzeige im Freigabe-Sheet, z. B. „Bitte in der App
  bestätigen“), `await mfn.requestCode(prompt, length)` (Code-Eingabe durch den Nutzer; Abbruch → Reject `"cancelled"`).
- v5: `mfn.showQRCode(payload, message)` (synchron, ohne Rückgabe): Die App zeichnet selbst einen QR-Code aus `payload`
  (`CIQRCodeGenerator`, Korrekturstufe M; nie ein Bild der Seite), `message` wird Statuszeile. Erneuter Aufruf ersetzt den
  Code; `mfn.status`/`mfn.requestCode` blenden ihn aus. `payload` ist ein Login-Token: nie loggen, nicht in `state`.
- Fehlgründe: Die App protokolliert neben dem Fehlerfall den Nachrichtentext des Skripts nur, wenn er reiner Text ohne
  Ziffern/`@` ist (≤ 120 Zeichen) – Skripte schreiben daher feste, datenfreie Gründe (`authFailed: captcha` o. ä.).
- Abschluss weiterhin über `completion` (unabhängig vom Skript gepollt); Rückgabe an den Connector wie bisher `.webSession`.
- Fehler: Skript wirft `Error` mit Nachricht `authFailed…` → `ConnectorError.authFailed` (kein Retry, Sperrgefahr);
  andere Fehler → `.formatChanged(detail: "login script")` (ohne Nachrichtentext); Zeitüberschreitung → `.cancelled`;
  fehlen die Zugangsdaten, fragt die App sie im Sheet ab (Felder aus `credentialFields`) und speichert sie.
- Zugangsdaten nur als Argument, nie in Skript-Quelltext eingesetzt, nie geloggt, keine Konsolenweitergabe.
  Connectoren sehen keine Zugangsdaten, nur das Ergebnis (Cookies/Storage).
- Skripte stammen ausschließlich aus dem Connector. Sie dürfen nur Login-Schritte ausführen (Formular füllen oder die
  Login-Endpunkte der Bank per `fetch` von deren Origin), nie Aufträge.
- `automation == nil` → sichtbarer Web-Login wie v1–v3.

## Verhalten, auf das sich Connectoren verlassen (in `MFNCore`, nicht Teil der Connectoren)

- **pending → booked** (`TransactionMerger`): gleiches Konto, gleicher Händler (alphanumerisch, Präfix-Vergleich),
  Datum ± 3 Tage, gleicher Betrag – bei Fremdwährung (`originalCurrency` ≠ `currency`) ± 2 %.
  Gebuchte Historie wird nie gelöscht; verschwundene pending/planned im abgefragten Zeitraum schon.
- **Sync** (`SyncEngine`): ein Sync pro Verbindung gleichzeitig, automatisch frühestens alle 15 min,
  kein automatischer Retry nach Login-Fehler, Stopp nach 3 Fehlern, `retryAfter` wird respektiert,
  inkrementell ab letztem Erfolg minus 14 Tage.
- **Abnahme** (`MFNConformance.ConnectorConformance`): Modell-Invarianten, Fingerprint stabil,
  `since` respektiert, pending → booked, Fehlerpfade nur `ConnectorError`, keine Secrets/IBANs in Logs (info+).

## Modelle (`MFNCore/Sources/MFNCore/Models`)

- `BankDay` (year, month, day; Europe/Berlin; Codable als `yyyy-MM-dd`) für alle Bank-Kalendertage.
  `Date` nur für Zeitpunkte (`asOf`, `since`, Sync-Zeitstempel).
- `Connection` (id, connectorID, displayName).
- `Account` (id, connectionID, iban?, type giro/tagesgeld/depot/card, currency, name, cardLast4?, creditLimitCents?).
- `Transaction` wie CLAUDE.md §4. `bookingDate: BankDay?`, `valueDate: BankDay`, `rawJSON: Data`.
  Connector-Felder sind `let`; `fingerprint` wird im Initialiser über `Fingerprint.make` berechnet.
  `id` = `ext:<externalID>` oder `fp:<fingerprint>`; Kollisionen über `Transaction.uniquingIDs` (`#2`, `#3`).
- `Balance` (bookedCents, availableCents?, currency, asOf).
- `CardStatement` (**accountID**, periodStart, periodEnd, dueDate?, amountCents, **currency**, pdfBlobID?).
- `SecurityPosition` (**accountID**, isin, **name**, quantity: `Decimal`, priceCents, currency, asOf, **purchasePriceCents: `Int?`** – durchschnittlicher Einstandskurs pro Stück in Cent von `currency`, gleiche Einheit wie `priceCents` (Anleihen pro 100 Nominal), `nil` wenn die Bank keinen liefert).

Fett = Ergänzung gegenüber der Kurzfassung in CLAUDE.md §4 (Zuordnung, Mehrwährung, Anzeige).

## Fingerprint

`SHA-256(accountID | bookingDate (yyyy-MM-dd oder leer) | amountCents | normalizedPurpose | counterpartIBAN)`.
`normalizedPurpose`: case-/diakritik-/breitenunabhängig gefaltet, **alle** Whitespaces entfernt
(MT940 bricht nach 27 Zeichen auch mitten im Wort um). IBAN: Großbuchstaben ohne Leerzeichen.

## Änderungshistorie
| Version | Datum | Änderung | Freigabe |
| --- | --- | --- | --- |
| 1 | 2026-11-09 | Initiales Einfrieren nach M2 (inkl. `WebLoginRequest`, `BankDay`, `accountID` an `CardStatement`/`SecurityPosition`) | Mensch, 2026-11-09 |
| 9 | 2026-11-12 | `SecurityPosition.purchasePriceCents: Int?` (Default `nil`) für Gewinn/Verlust; FinTS liest `:70E::HOLD//` aus MT535 (ING liefert ihn). Store-Migration 6 | Mensch, 2026-11-12 (Rückfrage „Protokoll v9“: „Yes, bump to v9“) |
| 8 | 2026-11-12 | `.ing.credentialFields` = Zugangsnummer (oder Benutzername) + PIN für FinTS (Keys `userID`/`pin` statt `username`/`password`); ING nur noch per FinTS, Web-Banking-Connector `MFNING` entfernt. Keine Signaturänderung | Mensch, 2026-11-12 (Chat: „ing webscraping can be removed entirely, when finished“ / „can be deleted“) |
| 7 | 2026-11-10 | `.ing.credentialFields` = Benutzername + Passwort (Keys `username`/`password` statt `accessNumber`/`pin`), Web-Login-Formular nimmt beides. Keine Signaturänderung | Mensch, 2026-11-10 (Chat: „ing needs username and real password not pin“) |
| 6 | 2026-11-10 | `.dkb.credentialFields` = Anmeldename + **Passwort** (Key `password` statt `pin`), `.dkb.supportsSetup = true`, `.ing.supportsSetup = true` (Felder unverändert: Zugangsnummer + PIN): ING und DKB per Web-Banking-Scraping bis zur FinTS-Registrierung. Keine Signaturänderung | Mensch, 2026-11-10 (Chat: „lets scrape ing and dkb now too and implement fints later“) |
| 5 | 2026-11-10 | Brücke `mfn.showQRCode(payload, message)` für Headless-Login per QR-Code; `.c24.credentialFields = []`. Additiv. Anlass: C24 hat nur QR-Login (`PROPOSALS.md`) | Mensch, 2026-11-10 (Chat: „C24 braucht den richtigen Login“) |
| 4 | 2026-11-10 | `WebLoginRequest.automation: WebLoginAutomation?` (Headless-Login mit gespeicherten Zugangsdaten), `CredentialField`/`BankCredentials`/`CredentialStore`, `ConnectorID.credentialFields`/`supportsSetup`, `ConnectorID.n26`. Additiv, v3-JSON bleibt dekodierbar. Anlass: Bank-Einrichtung per Assistent, Login ohne sichtbare Web-Ansicht, N26 | Mensch, 2026-11-10 (Auftrag im Chat) |
| 3 | 2026-11-10 | `StorageKey.Source.javaScript` + `StorageKey.expression` (optional, v2-JSON bleibt dekodierbar). Additiv. Anlass: easybank verlangt Header `UniqueKey`/`pcid` aus `window.VeriBranch.Config` (nicht im Web Storage) | Mensch, 2026-11-10 |
| 2 | 2026-11-10 | `WebLoginRequest.storageKeys: [StorageKey]` (`key`, `source: .sessionStorage/.localStorage`, `domain`), Default `[]`, v1-JSON bleibt dekodierbar. Storage-Werte als Pseudo-Cookies in `.webSession`; `.cookiesPresent` darf durch Storage-Einträge erfüllt werden. Additiv: bestehende Connectoren unverändert. Anlass: C24 (Bearer-Token in `sessionStorage`), Vorschlag in `PROPOSALS.md` (Branch `c24`) | Mensch, 2026-11-10 |
