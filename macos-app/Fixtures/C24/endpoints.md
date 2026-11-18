# C24 endpoints (from Safari HAR, anonymized)

Recorded after login (push TAN not included). Header values and cookie values removed, request bodies anonymized.

## Authentication
- Every API call carries `Authorization: Bearer <token>` (value removed). Additional headers: `x-c24-guid`, `x-c24-timestamp`, `x-c24-tracingsession`, `x-c24-unicorn-guid`.
- Cookie names (names only): `c24Cookies_v1`, `c24GDPR_v1`, `cid_v1`, `devicetype_v1`, `keyword_v1`, `matchtype_v1`, `source_v1`. There is no session cookie among them; the session depends on the bearer token.

## Calls (unique, in order of first appearance)

| Method | URL | Query parameters | Status | Type |
| --- | --- | --- | --- | --- |
| POST | `api.c24.de/api/webconfig.json` | – | 200 | application/json |
| POST | `banking.c24.de/cdn-cgi/rum` | – | 204 | text/plain |
| GET | `api.c24.de/api/user/userprofile/` | – | 200 | application/json |
| GET | `api.c24.de/api/v2/user/me/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/me/accounts/internal/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/me/accounts/external/` | – | 200 | application/json |
| GET | `api.c24.de/api/geldanlage/v2/fixed-deposit/account/list` | – | 200 | application/json |
| GET | `api.c24.de/api/transaction-categories/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/me/current-account-plan/cashback/` | – | 200 | application/json |
| GET | `api.c24.de/api/interest-center/` | – | 200 | application/json |
| GET | `api.c24.de/api/v2/upcoming-transactions/` | future_days | 200 | application/json |
| GET | `api.c24.de/api/v3/pockets/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/me/current-account-plan/` | – | 200 | application/json |
| GET | `api.c24.de/api/web/km-mw/api/c24bank/bank-interface-service/v1/financialData/bankConnections/` | app_name | 200 | application/json |
| GET | `api.c24.de/api/user/sca/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/sso/` | – | 200 | application/json |
| GET | `api.c24.de/api/user/profile-picture/view/{id}.png` | – | 200 | image/png |
| GET | `api.c24.de/api/account/{account_number}/overdraft/settings/` | – | 200 | application/json |
| GET | `api.c24.de/api/etl/product-api/{id}/tax-exemption` | – | 204 | application/octet-stream |
| POST | `api.c24.de/api/v3/transactions/search/` | – | 200 | application/json |

## Flow when clicking
- Overview (after login): `webconfig.json`, `user/me`, `accounts/internal`, `accounts/external`, `v3/pockets`, `v2/upcoming-transactions?future_days`, …
- Transactions of an account/pocket: `POST /api/v3/transactions/search/`, paging via `pagination.offset` (+30), ends when `pagination.more == false`.

## Request body `POST /api/v3/transactions/search/` (example, anonymized)
```json
{
  "criteria": {
    "account_numbers": [
      "3238114929"
    ]
  },
  "pagination": {
    "limit": 30,
    "offset": 30
  }
}
```

## Gaps
- No current account transactions recorded (all three searches concern pockets).
- No pending transactions (`preliminary: true` did not occur).
- No response for an expired session (`session-expired.json` missing).
- No dedicated balance endpoint: balances are in `accounts/internal` (`total_balance`, `available_balance`, `hold_balance`).
