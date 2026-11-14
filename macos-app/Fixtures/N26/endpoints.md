# N26 Endpunkte (aus Firefox-HAR der Web-App, anonymisiert)

Aufgezeichnet: Login mit Push-Freigabe, Feed des Hauptkontos (Seite 1 + 2), beider Spaces und „Alle Aktivitäten“.
Werte von Headern, Cookies und verschlüsselten Payloads entfernt. Antworten anonymisiert (siehe `README.md`).

## Hosts
- `app.n26.com`: Web-App (HTML) und `POST /graphql?op=<operationName>` – der einzige Daten-Endpunkt.
- `spc.n26.com` (Snowplow-Tracking) und `flags.n26.com` (Statsig-Feature-Flags): ignoriert, nicht nötig.

## Aufrufe (GraphQL, in Reihenfolge)

| Operation | Zweck | Antwort-Fixture |
| --- | --- | --- |
| `requestBiometricChallengeMutation` | Login: `username`, `password`, `fp`, `fpc`, `requestId` → `challengeType: "PUSH"` | `login-request-biometric-challenge.json` |
| `verifyLoginWithPushMutation` | Pollen (ca. alle 2 s), bis in der App bestätigt: `isAuthorizationPending`, `shouldAbortLoginAttempt`, `rateLimit {limit: 60, current}` | `login-verify-push-pending.json`, `login-verify-push-success.json` |
| `getTransactionsList(accountId)` | Feed: `balance` („Aktueller Kontostand“), `activities` (Kontoumschalter), `modules[FeedTimelineModule]` (erste Seite + `paginationKey`) | `feed-main.json`, `feed-space-1.json`, `feed-space-2.json`, `feed-all.json` |
| `getTimeline(paginationKey, activity, accountId)` | nächste (ältere) Seite: `timelineItems`, `paginationKey` (`null` = Ende) | `timeline-main-page2.json` |

Queries im Wortlaut: `*.graphql` (der Connector sendet `getTransactionsList` und `getTimeline` unverändert).

## Request
- `POST https://app.n26.com/graphql?op=<operationName>`, `Content-Type: application/json`
- Header: `csrf-token`, `x-requested-with: XMLHttpRequest`, `Origin`, `Referer` (`/login` bzw. `/feed/transactions/<accountId>`).
- `csrf-token` ist **nicht** der Cookie `n26.csrf`, sondern der Inhalt von `<meta name="csrf-token" content="…">` (36 Zeichen) im HTML.
- Body: `{"operationName": …, "variables": {"payload": "<SJCL-JSON>"}, "query": …}`

### Verschlüsselte Variablen (`variables.payload`)
Die Web-App verschlüsselt **alle** Variablen (Bundle-Chunk `1917`, `client.*.js` → `window.__PEK__`):

```js
sjcl.encrypt(new sjcl.ecc.elGamal.publicKey(sjcl.ecc.curves.c384, sjcl.codec.base64.toBits(window.__PEK__)),
             JSON.stringify(variables), { ts: 128, ks: 256, adata: Date.now().toString() })
```

- `window.__PEK__`: Base64, 96 Byte = x‖y eines P-384-Punkts, steht im HTML jeder Seite (auch anonym auf `/login`).
- KEM: zufälliger Skalar d, `kemtag` = d·G (x‖y, Base64), Schlüssel = SHA-256(x‖y von d·PEK). AES-256-CCM, IV 16 Byte
  (CCM nutzt 15 − L Byte), Tag 128 Bit, `adata` = Zeitstempel in ms als Text.
- Payload-Form (Schlüsselreihenfolge wie SJCL):
  `{"iv":"<24>","v":1,"iter":10000,"ks":256,"ts":128,"mode":"ccm","adata":"<Base64 ms>","cipher":"aes","kemtag":"<128>","ct":"<…>"}`
- Lehnt der Server einen Payload ab (nicht `ok`), antwortet er mit `{"key": "<neuer PEK>"}`; die App setzt `__PEK__` neu
  und wiederholt einmal (Status nicht aufgezeichnet).
- Variablen (aus den Längen von `ct` abgeleitet, Klartext ist nicht einsehbar):
  - `getTransactionsList`: `{"accountId":"<uuid>"}` (Konto/Space) bzw. `{"accountId":null}` (Alle Aktivitäten)
  - `getTimeline`: `{"paginationKey":"<key>","accountId":"<uuid>"}` (ohne `activity`)

## Antworten (Klartext-JSON)
- Feed: `balance.money = {unscaledAmount: "<Minor Units als String>", currency: {code, decimals}}`.
- `activities.values[]`: `title`, `accountId` (UUID, `null` bei „Alle Aktivitäten“), `tracking.label` `ALL` / `MAIN` / `SPACE`.
- `timelineItems[]`: `FeedTimelineGroupHeading` (Tages-/Jahresüberschrift) und `FeedTimelineTransaction`:
  `externalId` (UUID), `accountId`, `title` (Gegenpartei), `tintedSubtitle.elements[].value` (Verwendungszweck/„Online“),
  `secondarySubtitle` („Von Hauptkonto“ in „Alle Aktivitäten“), `styledAmount.money` (vorzeichenbehaftet), `timestamp`
  (ms, Buchungs-/Zahlungszeitpunkt), `category` (`micro-v2-…`), `balance` (Kontostand danach, Float), `icon` (`CATEGORY`/`MERCHANT`,
  `statusIcon` z. B. `installment_eligible.png`), `deeplink`.
- `paginationKey`: Base64-JSON `{"transaction":{"lastId":"<uuid>"},"lastBalance":<float>,"lastItemTs":<ms>,"pageIndex":<n>}`.
- Keine IBAN, keine SEPA-Felder (EREF/MREF/Gläubiger-ID), kein separates Valutadatum im Feed.

## Login und Sitzung
- Login-Seite `https://app.n26.com/login`: Formular `input[name=username]` (type email, id `email`), `input[name=password]`
  (id `password`), versteckt `fp`, `fpc`, `requestId` (füllt die App), Button `data-testid="login-button"`,
  Fehlercontainer `#login-errors`, `#abort-login-attempt-errors`, Push-Fallback-Button `data-testid="verify-login-push-poll-button"`.
- Cookies (nur Namen): `n26.csrf`, `n26.fp`, `n26.mfa_token` / `n26.mfa_recovery` (300 s, während des Logins),
  nach Freigabe `n26.token` (Max-Age 900 s), `num26refresh` (7200 s), `num26expires_at` (900 s), alle HttpOnly; dazu
  `num26UniqueDeviceToken`, `n26.timezone*`, `num26locale`, `num26DarkMode`, `n26.render_js_version`, Snowplow `_sp_*`.
- Abgelaufene Sitzung: Die Web-App behandelt den GraphQL-Fehler `message == "401 Unauthorized"` als Logout (Bundle);
  HTTP-Status dazu nicht aufgezeichnet.

## Lücken (nicht im HAR)
- Vorgemerkte (pending) Kartenzahlungen: keine im Mitschnitt, Kennzeichnung unbekannt.
- Antwort einer abgelaufenen Sitzung (Status/Body), Antwort bei abgelehntem Payload-Schlüssel.
- Ob `num26refresh` beim Laden einer Seite ein neues `n26.token` liefert.
- Feed-Seite 3 des Hauptkontos, Seite 2 von Space 01, Feed mit `FeedPendingModule`/`FeedRecurringModule`.
- Falsches Passwort (Inhalt von `#login-errors`), SMS-Fallback ohne gekoppeltes Gerät.
