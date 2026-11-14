# easybank Endpunkte (aus Safari-HAR, anonymisiert)

Host: `https://banking.easybank.de`. Header- und Cookie-Werte entfernt; Login-Request-Bodies nicht übernommen.

## Sitzung
- Request-Header (nur Namen): `accept`, `accept-encoding`, `accept-language`, `content-length`, `content-type`, `cookie`, `dl`, `keepreferrer`, `keepstate`, `origin`, `pcid`, `priority`, `referer`, `request-id`, `sec-fetch-dest`, `sec-fetch-mode`, `sec-fetch-site`, `uniquekey`, `user-agent`, `x-requested-with`, `x-xsrf-token`.
- Cookie-Namen: `ARRAffinity`, `ARRAffinitySameSite`, `ASP.NET_SessionId`, `FedAuth`, `VB_BTID`, `XSRF-TOKEN`, `__RequestVerificationToken`, `ab.storage.deviceId.9d9e94f9-b9f3-41a2-8f01-3ed6f1c0074e`, `ab.storage.sessionId.9d9e94f9-b9f3-41a2-8f01-3ed6f1c0074e`, `ab.storage.userId.9d9e94f9-b9f3-41a2-8f01-3ed6f1c0074e`, `ai_session`, `ai_user`.

## Aufrufe (eindeutig, Reihenfolge des ersten Auftretens)

| Methode | Pfad | Query | Status | Typ |
| --- | --- | --- | --- | --- |
| GET | `/services/customstaticdata/GetApplicationParameters` | v | 200 | application/json |
| GET | `/services/staticdata/ConfigurationParameterList` | v | 200 | application/json |
| GET | `/services/staticdata/GetResourceList` | v,cultureCode | 200 | application/json |
| POST | `/services/flow/LoginTransaction` | – | 200 | application/json |
| GET | `/Features/wwwroot/common.402a884bd76ad6d8385b.1.js` | – | 200 | application/x-javascript |
| GET | `/Features/wwwroot/86.402a884bd76ad6d8385b.1.js` | – | 200 | application/x-javascript |
| POST | `/services/flow/logintransaction/firstlevel/next` | – | 200 | application/json |
| POST | `/call/flow/Login/AfterLogin` | – | 200 | application/json |
| POST | `/services/flow/RetailLanding` | – | 200 | application/json |
| POST | `/call/directive/DashboardProductTabDirective/GetCashDepotAccountList` | – | 200 | application/json |
| POST | `/services/flow/AccountTransactionHistory` | – | 200 | application/json |
| POST | `/call/directive/TransactionViewDirective/GetTransactions` | – | 200 | application/json |
| POST | `/call/directive/VbOtpboxDirective/SendOTP` | – | 200 | application/json |
| POST | `/call/flow/SecureInboxManagementDashboard/GetUnreadMessageCount` | – | 200 | application/json |
| POST | `/services/flow/AccountTransactionDetail` | – | 200 | application/json |

Drittanbieter (Tracking, für den Connector irrelevant): `northeurope-0.in.applicationinsights.azure.com`, `sdk.fra-02.braze.eu`, `whn11ewowu.crashninja.net`, `www.googletagmanager.com`.

## Ablauf
1. Login: `POST /services/flow/LoginTransaction` → `POST /services/flow/logintransaction/firstlevel/next` (App-Freigabe) → `POST /call/flow/Login/AfterLogin`.
2. Übersicht: `POST /services/flow/RetailLanding` – enthält in `Item.InitialCallResponses[].Response.Item.AccountListResponse.AccountList[]`
   die Kartenkonten (→ `cards.json`) und `DashboardTransactionItemList`.
3. Kartenkonto öffnen: `POST /services/flow/AccountTransactionHistory` mit dem kompletten `Account`-Objekt aus der Kontenliste
   (→ `account-transaction-history-request.json` / `account-transaction-history.json`).
4. Umsätze: `POST /call/directive/TransactionViewDirective/GetTransactions` (Body: Flow-Flags + `Account`, siehe `get-transactions-request.json`).
   Erster Aufruf liefert `Item.OTPRequired: true` ohne Umsätze (→ `get-transactions-otp-required.json`),
   dann `POST /call/directive/VbOtpboxDirective/SendOTP` (→ `send-otp.json`, `Password`/`Reference` entfernt),
   dann erneut `GetTransactions` → 50 Umsätze, `HasMore: true` (→ `transactions-page1.json`).
5. Umsatzdetail: `POST /services/flow/AccountTransactionDetail` mit `Account` + komplettem `Transaction`-Objekt aus der Liste
   (→ `transaction-detail-request.json` / `transaction-detail.json`; `TwoFactorAuthentication.Password` entfernt).

## Umsatzstatus
`IsPending` war in allen 50 Umsätzen `false`. Der Status steckt in `TransactionType`: `Billed` (abgerechnet), `Unbilled`
(gebucht, noch nicht abgerechnet), `Pending` (vorgemerkt/autorisiert). `TransactionNature`: `Debit`/`Credit`.

## Lücken
- Keine zweite Seite (`HasMore: true`, Folgeaufruf nicht aufgezeichnet) – Paging-Parameter unbekannt.
- Keine Abrechnungsliste (`statements.json`), kein CSV-Export (`export.csv`).
- Unklar, wodurch der OTP-Schritt ausgelöst wird (Zeitraum > 90 Tage? jeder Abruf?).
- Abgelaufene Sitzung nicht aufgezeichnet.
