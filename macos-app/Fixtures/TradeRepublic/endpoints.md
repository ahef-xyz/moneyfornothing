# Trade Republic endpoints (web app, from HAR, anonymized)

Host `https://api.traderepublic.com`, web app `https://app.traderepublic.com`. Header and cookie values removed,
login request body (phoneNumber, pin) not carried over, `claims` and `qrCodePayload` removed.
WebSocket messages are not included in the HAR.

## Session
- Cookie-based. Request cookies (names): `JSESSIONID`, `aws-waf-token`, `mapper-lb-affinity`, `tr_claims`, `tr_device`, `tr_external_id`, `tr_locale`, `tr_refresh`, `tr_session`.
- Set-Cookie at login: `JSESSIONID`, `tr_claims`, `tr_device`, `tr_external_id`, `tr_refresh`, `tr_session`.
- Headers (names): `x-aws-waf-token`, `x-tr-app-version`, `x-tr-device-info`, `x-tr-platform`. `x-aws-waf-token` / cookie `aws-waf-token`: AWS WAF bot protection.
  A login without a browser will probably be blocked → login via WKWebView (`.webLogin`, completed when cookie `tr_session` appears).

## Login (web, v2)
1. `POST /api/v2/auth/web/login` body `{"phoneNumber","pin"}` → `{"processId", "claims"}` (→ `login.json`).
2. Poll `GET /api/v2/auth/web/login/processes/{processId}`; at first `status` open (→ `login-process-pending.json`),
   after approval in the app with `claims` + Set-Cookies (→ `login-process-done.json`). No 4-digit SMS code in the flow.
3. From the public web bundle (not in the HAR): headers `X-Tr-Platform: web-pro`, `X-TR-App-Version`,
   `X-TR-Device-Info` (Base64 JSON), `X-Aws-Waf-Token`. `requiredAction: AUTHENTICATOR_VERIFICATION` →
   `POST …/processes/{processId}/authenticator-verification` `{code}` (6 digits). Status `PENDING`/`CONFIRMED`/`COMPLETED`.
   Start error codes: `AUTHENTICATION_ERROR`, `INVALID_VALUE`, `NUMBER_INVALID`, `TOO_MANY_REQUESTS`,
   `WEBTRADING_NOT_AVAILABLE`, `LOGIN_NOT_ALLOWED`, `GEO_BLOCKED`, `DEVICE_NOT_FOUND`, `MOBILE_APP_VERSION_NOT_SUPPORTED`;
   polling: `PROCESS_GONE`, `ALREADY_PROCESSED`, `NOT_FOUND`, `TOO_MANY_REQUESTS`. Fallback only for `DEVICE_NOT_FOUND`/`MOBILE_APP_VERSION_NOT_SUPPORTED` (5xx/unknown code: abort, no second PIN entry):
   `POST /api/v1/auth/web/login` → `{processId, countdownInSeconds, "2fa"}`, then `POST /api/v1/auth/web/login/{processId}/{code}`.
4. Alternative: QR login via `GET /api/v2/auth/web/login/qr-challenges/{id}` (→ `login-qr-challenge.json`).

## Data (REST, no WebSocket needed)
- Accounts: `GET /api/v1/account-manager/accounts/switchable` (IBAN, account type) → `accounts-switchable.json`
- Card: `GET /api/v1/card/cards/home` → `cards-home.json`
- Interest: `GET /api/v1/interest-experience/interest/{cashAccountNumber}/info` → `interest-info.json`
- Transactions: `GET /api/v2/timeline/transactions` (first page without query), paging via `cursors.after` → `timeline-page1.json`
- Categories: `GET /api/v2/timeline/transaction-categories` → `timeline-transaction-categories.json`
- Orders: `GET /web-trading-gateway/api/customer/v1/orders?secAccNo&instrumentId&sort&page&pageSize` → `orders.json`
- Portfolio value history: `GET /api-gateway/portfolio-chart/v2/chart?secAccNo&range&currency&instrumentCategories` → `portfolio-chart.json`

## All calls to api.traderepublic.com (without OPTIONS)

| Method | Path | Query | Status | Type |
| --- | --- | --- | --- | --- |
| GET | `/api/v2/auth/web/login/qr-challenges/{id}` | – | 200 | application/json |
| POST | `/api/v2/auth/web/login` | – | 200 | application/json |
| GET | `/api/v2/auth/web/login/processes/{id}` | – | 200 | application/json |
| GET | `/api/v1/account-manager/accounts/switchable` | – | 200 | application/json |
| GET | `/api/v1/customer/app-usage-data-consents` | – | 200 | application/json |
| GET | `/api-gateway/pro-trading/api/v3/boards` | – | 200 | application/x-unknown-content-type |
| GET | `/api/v2/timeline/inbox/open` | – | 200 | application/json |
| GET | `/api/v2/timeline/inbox/closed` | – | 200 | application/json |
| GET | `/api/v1/survey/type/traderSelfCertification/results/latest` | – | 204 | application/x-unknown-content-type |
| GET | `/api-gateway/pro-trading/api/v1/user-preferences` | – | 200 | application/x-unknown-content-type |
| GET | `/api/v1/customer/personal-details` | – | 200 | application/json |
| POST | `/api-gateway/pro-trading/api/v3/boards` | – | 201 | text/xml |
| GET | `/api-gateway/portfolio-chart/v2/chart` | secAccNo,range,currency,instrumentCategories | 200 | text/xml |
| POST | `/api-gateway/pro-trading/api/v3/boards/{id}/widgets` | – | 201 | text/xml |
| GET | `/api-gateway/screeners/api/v2/screeners` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/screeners/api/v2/screeners/options` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/instrument-universe/api/v1/exchanges-details` | includeMaintenanceWindow | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/order-router/api/v2/instruments/US0378331005/destinations` | userId,productContext,lang,jurisdiction | 200 | application/x-unknown-content-type |
| PATCH | `/api-gateway/pro-trading/api/v3/boards/{id}/widgets/{id}` | – | 200 | text/xml |
| GET | `/api-gateway/instrument-universe/api/v1/exchanges/LSX/schedule` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/instrument-universe/api/v1/exchanges/TDG/schedule` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/instrument-universe/api/v1/exchanges/XFRA/schedule` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/instrument-universe/api/v1/exchanges/XLON/schedule` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/instrument-universe/api/v1/exchanges/XNAS/schedule` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/instrument-universe/api/v1/exchanges/TIB/schedule` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/instrument-universe/api/v1/exchanges/XETR/schedule` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/subscriptions/api/v1/entitlements/topics/L2` | exchangeId | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/subscriptions/api/v1/plans` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/subscriptions/api/v1/subscriptions` | – | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/subscriptions/api/v1/entitlements/topics/tickerV3` | exchangeId | 200 | application/x-unknown-content-type |
| GET | `/api-gateway/subscriptions/api/v1/entitlements/topics/tradeAggregateHistory` | exchangeId | 200 | application/x-unknown-content-type |
| GET | `/web-trading-gateway/api/customer/v1/orders` | secAccNo,instrumentId,sort,page,pageSize | 200 | application/json |
| GET | `/api/v1/card/cards/home` | – | 200 | application/json |
| GET | `/api/v1/interest-experience/interest/{id}/info` | – | 200 | application/json |
| GET | `/api/v2/timeline/transaction-categories` | – | 200 | application/json |
| GET | `/api/v2/timeline/transactions` | – | 200 | application/json |

## Gaps
- No securities positions (holding per ISIN): probably still via WebSocket (`compactPortfolio`), not in the HAR.
- No transaction detail (`action.payload` refers to it; detail endpoint not recorded).
- No second transaction page (query parameter for `cursors.after` unset, probably `after=`).
- No cash balance endpoint recorded.
