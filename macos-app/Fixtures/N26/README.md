# Fixtures N26 (Web-App, GraphQL)

Quelle: Firefox-HAR der Web-App `app.n26.com` (vom Menschen bereitgestellt, 42 Einträge, nicht im Repo).
Extrahiert und anonymisiert vom N26-Agent mit einem Skript außerhalb des Repos; **der Mensch sichtet die Dateien vor dem Merge.**

Anonymisierung:
- Alle UUIDs (Konto-IDs, `externalId`, Händler-Logo-IDs, auch innerhalb `paginationKey` und `deeplink`) deterministisch
  ersetzt (gleiche ID → gleicher Ersatz über alle Dateien); Platzhalter-UUIDs `00000000-0000-4000-8000-0000000000NN`
  bleiben unverändert.
- Gegenparteien → `Gegenpartei NN`, Space-Namen → `Space NN`, Verwendungszwecke → `Verwendungszweck NN`
  (generische Texte wie „Online“, „Von Hauptkonto“, „Hauptkonto“ bleiben). `paginationKey` neu Base64-kodiert.
- Danach `scripts/fixtures-scrub`: Beträge, Salden und Zeitstempel sind verfremdet (Faktor/Jitter, Datum um ganze Wochen
  verschoben, Gruppenüberschriften und `paginationKey` angepasst); Kategorien bleiben.
- Nicht übernommen: Cookies, Header-Werte, CSRF-Token, verschlüsselte Payloads (`ct`, `kemtag`, `iv`), Tracking-Aufrufe.
- Prüfung: kein Cookie-/CSRF-/Payload-Wert, keine Original-UUID, kein Originalname oder -zweck aus dem HAR kommt in
  `Fixtures/N26/` oder `Packages/MFNN26/` vor (Ausnahme: die Gegenpartei „N26“ selbst, der Bankname). Der HAR enthält
  Benutzername und Passwort nur verschlüsselt (`ct` von `requestBiometricChallengeMutation`); diese Werte sind ebenfalls geprüft.

| Datei | Inhalt | Status |
| --- | --- | --- |
| `endpoints.md` | Aufrufe, Header, Cookie-Namen, Verschlüsselung der Variablen, Login-Formular, Lücken | vorhanden |
| `getTransactionsList.graphql`, `getTimeline.graphql` | Queries im Wortlaut (Connector sendet sie unverändert) | vorhanden |
| `requestBiometricChallengeMutation.graphql`, `verifyLoginWithPushMutation.graphql` | Login-Mutations (sendet die Web-App selbst) | vorhanden |
| `login-request-biometric-challenge.json` | Antwort `challengeType: PUSH` | vorhanden |
| `login-verify-push-pending.json`, `login-verify-push-success.json` | Poll-Antworten vor/nach Freigabe | vorhanden |
| `feed-all.json` | `getTransactionsList` „Alle Aktivitäten“ (`accountId: null`): Kontoumschalter | vorhanden |
| `feed-main.json` | Hauptkonto, Seite 1 + `paginationKey` | vorhanden |
| `timeline-main-page2.json` | `getTimeline` Hauptkonto Seite 2 (hat weiteren `paginationKey`) | vorhanden |
| `feed-space-1.json`, `feed-space-2.json` | Spaces (Space 02 ohne weitere Seite) | vorhanden |
| `timeline-main-page3.json` / Ende | letzte Seite (`paginationKey: null`) | **fehlt** (Tests: synthetische leere Seite) |
| `feed-pending.json` | Feed mit vorgemerkter Kartenzahlung, dieselbe Zahlung später gebucht | **fehlt** (Tests: abgeleitet über `statusIcon …/pending.png`) |
| `session-expired.json` | Status + Body eines `/graphql`-Aufrufs nach > 15 min | **fehlt** |
| `login-wrong-password.json` | Antwort von `requestBiometricChallengeMutation` bei falschem Passwort | **fehlt** |
