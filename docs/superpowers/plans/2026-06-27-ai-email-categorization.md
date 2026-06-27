# AI Email Transaction Categorization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the email scanner sees a merchant with no cached category, ask Gemini Flash to classify it into one of the user's existing categories, create the transaction, and cache the result so each merchant costs at most one LLM call.

**Architecture:** A pure `normalizeMerchant()` function keys an exact merchant→category cache built on the existing `AssociatedTitles` table, extended with a `source` column (`user` | `ai`). A new `aiCategorization` service calls Gemini Flash over `http` with constrained JSON output. The three duplicated match-and-extract blocks in the email page collapse into one helper that does cache-read → AI-on-miss → fallback. User corrections write `source: user` and lock the merchant from the AI path.

**Tech Stack:** Flutter / Dart, Drift (SQLite ORM, `^2.14.0`), `http`, `shared_preferences`, `flutter_test` + `package:http/testing.dart` (`MockClient`).

## Global Constraints

- Categorization code **must never throw**. Every failure path (missing key, network error, rate-limit, refusal, unparseable output) logs and returns null/fallback. Worst case is "merchant skipped this scan," identical to today.
- **Never send financial data to Gemini**: request payload is the normalized merchant string + the user's category list (id + name) only. No amounts, accounts, dates, or raw email.
- Feature is a **no-op when the API key is empty** or the master toggle is off (off = today's skip-on-miss behavior).
- A `source: user` cache entry is **authoritative and locked**: the AI path never overwrites it and never re-queries that merchant.
- LLM provider is **Google Gemini Flash**, BYO API key, free tier, plain API key against `generativelanguage.googleapis.com` (independent of Google Sign-In OAuth).
- Follow existing codebase patterns: `updateSettings(...)` / `appStateSettings[...]` for settings, `TextInput` widget for text fields, `SettingsContainerSwitch` for toggles, drift migration via `migrationSteps(...)`.
- All file paths below are relative to `budget/` (the Flutter app root). Run all `dart`/`flutter` commands from `budget/`.

---

## File Structure

- **Create** `lib/struct/merchantNormalization.dart` — pure `normalizeMerchant(String)`.
- **Create** `lib/struct/aiCategorization.dart` — Gemini Flash service.
- **Create** `test/merchant_normalization_test.dart`, `test/ai_categorization_test.dart`.
- **Modify** `lib/database/tables.dart` — add `source` column, bump schema version, add migration step, add `getCachedCategoryForMerchant`.
- **Regenerate** `lib/database/tables.g.dart`, `lib/database/schema_versions.dart`, add `drift_schemas/drift_schema_v47.json` (build_runner + drift_dev, not hand-edited).
- **Modify** `lib/struct/defaultPreferences.dart` — two new settings keys.
- **Modify** `lib/pages/autoTransactionsPageEmail.dart` — consolidated helper + integration + settings UI.
- **Modify** `lib/pages/addTransactionPage.dart` — user-override write path sets `source: user`.

---

## Task 1: Merchant normalization

A pure, dependency-free function applied before every cache read and write so keys always match. Built first because everything downstream keys off it and it is trivially unit-testable.

**Files:**
- Create: `lib/struct/merchantNormalization.dart`
- Test: `test/merchant_normalization_test.dart`

**Interfaces:**
- Produces: `String normalizeMerchant(String rawTitle)` — top-level function, no imports needed by callers beyond this file.

- [ ] **Step 1: Write the failing test**

Create `test/merchant_normalization_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/merchantNormalization.dart';

void main() {
  group('normalizeMerchant', () {
    test('uppercases and collapses whitespace', () {
      expect(normalizeMerchant('  Chipotle   Mexican '), 'CHIPOTLE MEXICAN');
    });

    test('strips store-number tokens like #1234', () {
      expect(normalizeMerchant('CHIPOTLE #1234'), 'CHIPOTLE');
    });

    test('strips a US state + city location tail', () {
      expect(normalizeMerchant('CHIPOTLE #1234 NEW YORK NY'), 'CHIPOTLE');
    });

    test('strips trailing standalone digit groups', () {
      expect(normalizeMerchant('SQ *COFFEE 0093'), 'SQ *COFFEE');
    });

    test('does NOT collapse genuinely different merchants', () {
      expect(normalizeMerchant('AMAZON'),
          isNot(equals(normalizeMerchant('AMAZON PRIME'))));
    });

    test('returns empty string for empty/whitespace input', () {
      expect(normalizeMerchant('   '), '');
    });

    test('is idempotent', () {
      final once = normalizeMerchant('Chipotle #1234 New York NY');
      expect(normalizeMerchant(once), once);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/merchant_normalization_test.dart`
Expected: FAIL — `Error: ... 'package:budget/struct/merchantNormalization.dart'` not found / `normalizeMerchant` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `lib/struct/merchantNormalization.dart`:

```dart
// Pure merchant-name normalization used as the key for the merchant->category
// cache. Applied before EVERY cache read and write so keys always match.
// Deliberately conservative: it must never collapse genuinely different
// merchants together. See test/merchant_normalization_test.dart for the
// pinned behavior table.

// Two-letter US state codes used to detect and strip a trailing location tail.
const Set<String> _usStateCodes = {
  'AL', 'AK', 'AZ', 'AR', 'CA', 'CO', 'CT', 'DE', 'FL', 'GA', 'HI', 'ID',
  'IL', 'IN', 'IA', 'KS', 'KY', 'LA', 'ME', 'MD', 'MA', 'MI', 'MN', 'MS',
  'MO', 'MT', 'NE', 'NV', 'NH', 'NJ', 'NM', 'NY', 'NC', 'ND', 'OH', 'OK',
  'OR', 'PA', 'RI', 'SC', 'SD', 'TN', 'TX', 'UT', 'VT', 'VA', 'WA', 'WV',
  'WI', 'WY', 'DC',
};

String normalizeMerchant(String rawTitle) {
  // Uppercase + collapse all whitespace runs to single spaces.
  String s = rawTitle.toUpperCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return '';

  // Drop store-number tokens like "#1234" anywhere in the string.
  s = s.replaceAll(RegExp(r'#\s*\d+'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  // Tokenize and strip a trailing location tail: a final "<STATE>" optionally
  // preceded by a city, plus any trailing standalone digit groups.
  List<String> tokens = s.isEmpty ? [] : s.split(' ');

  // Strip a trailing two-letter state code and the single token before it
  // (treated as the city). Only strip when more than one meaningful token
  // remains, so we never reduce a merchant to nothing or to a bare state.
  if (tokens.length >= 3 && _usStateCodes.contains(tokens.last)) {
    tokens.removeLast(); // state
    tokens.removeLast(); // city
  }

  // Strip trailing standalone digit groups (e.g. terminal/transaction ids).
  while (tokens.length > 1 && RegExp(r'^\d+$').hasMatch(tokens.last)) {
    tokens.removeLast();
  }

  return tokens.join(' ').trim();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/merchant_normalization_test.dart`
Expected: PASS (7 tests). If a case fails, adjust the rule set and the test table together — the test is the spec for this function.

- [ ] **Step 5: Commit**

```bash
git add lib/struct/merchantNormalization.dart test/merchant_normalization_test.dart
git commit -m "feat: add merchant name normalization for category cache keys"
```

---

## Task 2: Cache data model — `source` column, migration, exact lookup

Add the `source` column to `AssociatedTitles`, migrate existing rows to `user`, regenerate drift code, and add the exact normalized cache lookup. The sync system serializes the whole drift data class, so the new column propagates automatically — verified, not hand-wired.

**Files:**
- Modify: `lib/database/tables.dart` (column `:404`, version `:29`, migration step after `:1166`, new query method near `:3115`)
- Regenerate: `lib/database/tables.g.dart`, `lib/database/schema_versions.dart`, `drift_schemas/drift_schema_v47.json`

**Interfaces:**
- Consumes: `normalizeMerchant` from Task 1.
- Produces:
  - Enum `enum AssociatedTitleSource { user, ai }` (top-level in `tables.dart`).
  - Column `IntColumn get source` on `AssociatedTitles` (stored as int index, default `0` = `user`).
  - `Future<TransactionAssociatedTitleWithCategory?> getCachedCategoryForMerchant(String normalizedMerchant)` on `FinanceDatabase` — exact (case-insensitive) match on the stored title, ordered `user` before `ai`. Returns null on miss.

- [ ] **Step 1: Add the `source` column and enum to the table definition**

In `lib/database/tables.dart`, add the enum just above `class AssociatedTitles extends Table {` (currently `:395`):

```dart
// Origin of an AssociatedTitles cache entry. `user` entries are authoritative
// and locked: the AI path never overwrites or re-queries them.
enum AssociatedTitleSource { user, ai }
```

Then add the column inside `AssociatedTitles` immediately after the `isExactMatch` line (currently `:404`):

```dart
  IntColumn get source =>
      intEnum<AssociatedTitleSource>().withDefault(const Constant(0))();
```

- [ ] **Step 2: Bump the schema version**

In `lib/database/tables.dart:29`, change:

```dart
int schemaVersionGlobal = 46;
```
to:
```dart
int schemaVersionGlobal = 47;
```

- [ ] **Step 3: Regenerate drift code**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: completes with `Succeeded`. `lib/database/tables.g.dart` now contains a `source` getter on `TransactionAssociatedTitle` and `AssociatedTitlesCompanion`.

- [ ] **Step 4: Export the v47 schema snapshot**

Run: `dart run drift_dev schema dump lib/database/tables.dart drift_schemas/`
Expected: creates `drift_schemas/drift_schema_v47.json`. Confirm the file exists:

Run: `ls drift_schemas/drift_schema_v47.json`
Expected: prints the path.

- [ ] **Step 5: Regenerate the versioned migration steps**

Run: `dart run drift_dev schema steps drift_schemas/ lib/database/schema_versions.dart`
Expected: `lib/database/schema_versions.dart` regenerated; the generated `migrationSteps(...)` helper now accepts a `from46To47` named parameter.

- [ ] **Step 6: Add the `from46To47` migration step**

In `lib/database/tables.dart`, inside the `migrationSteps(...)` call, immediately after the closing `},` of the `from45To46:` step (currently ends `:1166`), add:

```dart
            from46To47: (m, schema) async {
              try {
                await m.addColumn(
                    schema.associatedTitles, schema.associatedTitles.source);
              } catch (e) {
                print(
                    "Migration Error: Error creating column associatedTitles.source " +
                        e.toString());
              }
            },
```

Note: the column default `0` (`user`) means all pre-existing rows read back as `AssociatedTitleSource.user` with no data backfill needed.

- [ ] **Step 7: Add the exact cache-lookup method**

In `lib/database/tables.dart`, add this method just before `createOrUpdateAssociatedTitle` (currently `:3125`). It mirrors the join style of `getSimilarAssociatedTitles` but uses exact (case-insensitive) equality and prefers `user` over `ai`:

```dart
  // Exact, normalized-equality cache read for AI auto-categorization.
  // Distinct from the fuzzy getSimilarAssociatedTitles (LIKE %title%), which
  // stays for the suggestion feature. `user` entries win over `ai` entries.
  Future<TransactionAssociatedTitleWithCategory?> getCachedCategoryForMerchant(
      String normalizedMerchant) async {
    if (normalizedMerchant.trim().isEmpty) return null;
    final rows = await (select(associatedTitles).join([
      innerJoin(categories,
          categories.categoryPk.equalsExp(associatedTitles.categoryFk)),
    ])
          ..where(associatedTitles.title
              .collate(Collate.noCase)
              .equals(normalizedMerchant))
          ..orderBy([OrderingTerm.asc(associatedTitles.source)])
          ..limit(1))
        .get();
    if (rows.isEmpty) return null;
    return TransactionAssociatedTitleWithCategory(
      title: rows.first.readTable(associatedTitles),
      category: rows.first.readTable(categories),
      type: TitleType.TitleExists,
    );
  }
```

(`source` is stored as the enum index, so `OrderingTerm.asc` puts `user` (0) before `ai` (1).)

- [ ] **Step 8: Write a precedence test**

Create `test/cache_lookup_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:budget/database/tables.dart';

void main() {
  late FinanceDatabase db;

  setUp(() {
    db = FinanceDatabase(NativeDatabase.memory());
  });
  tearDown(() async => await db.close());

  Future<void> seedCategory(String pk) async {
    await db.into(db.categories).insert(
          CategoriesCompanion.insert(
            categoryPk: Value(pk),
            name: 'Cat $pk',
            order: 0,
            dateCreated: Value(DateTime.now()),
            income: const Value(false),
            methodAdded: const Value(null),
          ),
        );
  }

  Future<void> seedTitle(String title, String catPk,
      AssociatedTitleSource source) async {
    await db.into(db.associatedTitles).insert(
          AssociatedTitlesCompanion.insert(
            categoryFk: catPk,
            title: title,
            order: 0,
            source: Value(source),
          ),
        );
  }

  test('exact normalized lookup hits and misses', () async {
    await seedCategory('c1');
    await seedTitle('CHIPOTLE', 'c1', AssociatedTitleSource.ai);

    final hit = await db.getCachedCategoryForMerchant('CHIPOTLE');
    expect(hit?.category.categoryPk, 'c1');

    final miss = await db.getCachedCategoryForMerchant('STARBUCKS');
    expect(miss, isNull);
  });

  test('user entry wins over ai entry for the same merchant', () async {
    await seedCategory('cUser');
    await seedCategory('cAi');
    await seedTitle('CHIPOTLE', 'cAi', AssociatedTitleSource.ai);
    await seedTitle('CHIPOTLE', 'cUser', AssociatedTitleSource.user);

    final hit = await db.getCachedCategoryForMerchant('CHIPOTLE');
    expect(hit?.category.categoryPk, 'cUser');
  });
}
```

If the generated `CategoriesCompanion.insert` / `AssociatedTitlesCompanion.insert` required-argument lists differ from above, adjust the named args to match the generated signatures in `lib/database/tables.g.dart` (the column set is what matters; fill required fields, leave the rest defaulted).

- [ ] **Step 9: Run the cache + normalization tests**

Run: `flutter test test/cache_lookup_test.dart test/merchant_normalization_test.dart`
Expected: PASS.

- [ ] **Step 10: Verify sync propagation (read-only check, no code change)**

The sync layer ships `itemToUpdate: newEntry` (the full `TransactionAssociatedTitle` data class) in `lib/struct/syncClient.dart:435`, and drift's generated `toJson`/`fromJson` include every column. Confirm `source` is in the generated serializers:

Run: `grep -n "source" lib/database/tables.g.dart | grep -i "json\|source:"`
Expected: `source` appears in `TransactionAssociatedTitle.toJson` and `fromJson`. No code change needed; note this in the commit body.

- [ ] **Step 11: Commit**

```bash
git add lib/database/tables.dart lib/database/tables.g.dart lib/database/schema_versions.dart drift_schemas/drift_schema_v47.json test/cache_lookup_test.dart
git commit -m "feat: add source column and exact merchant cache lookup to AssociatedTitles

Sync propagation is automatic: the data class serializers include the new column."
```

---

## Task 3: Gemini Flash categorization service

A self-contained service with an injectable `http.Client` so it is fully testable with `MockClient`. Never throws; returns a category id or null.

**Files:**
- Create: `lib/struct/aiCategorization.dart`
- Test: `test/ai_categorization_test.dart`

**Interfaces:**
- Produces:
  - `class AiCategoryChoice { final String id; final String name; const AiCategoryChoice(this.id, this.name); }`
  - `Future<String?> aiCategorizeMerchant({ required String normalizedMerchant, required List<AiCategoryChoice> categories, required String apiKey, String model = 'gemini-2.0-flash', http.Client? client })` — returns the chosen category **id** (guaranteed to be one of `categories`), or null on any failure / empty key / empty categories.

- [ ] **Step 1: Write the failing test**

Create `test/ai_categorization_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:budget/struct/aiCategorization.dart';

const _cats = [
  AiCategoryChoice('food', 'Food'),
  AiCategoryChoice('travel', 'Travel'),
];

void main() {
  test('returns the chosen category id on a valid response', () async {
    final mock = MockClient((req) async {
      // Gemini wraps the JSON output as text inside candidates.
      final body = jsonEncode({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': '{"categoryId": "food"}'}
              ]
            }
          }
        ]
      });
      return http.Response(body, 200);
    });

    final result = await aiCategorizeMerchant(
      normalizedMerchant: 'CHIPOTLE',
      categories: _cats,
      apiKey: 'test-key',
      client: mock,
    );
    expect(result, 'food');
  });

  test('returns null when the model picks an id not in the list', () async {
    final mock = MockClient((req) async => http.Response(
        jsonEncode({
          'candidates': [
            {'content': {'parts': [{'text': '{"categoryId": "made-up"}'}]}}
          ]
        }),
        200));
    final result = await aiCategorizeMerchant(
        normalizedMerchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null on HTTP error (e.g. rate limit 429)', () async {
    final mock = MockClient((req) async => http.Response('rate limited', 429));
    final result = await aiCategorizeMerchant(
        normalizedMerchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null on a thrown network error (never rethrows)', () async {
    final mock = MockClient((req) async => throw Exception('no network'));
    final result = await aiCategorizeMerchant(
        normalizedMerchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null on unparseable response body', () async {
    final mock = MockClient((req) async => http.Response('not json', 200));
    final result = await aiCategorizeMerchant(
        normalizedMerchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null and makes no call when apiKey is empty', () async {
    var called = false;
    final mock = MockClient((req) async {
      called = true;
      return http.Response('{}', 200);
    });
    final result = await aiCategorizeMerchant(
        normalizedMerchant: 'X', categories: _cats, apiKey: '', client: mock);
    expect(result, isNull);
    expect(called, isFalse);
  });

  test('returns null and makes no call when categories is empty', () async {
    var called = false;
    final mock = MockClient((req) async {
      called = true;
      return http.Response('{}', 200);
    });
    final result = await aiCategorizeMerchant(
        normalizedMerchant: 'X', categories: const [], apiKey: 'k', client: mock);
    expect(result, isNull);
    expect(called, isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ai_categorization_test.dart`
Expected: FAIL — `aiCategorization.dart` / `AiCategoryChoice` / `aiCategorizeMerchant` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/struct/aiCategorization.dart`:

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;

// A category the model is allowed to choose from. Only id + name are ever sent
// to Gemini — never amounts, accounts, or raw email content.
class AiCategoryChoice {
  final String id;
  final String name;
  const AiCategoryChoice(this.id, this.name);
}

// Classifies a normalized merchant into one of [categories] using Gemini Flash.
// Returns the chosen category id (always one of [categories]) or null on ANY
// failure. This function never throws.
Future<String?> aiCategorizeMerchant({
  required String normalizedMerchant,
  required List<AiCategoryChoice> categories,
  required String apiKey,
  String model = 'gemini-2.0-flash',
  http.Client? client,
}) async {
  if (apiKey.trim().isEmpty) return null;
  if (categories.isEmpty) return null;
  if (normalizedMerchant.trim().isEmpty) return null;

  final ownClient = client == null;
  final httpClient = client ?? http.Client();
  try {
    final allowedIds = categories.map((c) => c.id).toList();
    final categoryList = categories
        .map((c) => '- ${c.id}: ${c.name}')
        .join('\n');

    final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey');

    final requestBody = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'text': 'You categorize credit-card merchants. Choose the single '
                  'best matching category for this merchant and respond with its '
                  'id.\n\nMerchant: "$normalizedMerchant"\n\n'
                  'Categories:\n$categoryList'
            }
          ]
        }
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'OBJECT',
          'properties': {
            'categoryId': {'type': 'STRING', 'enum': allowedIds}
          },
          'required': ['categoryId']
        }
      }
    });

    final response = await httpClient.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: requestBody,
    );

    if (response.statusCode != 200) {
      print('aiCategorizeMerchant: HTTP ${response.statusCode}: ${response.body}');
      return null;
    }

    final decoded = jsonDecode(response.body);
    final text = decoded['candidates']?[0]?['content']?['parts']?[0]?['text'];
    if (text is! String) return null;

    final parsed = jsonDecode(text);
    final chosen = parsed['categoryId'];
    if (chosen is! String) return null;

    // Enforce the contract even if the model ignores the schema.
    if (!allowedIds.contains(chosen)) return null;
    return chosen;
  } catch (e) {
    print('aiCategorizeMerchant: error: $e');
    return null;
  } finally {
    if (ownClient) httpClient.close();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ai_categorization_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/struct/aiCategorization.dart test/ai_categorization_test.dart
git commit -m "feat: add Gemini Flash merchant categorization service"
```

---

## Task 4: Settings (preferences + UI)

Add the two settings keys and a UI surface (API key field + master toggle + privacy note) on the existing Auto Transactions email page.

**Files:**
- Modify: `lib/struct/defaultPreferences.dart` (near `:126`)
- Modify: `lib/pages/autoTransactionsPageEmail.dart` (settings list in `build`, around `:378–387`)

**Interfaces:**
- Consumes: `updateSettings`, `appStateSettings`, `TextInput`, `SettingsContainerSwitch`, `TextFont` (all already imported in the email page).
- Produces: settings keys `"aiCategorizationEnabled"` (bool) and `"geminiApiKey"` (String) readable via `appStateSettings[...]`.

- [ ] **Step 1: Add default preferences**

In `lib/struct/defaultPreferences.dart`, after the `"autoAddAssociatedTitles": true,` line (`:126`), add:

```dart
    "aiCategorizationEnabled": false,
    "geminiApiKey": "",
```

- [ ] **Step 2: Add the settings UI to the email page**

In `lib/pages/autoTransactionsPageEmail.dart`, inside the `listWidgets:` list in `build` (the `AutoTransactionsPageEmail` state, `:337`), add the following just after the `IgnorePointer(...GmailApiScreen()...)` entry that currently ends around `:386`, before the list's closing `]`:

```dart
        SettingsContainerSwitch(
          title: "AI Categorization",
          description:
              "When a merchant has no saved category, ask Gemini to pick one of your existing categories. Each merchant is asked about only once, then cached.",
          onSwitched: (value) async {
            updateSettings("aiCategorizationEnabled", value,
                updateGlobalState: false, pagesNeedingRefresh: []);
          },
          initialValue: appStateSettings["aiCategorizationEnabled"],
          icon: appStateSettings["outlinedIcons"]
              ? Icons.auto_awesome_outlined
              : Icons.auto_awesome_rounded,
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(top: 5, bottom: 5),
          child: TextInput(
            labelText: "Gemini API Key",
            initialValue: appStateSettings["geminiApiKey"],
            obscureText: true,
            icon: appStateSettings["outlinedIcons"]
                ? Icons.key_outlined
                : Icons.key_rounded,
            onChanged: (value) {
              updateSettings("geminiApiKey", value,
                  updateGlobalState: false, pagesNeedingRefresh: []);
            },
          ),
        ),
        Padding(
          padding:
              const EdgeInsetsDirectional.only(bottom: 5, start: 20, end: 20),
          child: TextFont(
            text:
                "Only the merchant name and your category names are sent to Google — never amounts or account details. On Gemini's free tier, Google may use submitted data to improve its products.",
            fontSize: 13,
            maxLines: 10,
          ),
        ),
```

- [ ] **Step 3: Verify it compiles**

Run: `flutter analyze lib/pages/autoTransactionsPageEmail.dart lib/struct/defaultPreferences.dart`
Expected: No errors. (If `TextInput` is not yet imported in the email page, add `import 'package:budget/widgets/textInput.dart';` to the file's imports — confirm against existing imports first.)

- [ ] **Step 4: Commit**

```bash
git add lib/struct/defaultPreferences.dart lib/pages/autoTransactionsPageEmail.dart
git commit -m "feat: add AI categorization settings (toggle, API key, privacy note)"
```

---

## Task 5: Integration — consolidate match-and-extract and wire AI on cache miss

Replace the skip-on-miss with cache-read → AI → fallback in one shared helper, and make the user-correction write path stamp `source: user` so it locks the merchant. This task touches the two flows that currently duplicate the match logic.

**Files:**
- Modify: `lib/pages/autoTransactionsPageEmail.dart` (new helper; call sites `:122–130` and `:532–541`)
- Modify: `lib/pages/addTransactionPage.dart` (`addAssociatedTitles`, `:3001–3058`)

**Interfaces:**
- Consumes: `normalizeMerchant` (Task 1), `getCachedCategoryForMerchant` + `AssociatedTitleSource` (Task 2), `aiCategorizeMerchant` + `AiCategoryChoice` (Task 3), settings keys (Task 4).
- Produces: `Future<TransactionCategory?> resolveCategoryForMerchant(String rawTitle, String? defaultCategoryFk)` (top-level in `autoTransactionsPageEmail.dart`).

- [ ] **Step 1: Add imports to the email page**

In `lib/pages/autoTransactionsPageEmail.dart` imports, add (confirm none already present):

```dart
import 'package:budget/struct/merchantNormalization.dart';
import 'package:budget/struct/aiCategorization.dart';
```

- [ ] **Step 2: Add the shared resolver helper**

In `lib/pages/autoTransactionsPageEmail.dart`, add this top-level function (e.g. just above `parseEmailsInBackground` at `:392`):

```dart
// Single source of truth for turning a raw email merchant title into a
// category: exact normalized cache -> Gemini (on miss, if enabled) -> template
// default. Returns null only when there is no category to use (caller skips).
// Never throws.
Future<TransactionCategory?> resolveCategoryForMerchant(
    String rawTitle, String? defaultCategoryFk) async {
  final String normalized = normalizeMerchant(rawTitle);

  // 1. Exact cache (user entries win over ai entries).
  final cached = await database.getCachedCategoryForMerchant(normalized);
  if (cached != null) return cached.category;

  // 2. Gemini on cache miss, only if enabled and configured.
  final bool aiEnabled = appStateSettings["aiCategorizationEnabled"] == true;
  final String apiKey = appStateSettings["geminiApiKey"] ?? "";
  if (aiEnabled && apiKey.trim().isNotEmpty && normalized.isNotEmpty) {
    try {
      final List<TransactionCategory> userCategories =
          await database.getAllCategories();
      final choices = userCategories
          .map((c) => AiCategoryChoice(c.categoryPk, c.name))
          .toList();
      final String? chosenId = await aiCategorizeMerchant(
        normalizedMerchant: normalized,
        categories: choices,
        apiKey: apiKey,
      );
      if (chosenId != null) {
        final TransactionCategory? chosen =
            await database.getCategoryInstanceOrNull(chosenId);
        if (chosen != null) {
          // Cache as an ai entry keyed by the normalized merchant.
          await database.createOrUpdateAssociatedTitle(
            insert: true,
            TransactionAssociatedTitle(
              associatedTitlePk: "-1",
              categoryFk: chosen.categoryPk,
              isExactMatch: false,
              title: normalized,
              dateCreated: DateTime.now(),
              dateTimeModified: null,
              order: await database.getAmountOfAssociatedTitles(),
              source: AssociatedTitleSource.ai,
            ),
          );
          return chosen;
        }
      }
    } catch (e) {
      print("resolveCategoryForMerchant: AI path error: $e");
    }
  }

  // 3. Fallback to the template default (may be null -> caller skips).
  if (defaultCategoryFk != null) {
    return await database.getCategoryInstanceOrNull(defaultCategoryFk);
  }
  return null;
}
```

Note: the `TransactionAssociatedTitle(...)` constructor now requires `source:` (added in Task 2). Match the exact constructor argument order/names generated in `tables.g.dart` if they differ.

- [ ] **Step 3: Wire the background-scan call site**

In `lib/pages/autoTransactionsPageEmail.dart`, replace the block at `:532–537`:

```dart
        TransactionAssociatedTitleWithCategory? foundTitle =
            (await database.getSimilarAssociatedTitles(title: title, limit: 1))
                .firstOrNull;

        TransactionCategory? selectedCategory = foundTitle?.category;
        if (selectedCategory == null) continue;
```

with:

```dart
        TransactionCategory? selectedCategory =
            await resolveCategoryForMerchant(
                title, templateFound?.defaultCategoryFk);
        if (selectedCategory == null) continue;
```

(`title` is reassigned by `filterEmailTitle(title)` on the next existing line `:539` and `addAssociatedTitles(title, selectedCategory)` at `:541` stays — that records the user-facing title for the suggestion feature as today.)

- [ ] **Step 4: Wire the queue/test call site**

In `lib/pages/autoTransactionsPageEmail.dart`, replace the block at `:122–130`:

```dart
  TransactionCategory? category;
  TransactionAssociatedTitleWithCategory? foundTitle =
      (await database.getSimilarAssociatedTitles(title: title, limit: 1))
          .firstOrNull;
  category = foundTitle?.category;
  if (category == null) {
    category = await database
        .getCategoryInstanceOrNull(templateFound.defaultCategoryFk);
  }
```

with:

```dart
  TransactionCategory? category =
      await resolveCategoryForMerchant(title, templateFound.defaultCategoryFk);
```

- [ ] **Step 5: Make the user-correction write path stamp `source: user`**

In `lib/pages/addTransactionPage.dart`, in `addAssociatedTitles` (`:3001`), the new-entry branch creates a `TransactionAssociatedTitle` (`:3042–3050`). Add `source: AssociatedTitleSource.user,` to that constructor and switch the write to overwrite any existing `ai` entry for the normalized merchant. Replace the `else` branch body (`:3036–3052`) with:

```dart
      } else {
        // If there is no existing fuzzy match, create/overwrite the cache entry.
        // A user action is authoritative: replace any prior ai entry for this
        // normalized merchant and stamp it as user-sourced.
        print("Creating new associated title (user)");
        final String normalized = normalizeMerchant(selectedTitle);
        final existingAi =
            await database.getCachedCategoryForMerchant(normalized);
        if (existingAi != null &&
            existingAi.title.source == AssociatedTitleSource.ai) {
          await database.deleteAssociatedTitle(
              existingAi.title.associatedTitlePk, existingAi.title.order);
        }
        int length = await database.getAmountOfAssociatedTitles();
        await database.createOrUpdateAssociatedTitle(
          insert: true,
          TransactionAssociatedTitle(
            associatedTitlePk: "-1",
            categoryFk: selectedCategory.categoryPk,
            isExactMatch: false,
            title: selectedTitle.trim(),
            dateCreated: DateTime.now(),
            dateTimeModified: null,
            order: length,
            source: AssociatedTitleSource.user,
          ),
        );
      }
```

Add the import at the top of `lib/pages/addTransactionPage.dart` (confirm not already present):

```dart
import 'package:budget/struct/merchantNormalization.dart';
```

(`AssociatedTitleSource` and `TransactionAssociatedTitle` come from the already-imported `database/tables.dart`.)

- [ ] **Step 6: Write the precedence integration test**

Create `test/categorization_precedence_test.dart`. It verifies the cache-precedence contract at the database layer: an `ai` entry exists, a `user` correction overwrites it, and the exact lookup then returns the user category and reports `source == user` (so the AI path defers and won't re-query).

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/merchantNormalization.dart';

void main() {
  late FinanceDatabase db;
  setUp(() => db = FinanceDatabase(NativeDatabase.memory()));
  tearDown(() async => await db.close());

  test('user correction overwrites ai entry and locks the merchant', () async {
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        categoryPk: const Value('cAi'), name: 'AI Cat', order: 0));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        categoryPk: const Value('cUser'), name: 'User Cat', order: 1));

    final normalized = normalizeMerchant('Chipotle #1234');

    // AI writes first.
    await db.into(db.associatedTitles).insert(AssociatedTitlesCompanion.insert(
        categoryFk: 'cAi',
        title: normalized,
        order: 0,
        source: const Value(AssociatedTitleSource.ai)));

    var hit = await db.getCachedCategoryForMerchant(normalized);
    expect(hit?.category.categoryPk, 'cAi');
    expect(hit?.title.source, AssociatedTitleSource.ai);

    // User correction: delete ai entry, insert user entry (as addAssociatedTitles does).
    await db.deleteAssociatedTitle(
        hit!.title.associatedTitlePk, hit.title.order);
    await db.into(db.associatedTitles).insert(AssociatedTitlesCompanion.insert(
        categoryFk: 'cUser',
        title: normalized,
        order: 1,
        source: const Value(AssociatedTitleSource.user)));

    hit = await db.getCachedCategoryForMerchant(normalized);
    expect(hit?.category.categoryPk, 'cUser');
    expect(hit?.title.source, AssociatedTitleSource.user);
  });
}
```

Adjust `CategoriesCompanion.insert` / `AssociatedTitlesCompanion.insert` named args to match the generated required-field signatures if needed.

- [ ] **Step 7: Run all tests**

Run: `flutter test`
Expected: PASS — all new test files green.

- [ ] **Step 8: Static analysis on touched files**

Run: `flutter analyze lib/pages/autoTransactionsPageEmail.dart lib/pages/addTransactionPage.dart`
Expected: No errors.

- [ ] **Step 9: Commit**

```bash
git add lib/pages/autoTransactionsPageEmail.dart lib/pages/addTransactionPage.dart test/categorization_precedence_test.dart
git commit -m "feat: categorize first-seen email merchants via Gemini with cache + user override"
```

---

## Notes deferred from the spec (resolved here)

- **Gemini model ID:** default `gemini-2.0-flash` (current free-tier Flash). Configurable via the `model` parameter; change the default in `aiCategorization.dart` if a newer free Flash model is preferred at implementation time.
- **`responseSchema` shape:** an object with a single `categoryId` string constrained by `enum` to the user's existing category ids (Task 3, Step 3).
- **Normalization rule set:** pinned by the test table in Task 1; extend tests + rules together if real-world merchant strings need more cases.
- **Settings placement & privacy copy:** on the existing Auto Transactions email page, below the Gmail screen (Task 4).
- **Phase 0 (Google Sign-In on macOS)** from the spec is a separate prerequisite for *running* the scan on macOS and is **out of scope for this plan** — the categorization code is platform-neutral and fully testable without it.

## Self-Review

- **Spec coverage:** Section 1 data model/cache → Task 2; precedence/override → Task 2 + Task 5 Step 5; migration/sync → Task 2 Steps 1–6, 10. Section 2 normalization → Task 1. Section 3 Gemini service → Task 3. Section 4 integration / dedup of the match-and-extract blocks → Task 5 (two call sites consolidated into `resolveCategoryForMerchant`). Section 5 settings → Task 4. Testing section → tests in Tasks 1, 2, 3, 5. Error-handling/safety constraints → Global Constraints + Task 3 failure tests. All four open items → "Notes deferred" above.
- **Placeholder scan:** none — every code/step is concrete; the only conditional notes are "confirm import not already present" and "adjust generated companion args if signatures differ," which are verification instructions, not deferred work.
- **Type consistency:** `AssociatedTitleSource` enum, `getCachedCategoryForMerchant` return type (`TransactionAssociatedTitleWithCategory?`), `aiCategorizeMerchant` signature, `AiCategoryChoice`, and `resolveCategoryForMerchant` are referenced identically across tasks.
- **Note on the third "in-page test" block:** the spec referenced three duplicated blocks (~`:476`, ~`:100`, ~`:936`). In the current file there are two live match-and-extract sites (`:122` and `:532`); both are consolidated. No third independent extract block exists at `:936` in the current code — the consolidation goal is met with the two real sites.
