# Email Cleaner — Design Spec

**Date:** 2026-05-03
**Status:** Approved (Phase A)

## Goal

A Ruby CLI tool that audits the user's Gmail and helps unsubscribe from
newsletters and bulk senders. The broader aim is opting out of the attention
economy: identify recurring noise, act on it in bulk, and progressively make
the inbox useful.

This spec covers **Phase A**: a working CLI with two subcommands (`audit`,
`unsubscribe`) and a YAML-backed state file recording unsubscribe attempts.
Phase B (persistence in SQLite, trends/history over time, scheduled runs) is
out of scope for this spec but is explicitly accommodated by Phase A's
architecture — `State`, `Aggregator`, and the data-flow seams are designed so
Phase B is an extension, not a rewrite.

## Non-Goals (Phase A)

- No SQLite or any database. State is YAML.
- No scraping of unsubscribe web pages. https-only links are surfaced for the
  user to click manually.
- No third-party unsubscribe services.
- No data stored outside the project directory.
- No trend reporting, history, diffs across runs.
- No tests for the OAuth browser flow or for CLI subcommand dispatch glue.

## Project Layout

```
email_cleaner/
├── Gemfile
├── Gemfile.lock
├── README.md                  # setup steps (Google Cloud, OAuth, etc.)
├── Rakefile                   # default task: test
├── .gitignore                 # credentials.json, token.yaml, unsubscribed.yaml, unsubscribe.log
├── bin/
│   └── email_cleaner          # executable; parses subcommand, dispatches
├── lib/
│   └── email_cleaner/
│       ├── version.rb
│       ├── cli.rb             # OptionParser, subcommand dispatch
│       ├── config.rb          # paths: credentials.json, token.yaml, unsubscribed.yaml, log
│       ├── auth.rb            # OAuth flow, loopback server on :8765, token caching
│       ├── gmail_client.rb    # thin wrapper: list_message_ids, fetch_metadata_batched
│       ├── headers.rb         # parse From, List-Unsubscribe, List-Unsubscribe-Post
│       ├── sender.rb          # value object: address, name, domain
│       ├── aggregator.rb      # group messages → SenderStats
│       ├── pattern_matcher.rb # @domain vs substring matching
│       ├── audit.rb           # `audit` subcommand
│       ├── unsubscribe.rb     # `unsubscribe` subcommand (orchestrator)
│       ├── unsubscriber.rb    # executes one unsub: one-click, https, mailto
│       ├── state.rb           # unsubscribed.yaml read/write
│       └── table.rb           # ASCII table printing
├── test/
│   ├── test_helper.rb         # Minitest + VCR config
│   ├── fixtures/vcr/          # recorded Gmail responses
│   ├── headers_test.rb
│   ├── sender_test.rb
│   ├── aggregator_test.rb
│   ├── pattern_matcher_test.rb
│   ├── unsubscriber_test.rb
│   ├── state_test.rb
│   └── gmail_client_test.rb
└── docs/superpowers/specs/
    └── 2026-05-03-email-cleaner-design.md   # this file
```

All Ruby code lives under the `EmailCleaner` namespace
(`EmailCleaner::Audit`, `EmailCleaner::Unsubscriber`, etc.). All files use
`# frozen_string_literal: true`.

### Phase B readiness

- `Aggregator` returns plain `SenderStats` value objects. Today they go
  straight to `Audit#print`. In Phase B a `Persistence` layer can sit between
  aggregator and printer, writing rows to SQLite without touching either side.
- `State` exposes `each`, `record(address, attrs)`, `lookup(address)`,
  `already_unsubscribed?(address)`. The YAML backend can be swapped for a
  SQLite-backed implementation without changing callers.

## Data Flow

### audit pipeline

```
CLI flags
  ↓
Auth.authorize  →  authed Google::Apis::GmailV1::GmailService
  ↓
GmailClient#list_message_ids(query: "newer_than:30d")
  ↓ array of message IDs
GmailClient#fetch_metadata_batched(ids, batch_size: 50)
  ↓ array of raw Gmail messages (metadata format only)
Aggregator#group(messages)
  ↓ Hash{address => SenderStats}
Filter (skip count==1; with --actionable also: has List-Unsubscribe,
        count >= --min, and unless --include-done, exclude confirmed-done)
  ↓
State#annotate(stats)   # mark already-unsubscribed
  ↓
Table.print(rows)
```

### unsubscribe pipeline

```
CLI: pattern, --dry-run, --days, --yes
  ↓
[run audit pipeline above; keep only senders with List-Unsubscribe]
  ↓
PatternMatcher.filter(stats, pattern)   # @domain vs substring
  ↓
print matched senders; prompt y/N (skipped if --dry-run or --yes)
  ↓
for each:
  Unsubscriber#run(sender_stats, dry_run:)
    → :one_click | :https_only | :mailto | :error
  State#record(address, method:, status:, ...)
  append to unsubscribe.log
  ↓
print summary (N succeeded, M manual, K errors)
```

## Core Types

### `Sender`
- `address` (String, lowercased)
- `name` (String, may be nil)
- `domain` (String, derived from address)
- Equality and hash on `address`.

### `UnsubInfo`
- `urls`: Array of `{scheme: :https | :mailto, value: String}`
- `one_click?`: Boolean. True iff `List-Unsubscribe-Post` header equals
  `List-Unsubscribe=One-Click` AND at least one https URL is present in
  `List-Unsubscribe` (per RFC 8058).

### `SenderStats`
- `sender` (Sender)
- `count` (Integer)
- `unsub_info` (UnsubInfo or nil)
- `last_seen` (Date)
- `already_unsubscribed?` (Boolean — populated from State at annotate time)
- `state_status` (one of `:none`, `:confirmed`, `:unconfirmed`)

## Header Parsing (`Headers`)

- **`From`**: handle `Name <addr>`, `"Quoted Name" <addr>`, `"Quoted, Name"
  <addr>` (commas inside quotes), bare `addr`. Lowercase the address. Strip
  surrounding quotes and trailing whitespace from the name. If unparseable,
  treat the whole value as the address with `name = nil`; warn to stderr,
  don't crash.
- **`List-Unsubscribe`**: split on commas that are *outside* angle brackets,
  strip `<>`, classify each entry by URI scheme. Keep all entries. Preference
  ordering (https > mailto, one-click > plain https) happens at unsubscribe
  time, not parse time.
- **`List-Unsubscribe-Post`**: presence of literal
  `List-Unsubscribe=One-Click` (case-insensitive, whitespace-tolerant)
  enables one-click. Combined with at least one https URL, sets
  `UnsubInfo#one_click? = true`.

## Pattern Matching (`PatternMatcher`)

- If `pattern` starts with `@`, treat as **exact domain match**: sender
  matches iff `sender.domain == pattern[1..]` (case-insensitive). Does not
  match subdomains — `@substack.com` does not match `news@x.substack.com`.
  This is intentional for predictability.
- Otherwise, **substring match on address**, case-insensitive: `substack`
  matches both `news@substack.com` and `me+substack@x.com`.
- Display name is **never** matched against. Avoids surprise hits.

## Auth (`Auth`)

OAuth 2.0 flow using `googleauth` and `google-apis-gmail_v1`. Scopes:
`https://www.googleapis.com/auth/gmail.readonly` and
`https://www.googleapis.com/auth/gmail.send` (send is only used for the
mailto unsubscribe path).

1. Read `credentials.json` from project root. If missing, print setup
   instructions pointing at `README.md` and exit 1.
2. If `token.yaml` exists, load. If access token is expired but refresh
   token is present, refresh and continue.
3. Otherwise, run the loopback flow:
   - Build auth URL with `redirect_uri = http://localhost:8765`.
   - Start a WEBrick server on `127.0.0.1:8765` in a thread, serving exactly
     one request: capture `code` query param, respond with a small "You can
     close this tab" HTML page.
   - Try to open the auth URL in the user's browser via platform-specific
     command (`open` on macOS, `xdg-open` on Linux, `start` on Windows). If
     the platform detector fails or the command errors, print the URL and
     wait.
   - Block on the WEBrick thread until the code arrives, with a 5-minute
     timeout. On timeout, exit 1 with an error.
   - Exchange the code for tokens. Write `token.yaml` with `0600`
     permissions. Shut down the server.
4. Return an authorized `Google::Apis::GmailV1::GmailService`.

## External Files

| File | Purpose | Owner | Gitignored |
|---|---|---|---|
| `credentials.json` | OAuth client config (user provides from Google Cloud) | user | yes |
| `token.yaml` | cached access/refresh tokens, mode `0600` | tool | yes |
| `unsubscribed.yaml` | record of unsubscribe attempts | tool | yes |
| `unsubscribe.log` | append-only timeline of unsub actions | tool | yes |

### `unsubscribed.yaml` schema

```yaml
version: 1
entries:
  news@substack.com:
    method: one_click            # one_click | https_only | mailto | error
    status: 200                  # HTTP status, "manual", "sent", or error string
    attempted_at: 2026-05-03T14:22:10Z
    confirmed: true              # see rules below
    last_url: https://...        # URL/mailto used
```

`confirmed` rules:
- `one_click` with 2xx response → `true`
- `mailto` send succeeded → `true`
- `https_only` (manual link) → `false`
- any error → `false`

`State#already_unsubscribed?(address)` returns true only when
`confirmed: true`.

## Performance

- Use Gmail batch requests with batch size 50.
- Use `format: 'metadata'` with `metadata_headers: ['From',
  'List-Unsubscribe', 'List-Unsubscribe-Post', 'Subject', 'Date']` —
  never fetch full message bodies.
- Print `.` to stderr per completed batch as a progress indicator. After
  fetch, print final newline plus `Fetched N messages from M senders.`.

## Error Handling

- **Per-message fetch errors inside a batch**: log warning to stderr, drop
  that message, continue. Never abort a run for one bad message.
- **Auth failure**: print actionable error message ("delete token.yaml and
  retry"), exit 1.
- **Network failure mid-fetch**: caught at the outer level, print
  partial-results notice, exit 1.
- **Unsubscribe HTTP failures (4xx, 5xx, timeout)**: log status, mark as
  `:error` in state, continue to the next sender. Never raise.

## CLI Surface

Entry: `bin/email_cleaner <subcommand> [options]`. Argument parsing via
`OptionParser`.

Global behavior:
- No subcommand or `--help` → print top-level help, exit 0.
- Unknown subcommand → print error and help, exit 2.
- Any subcommand triggers auth on first run; subsequent runs use cached
  `token.yaml`.

### `audit [--days N] [--actionable] [--min N] [--include-done]`

- `--days N` (default 30): Gmail query becomes `newer_than:Nd`.
- `--actionable`: filter to senders that have `List-Unsubscribe` AND
  `count >= --min` AND (unless `--include-done`) are not already
  confirmed-unsubscribed. Without this flag, show everything (skip
  `count == 1` only).
- `--min N` (default 3): only meaningful with `--actionable`.
- `--include-done` (default false): only meaningful with `--actionable`.
- Output: ASCII table, sorted by count desc.
- Columns: `COUNT | UNSUB | 1-CLICK | DONE | DOMAIN | NAME | ADDRESS`.
  - `UNSUB`: `✓` if `List-Unsubscribe` header present, else blank.
  - `1-CLICK`: `✓` if RFC 8058 one-click, else blank.
  - `DONE`: `✓` if state confirmed, `~` if recorded but unconfirmed, else
    blank.
- Footer: `N senders shown, M messages`. With `--actionable`, append:
  `Use: email_cleaner unsubscribe <pattern> to act on these.`

### `unsubscribe <pattern> [--dry-run] [--days N] [--yes]`

- `<pattern>` required positional. `@domain.com` → exact-domain match;
  otherwise substring on address (case-insensitive).
- `--days N` (default 30): window for pulling matched senders.
- `--dry-run`: print plan, skip prompt and side effects.
- `--yes`: skip confirmation prompt.
- Filter: matches pattern AND has `List-Unsubscribe`. The audit-style
  `--min` and `--include-done` flags do **not** apply here — `unsubscribe`
  always considers all matched senders regardless of count or prior state.
  If a matched sender is already `confirmed: true` in state, the tool warns
  but still re-fires (the user may be retrying intentionally). If none
  match, exit 0 with `No matches.`.
- Print matched senders (audit-style table), then prompt
  `Unsubscribe from N senders? [y/N]` unless `--yes` or `--dry-run`.
- Per sender, choose method by preference:
  1. **One-click** (RFC 8058): `POST` to https URL, body
     `List-Unsubscribe=One-Click`, `Content-Type:
     application/x-www-form-urlencoded`, 10-second timeout. Log
     `[one-click] <address> → HTTP <status>`.
  2. **https only** (no one-click post): print URL for manual action; record
     with `confirmed: false`. Log `[manual] <address> → <url>`.
  3. **mailto only**: parse `subject` and `body` query params from the
     mailto URI (default subject: `unsubscribe`, default body: empty). Send
     via Gmail `users.messages.send`. Log `[mailto] <address> → sent`.
  4. If both https and mailto exist: prefer https (one-click if available,
     else https-only).
- After all attempts: write to state, append to `unsubscribe.log`. Print
  summary: `N succeeded, M manual, K errors`.

### Exit codes

- `0`: success.
- `1`: runtime error (auth, network).
- `2`: usage error (unknown subcommand, missing required arg).

## Testing

**Stack:** Minitest + VCR + WebMock.

**`test/test_helper.rb` setup:**
- VCR cassette dir: `test/fixtures/vcr/`.
- Default record mode `:none` (CI never hits the network).
- Re-record by setting `VCR_RECORD=new_episodes`.
- Filter sensitive data (OAuth tokens, `Authorization` headers, refresh
  tokens, the user's email address) with placeholders before write.

**Per-module test scope:**

- **`headers_test.rb`** — pure unit. From parsing variants (quoted names,
  commas in quotes, bare addresses, unicode, `+` aliases, malformed),
  List-Unsubscribe parsing (single https, single mailto, both
  comma-separated, malformed entries, commas inside angle brackets),
  List-Unsubscribe-Post recognition (with whitespace, missing → not
  one-click, present without https → not one-click).
- **`sender_test.rb`** — domain extraction, address normalization (lower),
  `==` and `hash` semantics.
- **`aggregator_test.rb`** — given a fixture array of fake message hashes,
  returns correct `SenderStats` (count, last_seen, unsub_info, sorted desc
  by count), `count == 1` skip logic.
- **`pattern_matcher_test.rb`** — substring case-insensitive,
  `@domain.com` exact match (does not match subdomains).
- **`unsubscriber_test.rb`** — uses WebMock directly:
  - One-click: stub https URL, assert method/headers/body, returned status.
  - https-only: assert no HTTP call, URL captured for printing.
  - mailto: stub Gmail send, parse mailto with subject/body, assert send
    payload.
  - 4xx, 5xx, timeout → `:error` returned, no exception.
  - `dry_run: true` → zero HTTP/send calls, returns planned method.
- **`state_test.rb`** — round-trip yaml read/write,
  `already_unsubscribed?` semantics, `record` overwrites prior entry, file
  is `0600`.
- **`gmail_client_test.rb`** — VCR cassette for `list_messages` plus a
  50-id batch. Asserts pagination handling, batch chunking (101 ids → 3
  batches), and per-message warning path on individual failures.

**Not tested:**
- `Auth` end-to-end (requires real Google OAuth interaction). `Auth` is kept
  thin to minimize untested logic.
- `CLI` subcommand dispatch glue. Verified by inspection.
- `Table` printing.

**Running:** `bundle exec rake test`.

## README setup steps (to be authored)

The README must walk through:

1. Create a Google Cloud project.
2. Enable the Gmail API.
3. Create an OAuth client of type **Desktop**, with
   `http://localhost:8765` listed as an authorized redirect URI.
4. Download `credentials.json` and place it in the project root.
5. Add the user's own Gmail address as a Test User on the OAuth consent
   screen (required while the app is in Testing status).
6. `bundle install`.
7. `bin/email_cleaner audit` (first run triggers OAuth in a browser).
