# Auto-Read Senders & Chunked 90-Day Triage — Design

Date: 2026-05-06
Status: Approved for planning

## Problem

During triage, many senders fall into a category the user wants to keep
receiving but doesn't need to actively see as unread (e.g. "Your latest
statement is available"). Adding senders to a Gmail filter via the web UI
is painful, and the Gmail API exposes filters as immutable resources, so
"appending" requires a delete-and-recreate cycle.

Separately, triaging 90 days of mail in one shot is slow and risks
hitting Gmail rate limits.

## Goals

1. During triage, mark a sender as "auto-read" with a single keystroke
   (address-scoped or domain-scoped).
2. A single managed Gmail filter, derived from a local source-of-truth
   list, marks matching mail as read server-side (works on web/mobile,
   future mail too).
3. 90-day backfill triage runs in resumable weekly chunks.

## Non-goals

- No archive / skip-inbox behavior. Auto-read action is mark-as-read only.
- No multiple managed filters. One filter; if the query exceeds Gmail's
  length limit, sync fails loudly and we revisit.
- No automatic sync from triage. `sync` is an explicit, separate command.

## Architecture

### New files

- `lib/email_cleaner/auto_read_state.rb` — load/save the local
  source-of-truth file at `auto_read.yaml` (alongside existing
  `unsubscribed.yaml`, `token.yaml`).

  Schema:
  ```yaml
  filter_id: "ANe1Bm..."   # nil until first successful sync
  addresses: ["a@x.com", "b@y.com"]
  domains:    ["chase.com", "stripe.com"]
  ```

  Responsibilities: load, save, dedupe-on-add, normalize input
  (`@chase.com` and `chase.com` both resolve to domain entry `chase.com`;
  bare `a@x.com` resolves to address entry).

- `lib/email_cleaner/gmail_filter.rb` — wrapper over
  `users.settings.filters` exposing `list`, `create(query)`,
  `delete(id)`. Also owns the query builder:

  ```
  from:(a@x.com OR b@y.com OR @chase.com OR @stripe.com)
  ```

  Builder enforces a length cap (~1500 chars); over-budget raises a
  typed error that the command surfaces with a clear message.

- `lib/email_cleaner/auto_read_command.rb` — `auto-read` subcommand with
  verbs: `list`, `add ADDR|@domain`, `remove ADDR|@domain`, `sync`,
  `status`.

### Modified files

- `lib/email_cleaner/triage_command.rb`:
  - Extend prompt key list from `[u/m/k/t/s/q/?]` to
    `[u/m/k/t/s/r/R/q/?]`.
  - `r` → append current sender's address to `AutoReadState.addresses`,
    save, log `auto_read_addr <addr>`, advance.
  - `R` → extract domain from current sender, append to
    `AutoReadState.domains`, save, log `auto_read_domain <domain>`,
    advance.
  - Neither key calls Gmail. Decisions are recorded under a new
    `auto_read` bucket in the recap (count of addresses + domains added
    this session).

- `lib/email_cleaner/cli.rb` — register `auto-read` subcommand.

- `bin/email_cleaner` — add `https://www.googleapis.com/auth/gmail.settings.basic`
  to OAuth scopes.

### Boundary

Triage only mutates the local list. `auto-read sync` is the only path
that calls the Filters API. This keeps triage offline-safe and makes
filter changes a discrete, reviewable step.

## 90-Day Chunked Triage

New flag on existing `triage` subcommand: `--chunk N` (default 7).

Behavior when `--days > --chunk`:

1. Compute chunk windows newest-to-oldest:
   `[today-7, today]`, `[today-14, today-7]`, …, until `--days` covered.
2. For each chunk:
   a. Fetch sender stats with Gmail query
      `after:YYYY/MM/DD before:YYYY/MM/DD` plus existing min-count filter.
   b. Run the existing interactive triage loop on that chunk's senders.
   c. On chunk completion, write
      `triage_progress.yaml: {last_completed_chunk_end: "YYYY-MM-DD"}`.
   d. Prompt: `chunk N/M done — Enter to continue, q to quit`.
3. On startup, if `triage_progress.yaml` exists and points within the
   current `--days` window, resume at the next chunk. Quitting mid-chunk
   re-runs that chunk on resume (chunk is the resume granularity).

`--chunk` is tunable; 7 is the default because most newsletters/statements
have weekly cadence and the gap between chunks (user triage time) acts
as natural rate-limit pacing.

## Sync Semantics

`auto-read sync`:

1. Load `auto_read.yaml`.
2. If `addresses` and `domains` are both empty:
   - If `filter_id` set: delete filter, clear `filter_id`, save, exit.
   - Else: nothing to do, exit.
3. Build query string. If over length cap, raise typed error and exit
   with a message listing entry count and char count.
4. If `filter_id` set: `DELETE users/me/settings/filters/{filter_id}`.
   On 404, log a warning and continue. Do NOT clear `filter_id` yet.
5. `POST users/me/settings/filters` with
   `{criteria: {query}, action: {removeLabelIds: ["UNREAD"]}}`.
6. On 200: set `filter_id` to returned id, save.
7. Print summary.

### Failure recovery

- Mid-flight failure between delete (succeeded) and create (failed):
  `filter_id` still holds the old (now-deleted) id. Next `sync` will
  attempt to delete it, get 404, warn, and proceed to create. End state
  converges.

- Auth scope missing (`gmail.settings.basic`): detected on first API call;
  print exact re-auth instruction.

- User deleted the filter manually in Gmail UI: detected as 404 on
  delete; same recovery as above.

## Triage Key Bindings

Final per-sender keys:

| key | action                              |
|-----|-------------------------------------|
| u   | unsubscribe + trash backlog         |
| m   | mark done                           |
| k   | keep                                |
| t   | trash backlog                       |
| s   | skip                                |
| r   | auto-read this address (local only) |
| R   | auto-read whole domain (local only) |
| q   | quit                                |
| ?   | help                                |

`r`/`R` are mnemonic for "read"; uppercase = broader scope.

## Testing

Minitest, matching existing style under `test/`:

- `auto_read_state_test.rb`: load/save round-trip; dedupe; normalization
  of `@chase.com` vs `chase.com` vs `a@chase.com`; empty file.
- `gmail_filter_test.rb`: query builder for addresses-only, domains-only,
  mixed, empty (raises), over-length (raises typed error).
- `auto_read_command_test.rb`: sync with no prior filter (creates, saves
  id); sync with valid `filter_id` (deletes then creates); sync with
  stale `filter_id` mocked 404 (warns, creates); sync with empty list
  deletes filter and clears id; `add`/`remove` verbs mutate state file.
- `triage_command_test.rb`: extend existing test — `r` appends address,
  `R` appends domain, neither calls Gmail; recap shows counts.

## Out of Scope

- Multi-filter splitting when query exceeds length cap.
- Auto-sync after triage (user runs `auto-read sync` explicitly).
- Archive-on-auto-read (mark-as-read only).
- Per-sender choice of action (always mark-as-read).

## Open Questions

None at spec time.
