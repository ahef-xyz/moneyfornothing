# DKB Web-Banking: Endpunkte (aus Firefox-HAR, anonymisiert)

Aufgezeichnet: Login mit Freigabe in der DKB-App (`seal_one`), Kontenübersicht, Umsätze mehrerer Girokonten
(je erste Seite mit `page[size]=3` und `25`), Debitkarten. Keine Kreditkarte, kein Depot, keine vorgemerkten Umsätze im
Mitschnitt. HTML/JS-Dokumente fehlen im HAR (nur XHR exportiert).

Anonymisierung: UUIDs deterministisch ersetzt (Bezüge zwischen den Dateien bleiben stimmig), IBANs `DE00…`,
Kontonummern pseudonym, Namen aus einer Platzhalterliste (Kontoinhaber = „Max Mustermann“), `description` →
„Verwendungszweck NNN“, Mandats-/End-to-End-/Gläubiger-IDs gleich lang ersetzt, Tokens `<redacted>`, Gruppen-Namen
„Gruppe N“, Produktnamen neutral („Girokonto N“). Anschließend `scripts/fixtures-scrub`: Beträge, Salden, Limits, Zinssätze,
Daten (einheitlich um ganze Wochen verschoben), Konto-/Benutzernummern und UUIDs sind verfremdet. Echt sind nur Struktur,
Buchungsarten und die öffentlichen BLZ/BIC.

## Host
Alles unter `https://banking.dkb.de` (Angular-SPA). Login-Seite `https://banking.dkb.de/login`.
Daneben `eu.frcapi.com` (Friendly Captcha, Proof-of-Work, löst die Seite selbst), `*.ingest.sentry.io` und
`execution-ci360.infos.dkb.de` (Tracking) – nicht nötig.

## Header und Cookies
- Jeder API-Aufruf: `x-xsrf-token: <Wert des Cookies __Host-xsrf>`, `application-name: web-banking`,
  `Accept: application/json, text/plain, */*` (JSON:API-Endpunkte antworten `application/vnd.api+json`).
- Kein `Authorization`-Header: Die Sitzung steckt in Cookies (`__Secure-at` Access-Token, `__Secure-rt` Refresh-Token,
  `__Host-sid`, `__Host-sid.sig`, `__Host-xsrf`). Nach der Freigabe zusätzlich `__Secure-ssoIdToken`,
  `__Secure-ssoDeviceSecret`, `__Secure-x_uid`.
- Access-Token: `expires_in: 300` (5 min), Refresh-Token `refresh_token_expires_in: "86399"` (24 h). Ein Refresh-Aufruf
  ist im Mitschnitt nicht enthalten.

## Login (in Reihenfolge)
| # | Aufruf | Zweck | Fixture |
| --- | --- | --- | --- |
| 1 | `POST eu.frcapi.com/api/v2/captcha/{activate,quote,redeem}` | Friendly Captcha → `captcha_token` | – |
| 2 | `POST /api/token` (form) `grant_type=banking_user_sca`, `username`, `password`, `captcha_token`, `sca_type=web-login` | 1. Faktor → `token_factor_type: "1fa"`, `mfa_id` | `token-login.json` |
| 3 | `GET /api/mfa/mfa/methods?filter[methodType]=seal_one&filter[methodType]=chip_tan_qr&filter[methodType]=chip_tan_manual` | Freigabegeräte (`deviceName`, `methodType`, `preferredDevice`, `locked`) | `mfa-methods.json` |
| 4 | `POST /api/device-data/web-device-data` | Browser-Fingerprint (`data.attributes.data.{deviceInfo,browserInfo,requestMetadata}`) → 204 | – |
| 5 | `POST /api/mfa/mfa/challenges` (JSON:API `mfa-challenge` mit `mfaId`, `methodId`, `methodType`) | Push an die App | `mfa-challenge-request.json`, `mfa-challenge-processing.json` |
| 6 | `GET /api/mfa/mfa/challenges/<id>` ca. alle 2–3 s | `verificationStatus` `processing` → `processed` | `mfa-challenge-processed.json` |
| 7 | `POST /api/token` (form) `grant_type=banking_user_mfa`, `mfa_id`, `scope=device_sso` | 2. Faktor → `token_factor_type: "2fa"`, setzt die SSO-Cookies | `token-mfa.json` |

Danach lädt die SPA die Übersicht (Seite selbst nicht im HAR).

## Daten
| Aufruf | Inhalt | Fixture |
| --- | --- | --- |
| `GET /api/accounts/accounts?filter[product.type][NEQ]=loan` | Konten (JSON:API `account`): `iban`, `holderName`, `currencyCode`, `balance`/`availableBalance`/`nearTimeBalance` (`{currencyCode, value: "123.45"}`), `product {id, type: checking-account-private, displayName}`, `overdraftLimit`, `updatedAt`, `state` | `accounts.json` |
| `GET /api/accounts/accounts/<id>` | ein Konto, gleiche Attribute | `account.json` |
| `GET /api/accounts/accounts/<id>/transactions?expand=Merchant,International&page[size]=25` | Umsätze (`accountTransaction`): `status` (`booked`; `pending` vermutlich), `bookingDate`, `valueDate`, `valueDateTime?`, `amount {value, currencyCode}` (Vorzeichen im Wert), `description`, `transactionType` (z. B. `RECHNUNG`, `ONLINE-UEBERWEISUNG`, `ECHTZEIT-GUTSCHRIFT`, `FOLGELASTSCHRIFT`), `transactionTypeCode`, `businessTransactionCode`, `creditor {name, id?, creditorAccount {iban?, accountNr, blz?}, agent {bic}?}`, `debtor {…}`, `endToEndId?`, `mandateId?`, `isRevocable` | `transactions-page.json`, `transactions-last.json`, `transactions-small-page.json` |
| Paging | `links.next` = `/accounts/<id>/transactions?page[size]=25&page[after]=<bookingDate>,<Zeitstempel>`, dazu `meta.page.next`; fehlt `links` → letzte Seite. Neueste Umsätze zuerst. | |
| `GET /api/credit-card/cards?filter[type]=debitCard` | Debitkarten (`maskedPan`, `referenceAccount.iban`, `product.displayName`) | `cards-debit.json` |
| `GET /api/credit-card/cards?filter[type]=creditCard` | Kreditkarten (im Mitschnitt leer: `{"data":[]…}`) | – |
| `GET /api/caa/users/me/product-types` | welche Produktarten der Kunde hat (`checkingAccount`, `creditCard`, `brokerageAccount`, …) | `product-types.json` |
| `GET /api/config/users/me/product-display-settings` | vom Nutzer benannte Gruppen (`productGroups.<uuid>.{name,index,products.accounts.<accountId>.index}`) | `product-display-settings.json` |

Eigene Umbuchungen: Gegenkonto steht in `creditor`/`debtor` (bei Ausgang ist `debtor` das eigene Konto, bei Eingang
`creditor`). Gläubiger-ID steht in `creditor.id`, Mandatsreferenz in `mandateId`.
