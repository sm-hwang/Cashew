# Email Scan Timestamp Watermark + Pagination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the email scanner's "latest 10 messages" fetch with a millisecond-precision timestamp watermark + pagination, so no bank-alert emails are missed between scans and no duplicates are created — with no message-ID dedup list.

**Architecture:** A single persisted watermark (`lastScannedEpochMs`) drives a Gmail `after:<seconds>` query. Each scan lists all message ids since the watermark (cheap, ids only), processes the oldest ones first (capped), dedups purely by `internalDate_ms > watermark`, and advances the watermark to the newest processed email. Pure helpers are unit-tested; the live Gmail loop is verified manually.

**Tech Stack:** Flutter / Dart, `googleapis` Gmail API, Drift, `flutter_test`, FVM Flutter 3.22.3.

## Global Constraints

- **Build only with FVM**: `fvm flutter ...` (project pinned to Flutter 3.22.3). Never bare `flutter`.
- Dedup is **timestamp-only** (`internalDate_ms > watermark`); do **not** reintroduce a message-ID list.
- **First-run watermark:** `now − 30 days` if there are **no** existing `MethodAdded.email` transactions, else `now`.
- **Per-scan processing cap = 500 oldest** messages; **listing** is complete (all pages, up to a 100-page safety cap). Process **oldest-first**; advance the watermark to the newest **processed** message.
- **Invariant:** never advance the watermark past an email whose transaction was not committed. Persist the watermark only after transaction inserts complete.
- Watermark stored in setting key **`EmailAutoTransactions-lastScannedEpochMs`** (int, Unix ms); not added to `defaultPreferences` (absent = unset = triggers first-run init).
- Scope: only `parseEmailsInBackground`. Do **not** change the template-editor preview (`GmailApiScreen`).
- All paths relative to `budget/`. Run all commands from `budget/`.

---

## File Structure

- **Create** `lib/struct/emailScanWatermark.dart` — pure helpers + constants.
- **Create** `test/email_scan_watermark_test.dart`.
- **Modify** `lib/database/tables.dart` — add `hasEmailTransactions()`.
- **Create** `test/has_email_transactions_test.dart`.
- **Modify** `lib/pages/autoTransactionsPageEmail.dart` — rewrite the fetch/loop in `parseEmailsInBackground` to use the watermark.

---

## Task 1: Pure watermark helpers

Self-contained, no I/O — fully unit-tested with TDD.

**Files:**
- Create: `lib/struct/emailScanWatermark.dart`
- Test: `test/email_scan_watermark_test.dart`

**Interfaces:**
- Produces:
  - `const Duration emailScanBackfillWindow` (30 days)
  - `const int emailScanPageSize` (100), `const int emailScanMaxListPages` (100), `const int emailScanMaxProcessPerScan` (500)
  - `String buildGmailAfterQuery(int watermarkMs)`
  - `bool isNewerThanWatermark(int internalDateMs, int watermarkMs)`
  - `int advanceWatermark(int currentMs, Iterable<int> handledInternalDatesMs)`
  - `int initialWatermarkMs(int nowMs, bool hasExistingEmailTransactions)`

- [ ] **Step 1: Write the failing test**

Create `test/email_scan_watermark_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/emailScanWatermark.dart';

void main() {
  test('buildGmailAfterQuery converts ms to whole seconds', () {
    expect(buildGmailAfterQuery(1000), 'after:1'); // 1000ms -> 1s
    expect(buildGmailAfterQuery(1783000500), 'after:1783000'); // truncates ms
  });

  group('isNewerThanWatermark', () {
    test('strictly greater is new', () {
      expect(isNewerThanWatermark(2000, 1000), isTrue);
    });
    test('equal is NOT new (boundary already processed)', () {
      expect(isNewerThanWatermark(1000, 1000), isFalse);
    });
    test('older is not new', () {
      expect(isNewerThanWatermark(500, 1000), isFalse);
    });
  });

  group('advanceWatermark', () {
    test('moves to the max handled', () {
      expect(advanceWatermark(1000, [500, 3000, 2000]), 3000);
    });
    test('never moves backward', () {
      expect(advanceWatermark(5000, [1, 2, 3]), 5000);
    });
    test('unchanged when nothing handled', () {
      expect(advanceWatermark(1000, const []), 1000);
    });
  });

  group('initialWatermarkMs', () {
    test('fresh install backfills 30 days', () {
      final now = 1783000000000;
      expect(initialWatermarkMs(now, false),
          now - const Duration(days: 30).inMilliseconds);
    });
    test('existing email transactions -> forward-only (now)', () {
      final now = 1783000000000;
      expect(initialWatermarkMs(now, true), now);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/email_scan_watermark_test.dart`
Expected: FAIL — `emailScanWatermark.dart` / the functions are undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/struct/emailScanWatermark.dart`:

```dart
// Pure helpers for the email-scan timestamp watermark. No I/O — unit-tested.

// Fresh installs backfill emails received within this window before "now".
const Duration emailScanBackfillWindow = Duration(days: 30);

// Gmail list page size.
const int emailScanPageSize = 100;

// Safety cap on how many id-only list pages we page through (ids are cheap).
const int emailScanMaxListPages = 100;

// Cap on the expensive get()+process work per scan (oldest-first).
const int emailScanMaxProcessPerScan = 500;

// Gmail's search query is second-granular; build "after:<unix seconds>".
String buildGmailAfterQuery(int watermarkMs) {
  return 'after:${watermarkMs ~/ 1000}';
}

// An email is unprocessed iff strictly newer than the watermark. Equality means
// it sat at the exact boundary second the (second-granular) after: query can
// re-return, and was already handled last scan.
bool isNewerThanWatermark(int internalDateMs, int watermarkMs) {
  return internalDateMs > watermarkMs;
}

// New watermark = newest handled email, never moving backward.
int advanceWatermark(int currentMs, Iterable<int> handledInternalDatesMs) {
  int result = currentMs;
  for (final ms in handledInternalDatesMs) {
    if (ms > result) result = ms;
  }
  return result;
}

// First-run watermark: fresh install backfills 30 days; an install that already
// has email-scanned transactions starts at now (forward-only) so a backfill
// cannot re-create them.
int initialWatermarkMs(int nowMs, bool hasExistingEmailTransactions) {
  return hasExistingEmailTransactions
      ? nowMs
      : nowMs - emailScanBackfillWindow.inMilliseconds;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/email_scan_watermark_test.dart`
Expected: PASS (all groups).

- [ ] **Step 5: Commit**

```bash
git add lib/struct/emailScanWatermark.dart test/email_scan_watermark_test.dart
git commit -m "feat: add pure helpers for email-scan timestamp watermark"
```

---

## Task 2: `hasEmailTransactions()` database helper

The first-run guard needs to know whether any email-scanned transactions already exist. Add a cheap count query.

**Files:**
- Modify: `lib/database/tables.dart` (add method near the other count helpers, ~`:3383`)
- Test: `test/has_email_transactions_test.dart`

**Interfaces:**
- Produces: `Future<bool> hasEmailTransactions()` on `FinanceDatabase`.
- Consumes: existing `MethodAdded` enum (`tables.dart:122`) and `transactions` table.

- [ ] **Step 1: Write the failing test**

Create `test/has_email_transactions_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:budget/database/tables.dart';

void main() {
  late FinanceDatabase db;
  setUp(() => db = FinanceDatabase(NativeDatabase.memory()));
  tearDown(() async => await db.close());

  Future<void> addTxn(String pk, MethodAdded? method) async {
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          transactionPk: Value(pk),
          name: 'n',
          amount: -1,
          note: '',
          categoryFk: 'c',
          walletFk: '0',
          dateCreated: Value(DateTime.now()),
          income: false,
          paid: const Value(true),
          methodAdded: Value(method),
        ));
  }

  test('false when there are no email transactions', () async {
    expect(await db.hasEmailTransactions(), isFalse);
    await addTxn('a', MethodAdded.csv);
    expect(await db.hasEmailTransactions(), isFalse);
  });

  test('true when at least one email transaction exists', () async {
    await addTxn('b', MethodAdded.email);
    expect(await db.hasEmailTransactions(), isTrue);
  });
}
```

If `TransactionsCompanion.insert`'s required fields differ from the above, adjust the named args to match the generated signature in `tables.g.dart` (fill required columns, leave the rest defaulted). `MethodAdded.csv` may be named differently — use any non-`email` value from the enum at `tables.dart:122`.

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/has_email_transactions_test.dart`
Expected: FAIL — `hasEmailTransactions` not defined.

- [ ] **Step 3: Write the implementation**

In `lib/database/tables.dart`, add this method just after `getTotalCountOfAssociatedTitles` (ends ~`:3383`), inside the `FinanceDatabase` class:

```dart
  Future<bool> hasEmailTransactions() async {
    final count = transactions.transactionPk.count(
        filter: transactions.methodAdded.equalsValue(MethodAdded.email));
    final query = selectOnly(transactions)..addColumns([count]);
    final result = await query.map((row) => row.read(count)).getSingle();
    return (result ?? 0) > 0;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `fvm flutter test test/has_email_transactions_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/database/tables.dart test/has_email_transactions_test.dart
git commit -m "feat: add hasEmailTransactions() count query"
```

---

## Task 3: Wire the watermark + pagination into the scan

Rewrite the fetch/loop in `parseEmailsInBackground` to use the watermark. This is integration code against the live Gmail API, so there is no unit test; acceptance is `fvm flutter analyze` clean plus the manual verification at the end.

**Files:**
- Modify: `lib/pages/autoTransactionsPageEmail.dart`

**Interfaces:**
- Consumes: `buildGmailAfterQuery`, `isNewerThanWatermark`, `advanceWatermark`, `initialWatermarkMs`, `emailScanPageSize`, `emailScanMaxListPages`, `emailScanMaxProcessPerScan` (Task 1); `database.hasEmailTransactions()` (Task 2); existing `getEmailMessage`, `getTransactionTitleFromEmail`, `getTransactionAmountFromEmail`, `aiCategorizeEmailMerchant`, `addAssociatedTitles`, `filterEmailTitle`, `database.getCategoryInstanceOrNull`, `database.getSimilarAssociatedTitles`, `database.getAllScannerTemplates`, `database.createOrUpdateTransaction`.

- [ ] **Step 1: Add the import**

In `lib/pages/autoTransactionsPageEmail.dart` imports, add:

```dart
import 'package:budget/struct/emailScanWatermark.dart';
```

- [ ] **Step 2: Replace the fetch/loop/persist block**

In `parseEmailsInBackground`, replace the entire block from the `List<dynamic> emailsParsed =` line (`:490`) through the closing of the scanned-emails snackbar and its enclosing `if` (`:685`) — i.e. everything between `if (hasSignedIn == false) { return; }` and the final `}` that closes `if (appStateSettings["AutoTransactions-canReadEmails"] == true) {` — with:

```dart
      int nowMs = DateTime.now().millisecondsSinceEpoch;
      int watermarkMs =
          appStateSettings["EmailAutoTransactions-lastScannedEpochMs"] ??
              initialWatermarkMs(nowMs, await database.hasEmailTransactions());

      final authHeaders = await googleUser!.authHeaders;
      final authenticateClient = GoogleAuthClient(authHeaders);
      gMail.GmailApi gmailApi = gMail.GmailApi(authenticateClient);

      List<ScannerTemplate> scannerTemplates =
          await database.getAllScannerTemplates();
      if (scannerTemplates.length <= 0) {
        openSnackbar(
          SnackbarMessage(
            title:
                "You have not setup the email scanning configuration in settings.",
            onTap: () {
              pushRoute(context, AutoTransactionsPageEmail());
            },
          ),
        );
      }

      // List all message ids received after the watermark (ids only = cheap),
      // newest-first, paginating up to a generous safety cap.
      final String query = buildGmailAfterQuery(watermarkMs);
      List<gMail.Message> listed = [];
      String? pageToken;
      int listedPages = 0;
      do {
        gMail.ListMessagesResponse results =
            await gmailApi.users.messages.list(
          googleUser!.id.toString(),
          q: query,
          maxResults: emailScanPageSize,
          pageToken: pageToken,
        );
        if (results.messages != null) listed.addAll(results.messages!);
        pageToken = results.nextPageToken;
        listedPages++;
      } while (pageToken != null && listedPages < emailScanMaxListPages);

      // Gmail returns newest-first; process oldest-first (capped) so older mail
      // is not skipped and the watermark advances forward across scans.
      List<gMail.Message> toProcess =
          listed.reversed.take(emailScanMaxProcessPerScan).toList();

      List<Transaction> transactionsToAdd = [];
      List<int> handledInternalDatesMs = [];
      int newEmailCount = 0;
      int currentEmailIndex = 0;

      for (gMail.Message message in toProcess) {
        currentEmailIndex++;
        loadingProgressKey.currentState
            ?.setProgressPercentage(currentEmailIndex / toProcess.length);

        gMail.Message messageData = await gmailApi.users.messages
            .get(googleUser!.id.toString(), message.id!);
        int internalDateMs = int.tryParse(messageData.internalDate ?? "") ?? 0;

        // Timestamp dedup: skip the boundary-second overlap the (second-granular)
        // after: query can re-return.
        if (!isNewerThanWatermark(internalDateMs, watermarkMs)) {
          continue;
        }
        // Fully examined from here on -> record so the watermark advances past
        // this email regardless of outcome (match, no-match, or skip).
        handledInternalDatesMs.add(internalDateMs);

        DateTime messageDate =
            DateTime.fromMillisecondsSinceEpoch(internalDateMs);
        String messageString = getEmailMessage(messageData);

        String? title;
        double? amountDouble;
        ScannerTemplate? templateFound;
        for (ScannerTemplate scannerTemplate in scannerTemplates) {
          if (messageString.contains(scannerTemplate.contains)) {
            templateFound = scannerTemplate;
            title = getTransactionTitleFromEmail(
              messageString,
              scannerTemplate.titleTransactionBefore,
              scannerTemplate.titleTransactionAfter,
            );
            amountDouble = getTransactionAmountFromEmail(
              messageString,
              scannerTemplate.amountTransactionBefore,
              scannerTemplate.amountTransactionAfter,
            );
            break;
          }
        }

        if (templateFound == null) continue;
        if (title == null) {
          openSnackbar(SnackbarMessage(
            title:
                "Couldn't find title in email. Check the email settings page for more information.",
            onTap: () {
              pushRoute(context, AutoTransactionsPageEmail());
            },
          ));
          continue;
        }
        if (amountDouble == null) {
          openSnackbar(SnackbarMessage(
            title:
                "Couldn't find amount in email. Check the email settings page for more information.",
            onTap: () {
              pushRoute(context, AutoTransactionsPageEmail());
            },
          ));
          continue;
        }

        TransactionAssociatedTitleWithCategory? foundTitle =
            (await database.getSimilarAssociatedTitles(title: title, limit: 1))
                .firstOrNull;
        TransactionCategory? selectedCategory = foundTitle?.category;
        if (selectedCategory == null) {
          selectedCategory = await aiCategorizeEmailMerchant(title);
        }
        if (selectedCategory == null) {
          // Fall back to the template's default category (always set) so a
          // matched email is never lost when the cache misses and AI is
          // unavailable — and so the watermark can safely advance past it.
          selectedCategory = await database
              .getCategoryInstanceOrNull(templateFound.defaultCategoryFk);
        }
        if (selectedCategory == null) continue;

        await addAssociatedTitles(title, selectedCategory);
        title = filterEmailTitle(title);

        transactionsToAdd.add(Transaction(
          transactionPk: "-1",
          name: title,
          amount: (amountDouble).abs() * (selectedCategory.income ? 1 : -1),
          note: "",
          categoryFk: selectedCategory.categoryPk,
          walletFk: appStateSettings["selectedWalletPk"],
          dateCreated: messageDate,
          dateTimeModified: null,
          income: selectedCategory.income,
          paid: true,
          skipPaid: false,
          methodAdded: MethodAdded.email,
        ));
        newEmailCount++;
        openSnackbar(SnackbarMessage(
          title: templateFound.templateName + ": " + "From Email",
          description: title,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.payments_outlined
              : Icons.payments_rounded,
        ));
        // TODO have setting so they can choose if the emails are marked as read
        gmailApi.users.messages.modify(
          gMail.ModifyMessageRequest(removeLabelIds: ["UNREAD"]),
          googleUser!.id,
          message.id!,
        );
      }

      // wait for intro animation to finish
      if (Duration(milliseconds: 2500) > stopwatch.elapsed) {
        await Future.delayed(
            Duration(milliseconds: 2500) - stopwatch.elapsed, () {});
      }

      for (Transaction transaction in transactionsToAdd) {
        await database.createOrUpdateTransaction(insert: true, transaction);
      }

      // Advance & persist the watermark only after inserts committed, so an
      // interruption never advances past an uncommitted transaction.
      int newWatermarkMs = advanceWatermark(watermarkMs, handledInternalDatesMs);
      if (newWatermarkMs > watermarkMs) {
        await updateSettings(
            "EmailAutoTransactions-lastScannedEpochMs", newWatermarkMs,
            updateGlobalState: false);
      }

      if (newEmailCount > 0 || sayUpdates == true)
        openSnackbar(SnackbarMessage(
          title: "Scanned " + toProcess.length.toString() + " emails",
          description: newEmailCount.toString() +
              pluralString(newEmailCount == 1, " new email"),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.mark_email_unread_outlined
              : Icons.mark_email_unread_rounded,
          onTap: () {
            pushRoute(context, AutoTransactionsPageEmail());
          },
        ));
```

Notes:
- This removes all use of `EmailAutoTransactions-emailsParsed` and `EmailAutoTransactions-amountOfEmails` from the scan (the latter still drives the template-editor preview elsewhere — leave that untouched).
- `stopwatch` is already declared earlier in the function; keep it.
- The template-default fallback is new at this site (site A already had it): it guarantees a matched email always yields a category, so the watermark can advance past every examined email without losing transactions.

- [ ] **Step 3: Verify it analyzes clean**

Run: `fvm flutter analyze lib/pages/autoTransactionsPageEmail.dart`
Expected: No errors. Pre-existing info-level `withOpacity` deprecations elsewhere in the file are acceptable; the edited region must add none. If an unused-variable warning appears for a now-unused leftover (e.g. `amountOfEmails`), remove that leftover line.

- [ ] **Step 4: Run the full suite (no regressions)**

Run: `fvm flutter test`
Expected: PASS for the new watermark + hasEmailTransactions tests and all prior tests (the pre-existing `widget_test.dart` counter stub failure is unrelated and predates this work).

- [ ] **Step 5: Commit**

```bash
git add lib/pages/autoTransactionsPageEmail.dart
git commit -m "feat: scan emails via timestamp watermark + pagination (no id list)"
```

---

## One-time migration for this install (ops, after code lands)

Do this once, after Task 3 is merged and the app is rebuilt, so the first watermark scan backfills 30 days against a clean slate (no duplicates). Not a code change.

- [ ] **Quit the app** (so it isn't writing the DB).
- [ ] **Delete all transactions** (keep the category cache):

```bash
DB=~/Library/Containers/com.budget.budget/Data/Documents/db.sqlite
sqlite3 "$DB" "DELETE FROM transactions;"
```

- [ ] **Relaunch** with FVM + the dart-define. With no email transactions, `hasEmailTransactions()` returns false → the watermark initializes to `now − 30 days` → the first scan backfills the last month, then auto-advances.

## Manual verification (macOS)

- [ ] First launch after the reset: the scan runs and creates transactions for matching alerts from the **last 30 days**, once each (no duplicates).
- [ ] Relaunch immediately: the scan runs and creates **no** new/duplicate transactions (watermark now at the newest processed email; `after:` returns only the boundary, which the `internalDate_ms > watermark` check skips).
- [ ] Send yourself (or wait for) a new matching alert, relaunch: exactly one new transaction is created.
- [ ] Confirm `EmailAutoTransactions-lastScannedEpochMs` is set and advancing:
  `python3 -c "import plistlib,json,os;d=plistlib.load(open(os.path.expanduser('~/Library/Containers/com.budget.budget/Data/Library/Preferences/com.budget.budget.plist'),'rb'));print(json.loads(d['flutter.userSettings']).get('EmailAutoTransactions-lastScannedEpochMs'))"`

## Notes / decisions resolved here

- **Timestamp-only dedup**, no message-ID list (`emailsParsed` no longer used by the scan).
- **First-run guard** (`hasEmailTransactions()`) makes a 30-day-backfill default safe for both fresh and existing-data installs.
- **Oldest-first, listing complete + processing capped at 500** avoids the newest-first miss and bounds expensive work.
- **Template-default fallback at the scan site** ensures matched emails always categorize, so the watermark advances cleanly.

## Self-Review

- **Spec coverage:** Section 1 (watermark storage + first-run init) → Task 3 Step 2 (init via `initialWatermarkMs` + `hasEmailTransactions`) + Task 1/2; Section 2 (query, list-all, oldest-first, cap) → Task 1 helpers + Task 3 Step 2; Section 3 (per-message timestamp dedup, drop id list) → Task 3 Step 2; Section 4 (advance invariant, persist after inserts) → Task 3 Step 2; Section 5 (pure helpers) → Task 1; migration → "One-time migration" section; testing → Task 1/2 unit tests + Manual verification.
- **Placeholder scan:** none — full code in every code step. The only conditional notes are companion-arg/enum-name verifications (guardrails), not deferred work.
- **Type/name consistency:** `buildGmailAfterQuery`, `isNewerThanWatermark`, `advanceWatermark`, `initialWatermarkMs`, the three cap/size constants, `hasEmailTransactions()`, and setting key `EmailAutoTransactions-lastScannedEpochMs` are used identically in Tasks 1–3.
