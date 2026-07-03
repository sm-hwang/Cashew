# Email Scan: Timestamp Watermark + Pagination — Design

**Date:** 2026-07-03
**Status:** Approved for planning
**App:** Cashew (`budget/`, Flutter)
**Branch:** `macos-google-signin` (continuing email-scanning work)

## Summary

The email scanner currently fetches only the **latest 10 messages** with no
date filter (`messages.list(maxResults: 10)`), deduping by a small message-ID
list (`EmailAutoTransactions-emailsParsed`, ~20 IDs). If more than ~10 emails
arrive between scans, bank-alert emails past position 10 are **never seen**.

This design replaces the count-window with a **millisecond-precision timestamp
watermark + pagination**: each scan fetches every email received since the last
scan (Gmail `after:` query, paginated), so nothing is missed. Deduplication
becomes purely timestamp-based (`internalDate_ms > watermark`), which lets us
**drop the message-ID list entirely**.

## Goals

- No bank-alert email is missed, regardless of email volume between scans.
- No duplicate transactions.
- Minimal persistent state (a single timestamp; no ID list).
- Bounded work per scan (a runaway/stale watermark can't fetch unbounded mail).

## Non-Goals

- Sender/subject/phrase filtering of the Gmail query (fetch the time window,
  match against templates in-app — same as today, just time-windowed).
- Changing the template-editor email preview (`GmailApiScreen`, which fetches
  latest-N purely for display) — out of scope, unchanged.
- Changing categorization, extraction, or transaction creation.
- Background/polling scans — triggers are unchanged (launch, refresh button,
  pull-to-refresh setting).
- A perpetual "always re-scan last 30 days" window — rejected: it would require
  remembering every message ID in the window (reintroducing a large ID list and
  duplicate risk). The watermark advances instead.

## Decisions (resolved during brainstorming)

| Decision | Choice |
|---|---|
| Dedup mechanism | Millisecond timestamp watermark + in-app `internalDate_ms > watermark`. **No message-ID list.** |
| First-run watermark | `now − 30 days` **if no existing email-scanned transactions**, else `now`. |
| Backfill semantics | One-time 30-day backfill on first run, then watermark auto-advances (not perpetual re-scan). |
| Query filtering | `after:<epoch>` only; no sender/phrase filter (match in-app). |
| Per-scan cap | ~500 messages (5 pages of 100); if hit, advance to what was processed and continue next scan. |
| Watermark advance | To the `internalDate` of the latest fully-examined email; forward-only; never past an uncommitted transaction. |

## Architecture

### Section 1 — Watermark storage & first-run initialization

- New setting `EmailAutoTransactions-lastScannedEpochMs` (int, Unix ms).
- On a scan, if the setting is unset/null, initialize it:
  - If the DB has **no** transactions with `methodAdded == MethodAdded.email`
    → `now − 30 days` (fresh install: backfill the last month).
  - Else → `now` (existing install with prior scanned data: forward-only, so a
    backfill can't re-create already-existing transactions).
- The setting is persisted via the existing `updateSettings(...)` mechanism.

### Section 2 — Query & pagination

- Build the Gmail query from the watermark:
  `q = "after:" + (watermarkMs ~/ 1000)` (Gmail's query is second-granular).
- `messages.list(userId, q: query, maxResults: 100)`, then follow
  `nextPageToken` until absent **or** the per-scan cap is reached.
- **Cap:** stop after `maxPages = 5` (~500 messages). Gmail returns messages
  newest-first; because we advance the watermark to what we processed, a capped
  scan simply resumes from where it left off on the next run.
- Collect the message IDs from all fetched pages.

### Section 3 — Per-message processing & timestamp dedup

- Process fetched messages in **ascending `internalDate` order** (oldest → newest)
  so partial progress is resume-safe.
- For each message: `messages.get(...)`, read `internalDate` (ms).
  - If `internalDate_ms <= watermarkMs` → **skip** (already processed; this is
    the boundary-second overlap the second-granular `after:` query can return).
  - Else → run the existing pipeline (template match → extract title/amount →
    resolve category incl. AI on cache-miss → build transaction).
- No message-ID list is consulted or written. `EmailAutoTransactions-emailsParsed`
  is no longer read/written by the scan (the key may remain, vestigial).

### Section 4 — Advancing the watermark (resume- & duplicate-safe)

- Invariant: **the watermark must never move past an email whose transaction was
  not committed** (or that wasn't fully examined).
- Advance the watermark to the `internalDate_ms` of the latest email that has
  been fully handled — where "handled" means its transaction was committed, or it
  was examined and produced no transaction (no template match / skipped).
- Advance is monotonic (only forward). Persist so an interruption
  (network error mid-pagination/`get`) leaves the watermark at the last handled
  email; the next scan resumes from there — no misses, no reprocessing of
  committed transactions.
- Existing behavior of batching transaction inserts may be retained, provided
  the watermark is only advanced past emails whose inserts have committed. (The
  plan chooses per-email vs. end-of-batch persistence while preserving the
  invariant.)

### Section 5 — Pure, testable helpers

Extract logic that doesn't touch the network so it can be unit-tested:

- `String buildGmailQuery(int watermarkMs)` → `"after:<seconds>"`.
- `bool isNewerThanWatermark(int internalDateMs, int watermarkMs)` →
  `internalDateMs > watermarkMs`.
- `int advanceWatermark(int currentMs, Iterable<int> handledInternalDatesMs)` →
  `max(currentMs, max(handled))` (returns `currentMs` if none handled).
- `int initialWatermarkMs(int nowMs, bool hasExistingEmailTransactions)` →
  `hasExistingEmailTransactions ? nowMs : nowMs - 30 days`.

The live Gmail pagination/`get` loop remains integration-tested (manual on
macOS), as today.

## One-time migration for this install

Because dropping the ID list means a 30-day backfill would re-create the ~10
already-scanned transactions, this install is reset to a clean slate:

- **Delete all transactions** (user confirmed there are no manually-entered
  ones). Keep `AssociatedTitles` (the category cache) so re-scans reuse learned
  categories and make fewer Gemini calls.
- Leave `lastScannedEpochMs` unset → first scan sees no email transactions →
  initializes to `now − 30 days` → backfills the last month fresh, no duplicates.

This is a one-time operations action, not a code path.

## Error handling & safety

- Scan continues to never throw out of the per-email pipeline (existing
  behavior). A network error during pagination/`get` aborts the current scan;
  the watermark reflects only fully-handled emails, so the next scan retries the
  rest.
- Duplicate-safety rests on the invariant in Section 4 + the clean-slate
  migration: the watermark never advances past an uncommitted transaction, and
  the backfill runs against an empty (or forward-only) slate.
- Gmail API quota is not a concern (250 units/user/sec; `list`/`get` = 5 units
  each). The tight limit is the Gemini free tier, already handled by
  retry/backoff in `aiCategorization.dart`.

## Testing

- Unit tests for the four pure helpers in Section 5 (query string, dedup
  predicate, watermark advance incl. empty case, first-run initialization for
  both fresh and existing-data installs).
- Manual macOS verification: with a clean slate, launch → confirm a 30-day
  backfill of matching alerts is created once; relaunch → confirm no duplicates
  and only newer emails are processed.

## Open items for the plan

- Exact `MethodAdded.email` query for "has existing email transactions."
- Per-email vs. end-of-batch watermark persistence (must preserve the Section 4
  invariant).
- Whether to remove the now-unused `EmailAutoTransactions-emailsParsed`
  reads/writes or leave the key vestigial (lean: remove the scan's use).
