# Fixtures easybank (ex Barclays, web banking JSON + CSV)

Created by a human (Safari → Developer → Network), anonymized and altered with `scripts/fixtures-scrub` (amounts, dates, IDs).

| File | Content | Status |
| --- | --- | --- |
| `endpoints.md` | method, path, flow, cookie/header names, gaps | present |
| `cards.json` | landing `Item`: `AccountListResponse` + `DashboardTransactionItemList` (one card, no partner card) | present |
| `account-transaction-history(-request).json` | open card account: statement data + current/pending transactions, without OTP | present |
| `get-transactions-request.json`, `get-transactions-otp-required.json`, `transactions-page1.json` | transaction history (OTP, 50 per page) | present |
| `send-otp.json` | response of `SendOTP` | present (request body missing) |
| `transaction-detail(-request).json` | transaction detail | present (not used by the connector) |
| `cash-depot-account-list.json` | savings/securities account list | present (empty) |
| `retail-landing.json` | complete `RetailLanding` response + request body | missing (the test builds the wrapper around `cards.json`) |
| `send-otp-request.json`, `transactions-page2(-request).json` | OTP request, following page (paging) | missing |
| `statements.json` | statement list (period, due date, amount, PDF) | missing |
| `export.csv` | CSV export of transactions from the app/web banking | missing |
| Savings account | non-empty `GetCashDepotAccountList` + transactions | missing |
