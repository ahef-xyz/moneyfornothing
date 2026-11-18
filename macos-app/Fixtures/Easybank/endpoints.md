# easybank endpoints (from Safari HAR, anonymized)

Host: `https://banking.easybank.de`. Header and cookie values removed; login request bodies not carried over.

## Session
- Request headers (names only): `accept`, `accept-encoding`, `accept-language`, `content-length`, `content-type`, `cookie`, `dl`, `keepreferrer`, `keepstate`, `origin`, `pcid`, `priority`, `referer`, `request-id`, `sec-fetch-dest`, `sec-fetch-mode`, `sec-fetch-site`, `uniquekey`, `user-agent`, `x-requested-with`, `x-xsrf-token`.
- Cookie names: `ARRAffinity`, `ARRAffinitySameSite`, `ASP.NET_SessionId`, `FedAuth`, `VB_BTID`, `XSRF-TOKEN`, `__RequestVerificationToken`, `ab.storage.deviceId.9d9e94f9-b9f3-41a2-8f01-3ed6f1c0074e`, `ab.storage.sessionId.9d9e94f9-b9f3-41a2-8f01-3ed6f1c0074e`, `ab.storage.userId.9d9e94f9-b9f3-41a2-8f01-3ed6f1c0074e`, `ai_session`, `ai_user`.

## Calls (unique, in order of first appearance)

| Method | Path | Query | Status | Type |
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

Third parties (tracking, irrelevant for the connector): `northeurope-0.in.applicationinsights.azure.com`, `sdk.fra-02.braze.eu`, `whn11ewowu.crashninja.net`, `www.googletagmanager.com`.

## Flow
1. Login: `POST /services/flow/LoginTransaction` → `POST /services/flow/logintransaction/firstlevel/next` (app approval) → `POST /call/flow/Login/AfterLogin`.
2. Overview: `POST /services/flow/RetailLanding`. It contains in `Item.InitialCallResponses[].Response.Item.AccountListResponse.AccountList[]`
   the card accounts (→ `cards.json`) and `DashboardTransactionItemList`.
3. Open card account: `POST /services/flow/AccountTransactionHistory` with the complete `Account` object from the account list
   (→ `account-transaction-history-request.json` / `account-transaction-history.json`).
4. Transactions: `POST /call/directive/TransactionViewDirective/GetTransactions` (body: flow flags + `Account`, see `get-transactions-request.json`).
   The first call returns `Item.OTPRequired: true` without transactions (→ `get-transactions-otp-required.json`),
   then `POST /call/directive/VbOtpboxDirective/SendOTP` (→ `send-otp.json`, `Password`/`Reference` removed),
   then `GetTransactions` again → 50 transactions, `HasMore: true` (→ `transactions-page1.json`).
5. Transaction detail: `POST /services/flow/AccountTransactionDetail` with `Account` + complete `Transaction` object from the list
   (→ `transaction-detail-request.json` / `transaction-detail.json`; `TwoFactorAuthentication.Password` removed).

## Transaction status
`IsPending` was `false` in all 50 transactions. The status is in `TransactionType`: `Billed` (settled), `Unbilled`
(booked, not yet settled), `Pending` (pending/authorized). `TransactionNature`: `Debit`/`Credit`.

## Gaps
- No second page (`HasMore: true`, follow-up call not recorded): paging parameter unknown.
- No statement list (`statements.json`), no CSV export (`export.csv`).
- Unclear what triggers the OTP step (period longer than 90 days? every call?).
- Expired session not recorded.
