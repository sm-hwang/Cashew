# AI Auto-Categorization for Email Transactions — Design

**Date:** 2026-06-27
**Status:** Approved for planning
**App:** Cashew (`budget/`, Flutter)

## Scope revision (2026-06-27, during planning)

After reviewing real merchant strings, the design was **simplified**. Two
elements of the original design below are **dropped**:

- **Merchant normalization** (Section 2) — removed. Most alert emails do not
  carry store numbers / locations, and re-querying the occasional
  `CHIPOTLE #1234` vs `CHIPOTLE #2345` is acceptable since the user revisits the
  same locations. The cache key is the **raw title**, exactly as
  `AssociatedTitles` already stores it.
- **The `source` column + new exact `getCachedCategoryForMerchant` lookup**
  (Section 1) — removed. With raw-title keys, the **existing**
  `getSimilarAssociatedTitles` already serves as the cache read and
  `addAssociatedTitles` already serves as the cache write. The user-correction
  lock is automatic: a cache hit means Gemini is never called, so the AI path
  can never overwrite a prior user (or AI) categorization. No DB migration.

Net feature = **Gemini service + settings + a small change at the two
cache-miss sites** (miss → ask Gemini → use result or fall through to today's
behavior). Sections 1 and 2 below are retained for history but are superseded
by this note; Sections 3–5 still apply. See the implementation plan for the
authoritative task breakdown.

## Summary

Cashew already scrapes credit-card-alert emails (AMEX, etc.) via Gmail and the
`ScannerTemplate` system, extracts the merchant title and amount, and creates a
transaction. Today, if a merchant has no prior category mapping the code
**silently skips** the transaction (`if (selectedCategory == null) continue;`).

This feature fills that single gap: when a merchant is not in the cache, ask
**Gemini Flash** to classify it into one of the user's existing categories,
create the transaction, and cache the result so future occurrences never call
the LLM again. Manual corrections are authoritative and override the cache
permanently.

The email scraping, Gmail integration, transaction prefill, and a cache-like
`AssociatedTitles` table all **already exist** — this design adds only the
LLM-on-cache-miss layer, a cache `source` flag, merchant normalization, and a
small settings surface.

## Goals

- Auto-categorize first-seen merchants instead of skipping them.
- Cache every result so each unique merchant costs at most one LLM call.
- Manual category corrections override the cache and are never overwritten by
  the LLM.
- Keep spend at $0 by using Gemini Flash's free tier.
- Fail safe: any error degrades to the template default or a skip — never a
  thrown exception (the macOS port already hit a swallowed-startup-error bug of
  this class via `captureLogs`'s zone handler; categorization must not add
  another).

## Non-Goals

- Changing the existing template/scraping UX or the highlight-to-select editor.
- Batch categorization / Batch API (cache makes per-call volume negligible).
- Confidence scoring or a review queue (auto-apply was chosen; corrections are
  cheap).
- Platform work beyond macOS validation. The feature is platform-neutral.

## Decisions (resolved during brainstorming)

| Decision | Choice |
|---|---|
| Target platform | macOS (Phase 0 prerequisite below) |
| LLM provider | Google Gemini Flash, BYO API key, free tier |
| Apply behavior | Auto-apply; correct later |
| Cache | Reuse `AssociatedTitles` + a new `source` flag (Approach A) |
| Override rule | User corrections are authoritative and lock the merchant from LLM |

## Prerequisite — Phase 0: Google Sign-In on macOS

The email scan cannot run on macOS until Google Sign-In works there. This is a
separate, already-scoped chunk and a hard prerequisite for *using* the feature
on macOS (the categorization code itself is independent and can be built/tested
without it). Scope:

- **User (Google Cloud Console, project `267621253497`):** create an OAuth
  client for the macOS app, add the Gmail scope to the consent screen, add a
  test user.
- **Code:** add the reversed-client-ID URL scheme to `macos/Runner/Info.plist`,
  pass the macOS client ID directly (Firebase is disabled on macOS, so
  `DefaultFirebaseOptions.currentPlatform` cannot be used — Firebase init is
  wrapped in try/catch on macOS), and add the network-client / keychain
  entitlements `google_sign_in_macos` requires.

Note: the Gemini API itself uses a **plain API key** against
`generativelanguage.googleapis.com` and is **independent** of this OAuth work.

## Architecture

### Section 1 — Data model & cache

`AssociatedTitles` is the merchant→category cache. Today it has:
`associatedTitlePk`, `categoryFk`, `title`, `dateCreated`, `dateTimeModified`,
`order`, `isExactMatch`.

**Change:** add one column.

- `source` — int enum `{ user, ai }`. Default `user`. All existing rows migrate
  to `user` (they were created by manual action today).

**Lookup (cache read):** a new exact, normalized match:

```dart
Future<TransactionCategory?> getCachedCategoryForMerchant(String normalizedMerchant)
```

This is **exact** (normalized equality), distinct from the existing fuzzy
`getSimilarAssociatedTitles` (`LIKE %title%`), which stays as-is for the
suggestion feature. The fuzzy match is too loose to be an authoritative cache.

**Precedence rule:** a `user` entry is authoritative and **locked** — the AI
path never overwrites it and never re-queries that merchant.

**Override flow (mostly already wired):** manual categorization already calls
`addAssociatedTitles` (`addTransactionPage.dart:467`, gated by the
`autoAddAssociatedTitles` setting). Extend the write path so a user-originated
write upserts with `source: user`, overwriting any prior `ai` entry for that
merchant.

**Migration:** Drift column add + schema-version bump + a new `drift_schemas`
entry + sync wiring so the new column propagates (the app syncs
`AssociatedTitle` via its update-log system).

### Section 2 — Merchant normalization

A single pure, unit-testable function applied **before every cache read and
cache write** so keys always match:

```dart
String normalizeMerchant(String rawTitle)
```

Conservative transforms: uppercase, collapse whitespace, strip store numbers
(`#1234`), trailing digits, and common location tails
(e.g. `CHIPOTLE #1234 NEW YORK NY` → `CHIPOTLE`). Deliberately cautious to avoid
collapsing genuinely different merchants. Exact behavior to be pinned with test
cases during implementation.

### Section 3 — Gemini service (`lib/struct/aiCategorization.dart`)

- **BYO key:** a Gemini API key field in Settings, stored locally via
  `shared_preferences` (same mechanism as existing settings). Feature is a no-op
  when empty.
- **Model:** Gemini Flash (current free-tier Flash model, e.g.
  `gemini-2.5-flash` / `gemini-2.0-flash`; final ID chosen at implementation).
- **Transport:** one `POST` to `generativelanguage.googleapis.com` via the
  existing `http` package.
- **Constrained output:** use `responseMimeType: application/json` +
  `responseSchema`, enumerating the user's existing category IDs so the model
  must return a valid existing category and cannot invent one.
- **Request payload:** normalized merchant name + the user's category list
  (id + name). No amounts, accounts, or other transaction data are sent.
- **Failure handling:** on missing key, network error, rate-limit, refusal, or
  unparseable output → fall back to the template's `defaultCategoryFk`; if none,
  skip. All errors are logged, never thrown.

### Section 4 — Integration point

Consolidate the **three duplicated match-and-extract blocks**
(`parseEmailsInBackground` ~`:476`, `queueTransactionFromMessage` ~`:100`, and
the in-page test ~`:936` in `autoTransactionsPageEmail.dart`) into one shared
helper. Replace the current skip-on-miss with:

```text
normalized = normalizeMerchant(title)
cached = getCachedCategoryForMerchant(normalized)     # user or ai
if cached != null:
    category = cached
else:
    category = await aiCategorize(normalized, userCategories)   # Gemini Flash
    if category != null:
        cacheWrite(normalized, category, source: ai)
    else:
        category = template.defaultCategoryFk         # or skip if null

if category != null:
    create transaction (auto-apply, as today)
```

A later manual correction flips that merchant's cache entry to `source: user`,
which the AI path will then always defer to.

### Section 5 — Settings surface

- Gemini API key text field (obscured), under the existing Auto-Email-
  Transactions / a new "AI categorization" settings area.
- A master on/off toggle (independent of having a key; off = current
  skip-on-miss behavior).
- Reuse existing settings widgets/patterns; no new settings framework.

## Error handling & safety

- Categorization never throws; the worst case is "merchant skipped this scan,"
  identical to today's behavior.
- No financial amounts or account identifiers are sent to Gemini — merchant
  string + category list only.
- Free-tier privacy caveat (Google may use submitted data to improve products)
  is surfaced to the user near the API-key field.

## Testing

- Unit tests for `normalizeMerchant` (table of raw → normalized cases,
  including the don't-collapse-distinct-merchants cases).
- Unit/contract test for the Gemini service with a mocked `http` client:
  success, network error, rate-limit, and unparseable-response paths all return
  the correct fallback.
- Cache precedence test: `ai` entry present → user correction upserts `user` →
  subsequent AI path defers to it and does not call the service.
- Exact-match cache test: normalized lookup hits/misses as expected.

## Open items for the plan

- Exact Gemini Flash model ID (free-tier current).
- Final normalization rule set + test table.
- `responseSchema` shape for the category-ID enum.
- Settings placement and copy for the privacy note.
