# N26 endpoints (from Firefox HAR of the web app, anonymized)

Recorded: login with push approval, feed of the main account (pages 1 + 2), both Spaces and "Alle Aktivitäten" (all activities).
Values of headers, cookies and encrypted payloads removed. Responses anonymized (see `README.md`).

## Hosts
- `app.n26.com`: web app (HTML) and `POST /graphql?op=<operationName>`, the only data endpoint.
- `spc.n26.com` (Snowplow tracking) and `flags.n26.com` (Statsig feature flags): ignored, not needed.

## Calls (GraphQL, in order)

| Operation | Purpose | Response fixture |
| --- | --- | --- |
| `requestBiometricChallengeMutation` | login: `username`, `password`, `fp`, `fpc`, `requestId` → `challengeType: "PUSH"` | `login-request-biometric-challenge.json` |
| `verifyLoginWithPushMutation` | polling (about every 2 s) until confirmed in the app: `isAuthorizationPending`, `shouldAbortLoginAttempt`, `rateLimit {limit: 60, current}` | `login-verify-push-pending.json`, `login-verify-push-success.json` |
| `getTransactionsList(accountId)` | feed: `balance` ("Aktueller Kontostand", current balance), `activities` (account switcher), `modules[FeedTimelineModule]` (first page + `paginationKey`) | `feed-main.json`, `feed-space-1.json`, `feed-space-2.json`, `feed-all.json` |
| `getTimeline(paginationKey, activity, accountId)` | next (older) page: `timelineItems`, `paginationKey` (`null` = end) | `timeline-main-page2.json` |

Queries verbatim: `*.graphql` (the connector sends `getTransactionsList` and `getTimeline` unchanged).

## Request
- `POST https://app.n26.com/graphql?op=<operationName>`, `Content-Type: application/json`
- Headers: `csrf-token`, `x-requested-with: XMLHttpRequest`, `Origin`, `Referer` (`/login` or `/feed/transactions/<accountId>`).
- `csrf-token` is **not** the cookie `n26.csrf` but the content of `<meta name="csrf-token" content="…">` (36 characters) in the HTML.
- Body: `{"operationName": …, "variables": {"payload": "<SJCL-JSON>"}, "query": …}`

### Encrypted variables (`variables.payload`)
The web app encrypts **all** variables (bundle chunk `1917`, `client.*.js` → `window.__PEK__`):

```js
sjcl.encrypt(new sjcl.ecc.elGamal.publicKey(sjcl.ecc.curves.c384, sjcl.codec.base64.toBits(window.__PEK__)),
             JSON.stringify(variables), { ts: 128, ks: 256, adata: Date.now().toString() })
```

- `window.__PEK__`: Base64, 96 bytes = x‖y of a P-384 point, present in the HTML of every page (also anonymously on `/login`).
- KEM: random scalar d, `kemtag` = d·G (x‖y, Base64), key = SHA-256(x‖y of d·PEK). AES-256-CCM, IV 16 bytes
  (CCM uses 15 − L bytes), tag 128 bit, `adata` = timestamp in ms as text.
- Payload form (key order as in SJCL):
  `{"iv":"<24>","v":1,"iter":10000,"ks":256,"ts":128,"mode":"ccm","adata":"<Base64 ms>","cipher":"aes","kemtag":"<128>","ct":"<…>"}`
- If the server rejects a payload (not `ok`), it answers with `{"key": "<new PEK>"}`; the app sets `__PEK__` anew
  and retries once (status not recorded).
- Variables (derived from the lengths of `ct`; plaintext is not visible):
  - `getTransactionsList`: `{"accountId":"<uuid>"}` (account/space) or `{"accountId":null}` ("Alle Aktivitäten")
  - `getTimeline`: `{"paginationKey":"<key>","accountId":"<uuid>"}` (without `activity`)

## Responses (plaintext JSON)
- Feed: `balance.money = {unscaledAmount: "<minor units as string>", currency: {code, decimals}}`.
- `activities.values[]`: `title`, `accountId` (UUID, `null` for "Alle Aktivitäten"), `tracking.label` `ALL` / `MAIN` / `SPACE`.
- `timelineItems[]`: `FeedTimelineGroupHeading` (day/year heading) and `FeedTimelineTransaction`:
  `externalId` (UUID), `accountId`, `title` (counterparty), `tintedSubtitle.elements[].value` (purpose/"Online"),
  `secondarySubtitle` ("Von Hauptkonto" in "Alle Aktivitäten"), `styledAmount.money` (signed), `timestamp`
  (ms, booking/payment time), `category` (`micro-v2-…`), `balance` (balance afterwards, float), `icon` (`CATEGORY`/`MERCHANT`,
  `statusIcon` e.g. `installment_eligible.png`), `deeplink`.
- `paginationKey`: Base64 JSON `{"transaction":{"lastId":"<uuid>"},"lastBalance":<float>,"lastItemTs":<ms>,"pageIndex":<n>}`.
- No IBAN, no SEPA fields (EREF/MREF/creditor ID), no separate value date in the feed.

## Login and session
- Login page `https://app.n26.com/login`: form `input[name=username]` (type email, id `email`), `input[name=password]`
  (id `password`), hidden `fp`, `fpc`, `requestId` (filled by the app), button `data-testid="login-button"`,
  error containers `#login-errors`, `#abort-login-attempt-errors`, push fallback button `data-testid="verify-login-push-poll-button"`.
- Cookies (names only): `n26.csrf`, `n26.fp`, `n26.mfa_token` / `n26.mfa_recovery` (300 s, during login),
  after approval `n26.token` (Max-Age 900 s), `num26refresh` (7200 s), `num26expires_at` (900 s), all HttpOnly; plus
  `num26UniqueDeviceToken`, `n26.timezone*`, `num26locale`, `num26DarkMode`, `n26.render_js_version`, Snowplow `_sp_*`.
- Expired session: the web app treats the GraphQL error `message == "401 Unauthorized"` as logout (bundle);
  HTTP status for this not recorded.

## Gaps (not in the HAR)
- Pending card payments: none in the capture, marking unknown.
- Response of an expired session (status/body), response when the payload key is rejected.
- Whether `num26refresh` returns a new `n26.token` when a page loads.
- Feed page 3 of the main account, page 2 of Space 01, feed with `FeedPendingModule`/`FeedRecurringModule`.
- Wrong password (content of `#login-errors`), SMS fallback without a paired device.
