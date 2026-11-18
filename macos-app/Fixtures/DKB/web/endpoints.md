# DKB web banking: endpoints (from Firefox HAR, anonymized)

Recorded: login with approval in the DKB app (`seal_one`), account overview, transactions of several current accounts
(first page each with `page[size]=3` and `25`), debit cards. No credit card, no securities account, no pending transactions in the
capture. HTML/JS documents are missing from the HAR (only XHR exported).

Anonymization: UUIDs replaced deterministically (references between the files stay consistent), IBANs `DE00…`,
account numbers pseudonymous, names from a placeholder list (account holder = "Max Mustermann"), `description` →
"Verwendungszweck NNN" (purpose NNN), mandate/end-to-end/creditor IDs replaced with the same length, tokens `<redacted>`, group names
"Gruppe N" (group N), product names neutral ("Girokonto N", current account N). Afterwards `scripts/fixtures-scrub`: amounts, balances, limits, interest rates,
dates (uniformly shifted by whole weeks), account/user numbers and UUIDs are altered. Only the structure, booking types and the public BLZ/BIC are real.

## Host
Everything under `https://banking.dkb.de` (Angular SPA). Login page `https://banking.dkb.de/login`.
Also `eu.frcapi.com` (Friendly Captcha, proof of work, solves itself), `*.ingest.sentry.io` and
`execution-ci360.infos.dkb.de` (tracking), not needed.

## Headers and cookies
- Every API call: `x-xsrf-token: <value of cookie __Host-xsrf>`, `application-name: web-banking`,
  `Accept: application/json, text/plain, */*` (JSON:API endpoints answer with `application/vnd.api+json`).
- No `Authorization` header: the session lives in cookies (`__Secure-at` access token, `__Secure-rt` refresh token,
  `__Host-sid`, `__Host-sid.sig`, `__Host-xsrf`). After approval additionally `__Secure-ssoIdToken`,
  `__Secure-ssoDeviceSecret`, `__Secure-x_uid`.
- Access token: `expires_in: 300` (5 min), refresh token `refresh_token_expires_in: "86399"` (24 h). A refresh call
  is not included in the capture.

## Login (in order)
| # | Call | Purpose | Fixture |
| --- | --- | --- | --- |
| 1 | `POST eu.frcapi.com/api/v2/captcha/{activate,quote,redeem}` | Friendly Captcha → `captcha_token` | – |
| 2 | `POST /api/token` (form) `grant_type=banking_user_sca`, `username`, `password`, `captcha_token`, `sca_type=web-login` | 1st factor → `token_factor_type: "1fa"`, `mfa_id` | `token-login.json` |
| 3 | `GET /api/mfa/mfa/methods?filter[methodType]=seal_one&filter[methodType]=chip_tan_qr&filter[methodType]=chip_tan_manual` | approval devices (`deviceName`, `methodType`, `preferredDevice`, `locked`) | `mfa-methods.json` |
| 4 | `POST /api/device-data/web-device-data` | browser fingerprint (`data.attributes.data.{deviceInfo,browserInfo,requestMetadata}`) → 204 | – |
| 5 | `POST /api/mfa/mfa/challenges` (JSON:API `mfa-challenge` with `mfaId`, `methodId`, `methodType`) | push to the app | `mfa-challenge-request.json`, `mfa-challenge-processing.json` |
| 6 | `GET /api/mfa/mfa/challenges/<id>` about every 2–3 s | `verificationStatus` `processing` → `processed` | `mfa-challenge-processed.json` |
| 7 | `POST /api/token` (form) `grant_type=banking_user_mfa`, `mfa_id`, `scope=device_sso` | 2nd factor → `token_factor_type: "2fa"`, sets the SSO cookies | `token-mfa.json` |

After that the SPA loads the overview (the page itself is not in the HAR).

## Data
| Call | Content | Fixture |
| --- | --- | --- |
| `GET /api/accounts/accounts?filter[product.type][NEQ]=loan` | accounts (JSON:API `account`): `iban`, `holderName`, `currencyCode`, `balance`/`availableBalance`/`nearTimeBalance` (`{currencyCode, value: "123.45"}`), `product {id, type: checking-account-private, displayName}`, `overdraftLimit`, `updatedAt`, `state` | `accounts.json` |
| `GET /api/accounts/accounts/<id>` | one account, same attributes | `account.json` |
| `GET /api/accounts/accounts/<id>/transactions?expand=Merchant,International&page[size]=25` | transactions (`accountTransaction`): `status` (`booked`; `pending` probably), `bookingDate`, `valueDate`, `valueDateTime?`, `amount {value, currencyCode}` (sign in the value), `description`, `transactionType` (e.g. `RECHNUNG`, `ONLINE-UEBERWEISUNG`, `ECHTZEIT-GUTSCHRIFT`, `FOLGELASTSCHRIFT`), `transactionTypeCode`, `businessTransactionCode`, `creditor {name, id?, creditorAccount {iban?, accountNr, blz?}, agent {bic}?}`, `debtor {…}`, `endToEndId?`, `mandateId?`, `isRevocable` | `transactions-page.json`, `transactions-last.json`, `transactions-small-page.json` |
| Paging | `links.next` = `/accounts/<id>/transactions?page[size]=25&page[after]=<bookingDate>,<timestamp>`, plus `meta.page.next`; if `links` is missing → last page. Newest transactions first. | |
| `GET /api/credit-card/cards?filter[type]=debitCard` | debit cards (`maskedPan`, `referenceAccount.iban`, `product.displayName`) | `cards-debit.json` |
| `GET /api/credit-card/cards?filter[type]=creditCard` | credit cards (empty in the capture: `{"data":[]…}`) | – |
| `GET /api/caa/users/me/product-types` | which product types the customer has (`checkingAccount`, `creditCard`, `brokerageAccount`, …) | `product-types.json` |
| `GET /api/config/users/me/product-display-settings` | groups named by the user (`productGroups.<uuid>.{name,index,products.accounts.<accountId>.index}`) | `product-display-settings.json` |

Own transfers: the counter account is in `creditor`/`debtor` (for outgoing payments `debtor` is the own account, for incoming
payments `creditor`). Creditor ID is in `creditor.id`, mandate reference in `mandateId`.
