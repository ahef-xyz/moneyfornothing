# Trade Republic Endpunkte (Web-App, aus HAR, anonymisiert)

Host `https://api.traderepublic.com`, Web-App `https://app.traderepublic.com`. Header-/Cookie-Werte entfernt,
Login-Request-Body (phoneNumber, pin) nicht übernommen, `claims` und `qrCodePayload` entfernt.
WebSocket-Nachrichten sind im HAR nicht enthalten.

## Sitzung
- Cookie-basiert. Request-Cookies (Namen): `JSESSIONID`, `aws-waf-token`, `mapper-lb-affinity`, `tr_claims`, `tr_device`, `tr_external_id`, `tr_locale`, `tr_refresh`, `tr_session`.
- Set-Cookie beim Login: `JSESSIONID`, `tr_claims`, `tr_device`, `tr_external_id`, `tr_refresh`, `tr_session`.
- Header (Namen): `x-aws-waf-token`, `x-tr-app-version`, `x-tr-device-info`, `x-tr-platform`. `x-aws-waf-token`/Cookie `aws-waf-token`: AWS-WAF-Bot-Schutz –
  ein Login ohne Browser wird voraussichtlich geblockt → Login per WKWebView (`.webLogin`, Abschluss bei Cookie `tr_session`).

## Login (Web, v2)
1. `POST /api/v2/auth/web/login` Body `{"phoneNumber","pin"}` → `{"processId", "claims"}` (→ `login.json`).
2. `GET /api/v2/auth/web/login/processes/{processId}` pollen; zunächst `status` offen (→ `login-process-pending.json`),
   nach Freigabe in der App mit `claims` + Set-Cookies (→ `login-process-done.json`). Kein 4-stelliger SMS-Code im Ablauf.
3. Aus dem öffentlichen Web-Bundle (nicht im HAR): Header `X-Tr-Platform: web-pro`, `X-TR-App-Version`,
   `X-TR-Device-Info` (Base64-JSON), `X-Aws-Waf-Token`. `requiredAction: AUTHENTICATOR_VERIFICATION` →
   `POST …/processes/{processId}/authenticator-verification` `{code}` (6 Ziffern). Status `PENDING`/`CONFIRMED`/`COMPLETED`.
   Fehlercodes Start: `AUTHENTICATION_ERROR`, `INVALID_VALUE`, `NUMBER_INVALID`, `TOO_MANY_REQUESTS`,
   `WEBTRADING_NOT_AVAILABLE`, `LOGIN_NOT_ALLOWED`, `GEO_BLOCKED`, `DEVICE_NOT_FOUND`, `MOBILE_APP_VERSION_NOT_SUPPORTED`;
   Pollen: `PROCESS_GONE`, `ALREADY_PROCESSED`, `NOT_FOUND`, `TOO_MANY_REQUESTS`. Fallback nur bei `DEVICE_NOT_FOUND`/`MOBILE_APP_VERSION_NOT_SUPPORTED` (5xx/unbekannter Code: Abbruch, keine zweite PIN-Eingabe):
   `POST /api/v1/auth/web/login` → `{processId, countdownInSeconds, "2fa"}`, dann `POST /api/v1/auth/web/login/{processId}/{code}`.
4. Alternative: QR-Login über `GET /api/v2/auth/web/login/qr-challenges/{id}` (→ `login-qr-challenge.json`).

## Daten (REST, keine WebSocket nötig)
- Konten: `GET /api/v1/account-manager/accounts/switchable` (IBAN, Kontotyp) → `accounts-switchable.json`
- Karte: `GET /api/v1/card/cards/home` → `cards-home.json`
- Zinsen: `GET /api/v1/interest-experience/interest/{cashAccountNumber}/info` → `interest-info.json`
- Umsätze: `GET /api/v2/timeline/transactions` (erste Seite ohne Query), Paging über `cursors.after` → `timeline-page1.json`
- Kategorien: `GET /api/v2/timeline/transaction-categories` → `timeline-transaction-categories.json`
- Orders: `GET /web-trading-gateway/api/customer/v1/orders?secAccNo&instrumentId&sort&page&pageSize` → `orders.json`
- Depotwert-Verlauf: `GET /api-gateway/portfolio-chart/v2/chart?secAccNo&range&currency&instrumentCategories` → `portfolio-chart.json`

## Alle Aufrufe auf api.traderepublic.com (ohne OPTIONS)

| Methode | Pfad | Query | Status | Typ |
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

## Lücken
- Keine Depotpositionen (Bestand je ISIN): vermutlich weiter per WebSocket (`compactPortfolio`), im HAR nicht enthalten.
- Kein Umsatzdetail (`action.payload` verweist darauf; Detail-Endpunkt nicht aufgezeichnet).
- Keine zweite Umsatzseite (Query-Parameter für `cursors.after` unbelegt, vermutlich `after=`).
- Kein Cash-Saldo-Endpunkt aufgezeichnet.
