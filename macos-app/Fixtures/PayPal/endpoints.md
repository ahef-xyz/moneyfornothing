# PayPal web (www.paypal.com)

Source: two HAR recordings by the human (2026-11-22, `raw/`, gitignored, never commit). This file
holds structure only: paths, field names, value formats.

## Fixtures

Made from the second recording on the human's instruction ("copy, anony. and go for it"): the real
structure and PayPal's own enum values and UI texts, **every name, amount, date, e-mail and
identifier invented** (amounts random, dates shifted by whole weeks, IDs regenerated; checked that
no recorded value is in a file).

| File | Content |
| --- | --- |
| `summary.html` | `GET /myaccount/summary` reduced to the script element with the balances |
| `activities.html` | `GET /myaccount/activities/` reduced to the element with the encoded page state (`_csrf`) |
| `activities-filter.json` | `GET /myaccount/activities/filter`: 22 rows, every recorded type, EUR and USD, the fields the connector reads and their neighbours |

## Login

| Step | Request | Notes |
| --- | --- | --- |
| Password | `POST /signin`, form encoded | fields among others `_csrf`, `_sessionID`, `login_email`, `splitLoginContext`, `fn_sync_data` (device fingerprint); answer JSON with `captcha`, `adsChallengeUrl`, `dpopKey` |
| reCAPTCHA Enterprise | `POST /auth/verifygrcenterprise` | `grcV3EntToken`, `publicKey`, `_csrf`, `_sessionID` |
| Second factor (authenticator app) | `GET /authflow/challenges/softwareToken/`, then `PUT /authflow/challenges/softwareToken`, JSON | `answer`, `anw_sid`, `authflowDocumentId`, `selectedChallengeType`, `fn_sync_data` |
| Done | redirect to `GET /myaccount/summary` | |

Side requests: `ddbm2.paypal.com/js/`, `c.paypal.com/v1/r/d/b/…` (device and bot checks),
`www.recaptcha.net`. Cookies include `datadome`, `id_token`, `nsid`, `x-pp-s`, `ts`, `ts_c`, `tsrce`,
`rssk`, `l7_az`, `X-PP-ADS`, `fn_dt`, `d_id` and several with random names.

Consequence: no headless login. The connector asks for the visible web login (`WebLoginRequest`
without `automation`, done at `https://www.paypal.com/myaccount…`) and takes the cookies of
`paypal.com` plus `navigator.userAgent`.

## Data (all GET)

**`/myaccount/summary`** (HTML). `<script id="reactContainer__balance_props" type="application/json">`
holds `balance.balance`: `primaryCurrency`, `totalAvailable { amount: "152.37", currency }`,
`balances[] { id, currency, availableBalance { total { amount, currency }, subBalances[] },
pendingBalance, reservedBalance }`. Amounts are decimal strings with a dot.

**`/myaccount/activities/`** (HTML). `<div id="__react_data__" data="…" data-isEncoded="yes">`: `data`
is base64 of the page state (JSON); its `_csrf` is the token of the calls below. A new page load
gives a new token.

**`/myaccount/activities/filter?q=…`** (JSON). `q` is base64 of the filter form:
`free_text_search=&start_date=2026-01-01&end_date=2026-03-31&type=&status=&currency=&filter_id=&issuance_product_name=&asset_names=&asset_symbols=`.
Headers: `Accept: application/json`, `X-Requested-With: XMLHttpRequest`, `x-csrf-token`.
Answer `data.data.activity`: `noOfTransactions`, `currencyCodes`, `transactions[]`. The two recorded
answers held 20 and 130 rows for their ranges, without any paging field.

One row: `id` (17 characters; `primitiveTxnId` and `legId` were always the same), `type`, `status`,
`date.rawDate { date: "2026-01-01T12:00:00.000Z", timeZone: "Europe/Berlin" }`,
`amounts.currencyCode`, `amountInfo.contents.amountText` (`"&minus;188,67 €"`, `"+12,00 €"`,
`"&minus;101,25 $ USD"`; non-breaking space), `amountInfo.classNames.transactionAmountClassName`
(contains `isCredit` for money received), `counterpartyInfo.counterpartyName`,
`descriptionInfo.content.transactionDescriptionText` (`"9. Sept. . Zahlung"`), `notesInfo.notes`,
`ftsSearchInfo { displayType, counterparty, email, displayAmount, date }`, `linksInfo.detailsLink`.

Recorded values: `status` only `COMPLETED`; `type` `PAYMENT`, `PRE_APPROVED_PAYMENT`,
`SEND_MONEY_SENT`, `SEND_MONEY_RECEIVED`, `REFUND`, `TRANSFER_TO_BANK`, `INSTANT_TRANSFER_TO_BANK`,
`DONATION_SENT`, `CONTRIBUTION_SENT`; currencies EUR and USD (USD rows although the account holds
only a EUR balance: converted payments).

**`/myaccount/activities/details/inline/{id}`** (JSON, first recording, not used yet). `data` with
`timeCreatedInISO`, `status`, `transactionTypeEnum` (`PAYMENT_SENT`), `moneyFlowDirection`,
`amount.rawAmounts.gross`, `counterparty { name, email, url, isBusiness }`,
`fundingSource.fundingSourceList[] { type: BANK_ACCOUNT, last4, institution, amount, currencyCode }`.
`fundingSource` is what would link a PayPal payment to the direct debit in the bank account, and
the funding amount is what a foreign-currency payment cost.

Also seen, not used: `/myaccount/activities/widget` (newest 6 rows, no dates),
`/myaccount/activities/extendSession`, `/myaccount/activities/api/statements`, `/reports/` (the
activity download; its own request was not recorded).

## Missing

- **A pending, a denied and a refunded payment**: the status names other than `COMPLETED` are guesses.
- **An expired session**: status and body of a request after the session timed out. The connector
  assumes the login page (or 401/403).
- **A range with more rows than PayPal sends at once**, if there is such a limit.
- **The detail of a payment in a foreign currency**, to read what it cost in the account's currency.

## Seen live (2026-11-22)

Requests from the app with the login's cookies and user agent are answered (summary page, activity
page, list). A burst is not: eleven list requests within 14 seconds went through, then the activity
pages stopped answering (no status, timeout) while the summary page still did. The connector asks
for one year per request and pauses between requests.
