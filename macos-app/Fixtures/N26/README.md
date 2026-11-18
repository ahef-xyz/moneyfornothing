# Fixtures N26 (web app, GraphQL)

Source: Firefox HAR of the web app `app.n26.com` (provided by a human, 42 entries, not in the repo).
Extracted and anonymized by the N26 agent with a script outside the repo; **the human reviews the files before the merge.**

Anonymization:
- All UUIDs (account IDs, `externalId`, merchant logo IDs, also inside `paginationKey` and `deeplink`) replaced deterministically
  (same ID → same replacement across all files); placeholder UUIDs `00000000-0000-4000-8000-0000000000NN`
  stay unchanged.
- Counterparties → `Gegenpartei NN` (counterparty NN), Space names → `Space NN`, purposes → `Verwendungszweck NN`
  (generic texts such as "Online", "Von Hauptkonto" and "Hauptkonto" stay). `paginationKey` re-encoded in Base64.
- Afterwards `scripts/fixtures-scrub`: amounts, balances and timestamps are altered (factor/jitter, dates shifted by whole weeks,
  group headings and `paginationKey` adjusted); categories stay.
- Not carried over: cookies, header values, CSRF tokens, encrypted payloads (`ct`, `kemtag`, `iv`), tracking calls.
- Check: no cookie, CSRF or payload value, no original UUID, and no original name or purpose from the HAR appears in
  `Fixtures/N26/` or `Packages/MFNN26/` (exception: the counterparty "N26" itself, the bank name). The HAR contains
  username and password only encrypted (`ct` of `requestBiometricChallengeMutation`); these values were checked too.

| File | Content | Status |
| --- | --- | --- |
| `endpoints.md` | calls, headers, cookie names, encryption of the variables, login form, gaps | present |
| `getTransactionsList.graphql`, `getTimeline.graphql` | queries verbatim (the connector sends them unchanged) | present |
| `requestBiometricChallengeMutation.graphql`, `verifyLoginWithPushMutation.graphql` | login mutations (the web app sends them itself) | present |
| `login-request-biometric-challenge.json` | response `challengeType: PUSH` | present |
| `login-verify-push-pending.json`, `login-verify-push-success.json` | poll responses before/after approval | present |
| `feed-all.json` | `getTransactionsList` "Alle Aktivitäten" (`accountId: null`): account switcher | present |
| `feed-main.json` | main account, page 1 + `paginationKey` | present |
| `timeline-main-page2.json` | `getTimeline` main account page 2 (has another `paginationKey`) | present |
| `feed-space-1.json`, `feed-space-2.json` | Spaces (Space 02 has no further page) | present |
| `timeline-main-page3.json` / end | last page (`paginationKey: null`) | **missing** (tests: synthetic empty page) |
| `feed-pending.json` | feed with a pending card payment, the same payment later booked | **missing** (tests: derived via `statusIcon …/pending.png`) |
| `session-expired.json` | status and body of a `/graphql` call after more than 15 min | **missing** |
| `login-wrong-password.json` | response of `requestBiometricChallengeMutation` with wrong password | **missing** |
