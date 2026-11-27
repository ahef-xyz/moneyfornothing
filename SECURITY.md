# Security policy

MFN handles banking credentials and financial data, so security reports are taken seriously.

**Please report vulnerabilities privately** by e-mail to **hi@ahef.xyz**. Do not open a public issue
for security problems. Include what you found, how to reproduce it and the affected version.
Never send real credentials, account numbers or transactions; anonymise any samples.

You can expect an acknowledgement and an assessment; fixes ship in the next release and are
credited if you wish. Only the latest release is supported.

In scope: leaks of credentials, session data, database keys or personal data; weaknesses in the
database encryption, app lock or Keychain handling; anything that could make MFN act on an account
instead of only reading it.

## Banks over YAXI (from 0.7.0)

Opt-in per bank. MFN talks to YAXI (`api.yaxi.tech`, `integration.yaxi.tech` for test keys) through YAXI's
client `routex-client-swift` (pinned 0.6.2). The client verifies the AMD SEV-SNP attestation of YAXI's
enclave and seals every request and response with a key settled with that enclave, so YAXI's staff and its
data centre cannot read credentials, consent or results. The user's own YAXI API key lives only in the
Keychain (never in a backup); MFN issues the short-lived tickets on the Mac and runs no server. Tickets
exist only for the accounts, balances and transactions services; a test fails if code for transfers or
payment collection appears. Results of the consent flow are HS256 JWTs and are checked with the key and
the ticket ID. The bank login stays in the Keychain like other bank logins and is only sent when the bank
wants a new consent; the consent itself (`ConnectionData`) is in the Keychain too. Bank logos come from
`logos.yaxi.tech` (no cookies, that host only, PNG, size cap; off with "Load Bank Icons from Websites" / "Bank-Symbole von den Websites laden").

YAXI records web logs with masked IP addresses, records of service calls (kept up to seven years for fraud
investigation) and traces (90 days), see https://docs.yaxi.tech/diagnostics.html. MFN never sends YAXI a
diagnostic archive.

Also in scope: any way for MFN to issue a ticket beyond reading, to leak the YAXI key or consent, or to
accept an unattested or unsealed answer.

## AI assistants (MCP, from 0.6.0)

Off by default. When the user switches it on, MFN listens on a Unix socket (mode 0600) in its App Group
container. MCP clients start the helper `MFN.app/Contents/Helpers/mfn-mcp`, which only forwards messages;
it holds no data and cannot open the database. The app accepts a connection only from that helper,
checked by its code signature (same team, identifier `xyz.ahef.mfn.mcp`) through the peer's audit token.

What this does not prove is who started the helper: while access is on and MFN is unlocked, any process
of the same user could run it. MFN therefore asks the first time a program connects, naming the parent
process and its signature as the helper reads it. "Allow always" exists only for programs signed by a
known developer team; unsigned or ad hoc signed clients can be allowed once per session. Every call is
logged in the app (tool, count, outcome; never arguments or results), and locking closes every
connection.

All tools are read-only and never cause network traffic. IBANs, end-to-end and mandate references,
creditor IDs, bank IDs, fingerprints and raw bank data never leave; account and transaction IDs are
salted hashes. Counterparty names and purpose texts are written by third parties and are a prompt
injection path: they are returned in fields marked `_text_untrusted`, purposes are cut short, and the
tool descriptions say so. This lowers the risk, it does not remove it. Page size, period length and
calls per minute are capped.

Also in scope: any way to read MFN data over this channel without the user's approval, while MFN is
locked, or for accounts the user did not share.
