# Fixtures C24 (web banking JSON)

Created by a human (Safari → Developer → Network), anonymized and altered with `scripts/fixtures-scrub` (amounts, dates, IDs). Agents only read them.

| File | Content | Status |
| --- | --- | --- |
| `endpoints.md` | Calls, header names, cookie names, request body of the transaction search, gaps | present |
| `accounts.json` | `GET /api/user/me/accounts/internal/`: accounts + pockets with balances | present |
| `pockets.json` | `GET /api/v3/pockets/` | present (`id` is the same after anonymization; the connector uses `pocket_number`) |
| `transactions-page1.json`, `transactions-page2.json` | `POST /api/v3/transactions/search/`, Pocket Plus, offset 0/30 | present, **booked only** |
| `transactions-other-pocket-page1.json` | same, other pocket with card payments | present |
| `upcoming-transactions.json` | `GET /api/v2/upcoming-transactions/`: standing orders, announced direct debits | present |
| `balance.json` | – | not needed (balances are in `accounts.json`) |
| `transactions-giro-page1.json` | transaction search for a current account (`account_numbers` = account number of the smart account) | **missing** |
| `transactions-preliminary.json` | transaction search with a pending card payment (`preliminary: true`), foreign currency if possible; the same payment later booked | **missing** |
| `session-expired.json` | status and body of an API call after about 15 min of inactivity | **missing** |
| Login (in `endpoints.md`) | start URL, flow up to push approval, **where the web app stores the bearer token** (local/session storage key or response of a login call), format of the `x-c24-*` header values, value of `future_days` | **missing** |
