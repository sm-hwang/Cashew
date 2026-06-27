# AI Email Transaction Categorization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the email scanner sees a merchant with no cached category, ask Gemini Flash to classify it into one of the user's existing categories and use that; the existing cache machinery records the result so each merchant costs at most one LLM call.

**Architecture:** No database changes and no merchant normalization (see the spec's "Scope revision" note). The cache key stays the raw email title, which `AssociatedTitles` already stores. The existing `getSimilarAssociatedTitles` is the cache read and `addAssociatedTitles` is the cache write. A new `aiCategorization` service calls Gemini Flash over `http` with constrained JSON output. At the two sites where the email flow resolves a category, a cache miss now calls Gemini before falling through to today's behavior (skip, or template default).

**Tech Stack:** Flutter / Dart, `http`, `shared_preferences`, `flutter_test` + `package:http/testing.dart` (`MockClient`).

## Global Constraints

- Categorization code **must never throw**. Every failure path (missing key, network error, rate-limit, refusal, unparseable output) logs and returns null. Worst case is identical to today's behavior at each site (skip, or template default).
- **Never send financial data to Gemini**: request payload is the merchant title + the user's category list (id + name) only. No amounts, accounts, dates, or raw email.
- Feature is a **no-op when the API key is empty** or the master toggle is off. With the feature off, each cache-miss site behaves exactly as it does today.
- The user-correction lock is automatic and must be preserved: Gemini is only called on a true cache miss, so it can never overwrite a category the user (or a prior run) already cached. **Do not add any code that overwrites or deletes existing `AssociatedTitles` entries.**
- LLM provider is **Google Gemini Flash**, BYO API key, free tier, plain API key against `generativelanguage.googleapis.com`.
- **No database / Drift / migration / `tables.dart` changes.** No `build_runner` runs.
- Follow existing codebase patterns: `updateSettings(...)` / `appStateSettings[...]` for settings, `TextInput` widget for text fields, `SettingsContainerSwitch` for toggles.
- All paths below are relative to `budget/` (the Flutter app root). Run all `dart`/`flutter` commands from `budget/`.

---

## File Structure

- **Create** `lib/struct/aiCategorization.dart` — Gemini Flash service.
- **Create** `test/ai_categorization_test.dart`.
- **Modify** `lib/struct/defaultPreferences.dart` — two new settings keys.
- **Modify** `lib/pages/autoTransactionsPageEmail.dart` — a settings UI block, a small `aiCategorizeEmailMerchant` wrapper, and the cache-miss change at the two resolve sites.

---

## Task 1: Gemini Flash categorization service

A self-contained service with an injectable `http.Client` so it is fully testable with `MockClient`. Never throws; returns a category id (guaranteed to be one of the supplied ids) or null.

**Files:**
- Create: `lib/struct/aiCategorization.dart`
- Test: `test/ai_categorization_test.dart`

**Interfaces:**
- Produces:
  - `class AiCategoryChoice { final String id; final String name; const AiCategoryChoice(this.id, this.name); }`
  - `Future<String?> aiCategorizeMerchant({ required String merchant, required List<AiCategoryChoice> categories, required String apiKey, String model = 'gemini-2.0-flash', http.Client? client })` — returns the chosen category **id**, or null on any failure / empty key / empty categories / empty merchant.

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
      merchant: 'CHIPOTLE #1234',
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
        merchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null on HTTP error (e.g. rate limit 429)', () async {
    final mock = MockClient((req) async => http.Response('rate limited', 429));
    final result = await aiCategorizeMerchant(
        merchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null on a thrown network error (never rethrows)', () async {
    final mock = MockClient((req) async => throw Exception('no network'));
    final result = await aiCategorizeMerchant(
        merchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null on unparseable response body', () async {
    final mock = MockClient((req) async => http.Response('not json', 200));
    final result = await aiCategorizeMerchant(
        merchant: 'X', categories: _cats, apiKey: 'k', client: mock);
    expect(result, isNull);
  });

  test('returns null and makes no call when apiKey is empty', () async {
    var called = false;
    final mock = MockClient((req) async {
      called = true;
      return http.Response('{}', 200);
    });
    final result = await aiCategorizeMerchant(
        merchant: 'X', categories: _cats, apiKey: '', client: mock);
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
        merchant: 'X', categories: const [], apiKey: 'k', client: mock);
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

// Classifies a merchant into one of [categories] using Gemini Flash.
// Returns the chosen category id (always one of [categories]) or null on ANY
// failure. This function never throws.
Future<String?> aiCategorizeMerchant({
  required String merchant,
  required List<AiCategoryChoice> categories,
  required String apiKey,
  String model = 'gemini-2.0-flash',
  http.Client? client,
}) async {
  if (apiKey.trim().isEmpty) return null;
  if (categories.isEmpty) return null;
  if (merchant.trim().isEmpty) return null;

  final ownClient = client == null;
  final httpClient = client ?? http.Client();
  try {
    final allowedIds = categories.map((c) => c.id).toList();
    final categoryList =
        categories.map((c) => '- ${c.id}: ${c.name}').join('\n');

    final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey');

    final requestBody = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'text': 'You categorize credit-card merchants. Choose the single '
                  'best matching category for this merchant and respond with its '
                  'id.\n\nMerchant: "$merchant"\n\n'
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
      print(
          'aiCategorizeMerchant: HTTP ${response.statusCode}: ${response.body}');
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

## Task 2: Settings (preferences + UI)

Add the two settings keys and a UI surface (master toggle + API key field + privacy note) on the existing Auto Transactions email page.

**Files:**
- Modify: `lib/struct/defaultPreferences.dart` (after the `"autoAddAssociatedTitles": true,` line, ~`:126`)
- Modify: `lib/pages/autoTransactionsPageEmail.dart` (the `listWidgets:` list in the `AutoTransactionsPageEmail` `build`, the entries end ~`:386`)

**Interfaces:**
- Consumes: `updateSettings`, `appStateSettings`, `SettingsContainerSwitch`, `TextFont` (already imported in the email page), `TextInput` (from `package:budget/widgets/textInput.dart`).
- Produces: settings keys `"aiCategorizationEnabled"` (bool) and `"geminiApiKey"` (String), readable via `appStateSettings[...]`.

- [ ] **Step 1: Add default preferences**

In `lib/struct/defaultPreferences.dart`, after the `"autoAddAssociatedTitles": true,` line (`:126`), add:

```dart
    "aiCategorizationEnabled": false,
    "geminiApiKey": "",
```

- [ ] **Step 2: Ensure the TextInput import is present**

In `lib/pages/autoTransactionsPageEmail.dart`, confirm the imports include `package:budget/widgets/textInput.dart`. If not, add:

```dart
import 'package:budget/widgets/textInput.dart';
```

- [ ] **Step 3: Add the settings UI to the email page**

In `lib/pages/autoTransactionsPageEmail.dart`, inside the `listWidgets:` list in the `AutoTransactionsPageEmail` state `build` (`:337`), add the following entries just after the `IgnorePointer(...GmailApiScreen()...)` entry that currently ends around `:386`, before the list's closing `]`:

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

- [ ] **Step 4: Verify it compiles**

Run: `flutter analyze lib/pages/autoTransactionsPageEmail.dart lib/struct/defaultPreferences.dart`
Expected: No errors. (If `TextInput`'s named-parameter set differs from the call above — e.g. `onChanged` signature — adjust to match `lib/widgets/textInput.dart`. Its constructor supports `labelText`, `initialValue`, `obscureText`, `icon`, `onChanged`.)

- [ ] **Step 5: Commit**

```bash
git add lib/struct/defaultPreferences.dart lib/pages/autoTransactionsPageEmail.dart
git commit -m "feat: add AI categorization settings (toggle, API key, privacy note)"
```

---

## Task 3: Integration — call Gemini on cache miss at both resolve sites

Add a small wrapper that reads settings, gathers the user's categories, calls the service, and resolves the chosen id to a category. Then wire it into the two places the email flow resolves a category, on the cache-miss branch only — so with the feature off, behavior is byte-for-byte identical to today.

**Files:**
- Modify: `lib/pages/autoTransactionsPageEmail.dart`
  - new wrapper `aiCategorizeEmailMerchant` (top-level, e.g. just above `parseEmailsInBackground` at `:392`)
  - call site A: `queueTransactionFromMessage` (`:122–130`)
  - call site B: `parseEmailsInBackground` (`:532–537`)

**Interfaces:**
- Consumes: `aiCategorizeMerchant` + `AiCategoryChoice` (Task 1); settings keys (Task 2); existing `database.getAllCategories()` and `database.getCategoryInstanceOrNull(String)`.
- Produces: `Future<TransactionCategory?> aiCategorizeEmailMerchant(String rawTitle)` — returns a category or null (null = feature off / no key / no answer / error). Never throws.

- [ ] **Step 1: Add imports**

In `lib/pages/autoTransactionsPageEmail.dart` imports, add (confirm not already present):

```dart
import 'package:budget/struct/aiCategorization.dart';
```

- [ ] **Step 2: Add the wrapper function**

In `lib/pages/autoTransactionsPageEmail.dart`, add this top-level function just above `parseEmailsInBackground` (`:392`):

```dart
// Bridges the email flow to the Gemini service: reads settings, gathers the
// user's categories, asks for a classification, and resolves the chosen id to a
// category. Returns null when the feature is off, unconfigured, or unsuccessful.
// Never throws.
Future<TransactionCategory?> aiCategorizeEmailMerchant(String rawTitle) async {
  final bool enabled = appStateSettings["aiCategorizationEnabled"] == true;
  final String apiKey = appStateSettings["geminiApiKey"] ?? "";
  if (!enabled || apiKey.trim().isEmpty || rawTitle.trim().isEmpty) return null;
  try {
    final List<TransactionCategory> categories =
        await database.getAllCategories();
    final choices = categories
        .map((c) => AiCategoryChoice(c.categoryPk, c.name))
        .toList();
    final String? chosenId = await aiCategorizeMerchant(
      merchant: rawTitle,
      categories: choices,
      apiKey: apiKey,
    );
    if (chosenId == null) return null;
    return await database.getCategoryInstanceOrNull(chosenId);
  } catch (e) {
    print("aiCategorizeEmailMerchant: error: $e");
    return null;
  }
}
```

- [ ] **Step 3: Wire call site A (`queueTransactionFromMessage`)**

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
  TransactionAssociatedTitleWithCategory? foundTitle =
      (await database.getSimilarAssociatedTitles(title: title, limit: 1))
          .firstOrNull;
  TransactionCategory? category = foundTitle?.category;
  if (category == null) {
    category = await aiCategorizeEmailMerchant(title);
  }
  if (category == null) {
    category = await database
        .getCategoryInstanceOrNull(templateFound.defaultCategoryFk);
  }
```

- [ ] **Step 4: Wire call site B (`parseEmailsInBackground`)**

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
        TransactionAssociatedTitleWithCategory? foundTitle =
            (await database.getSimilarAssociatedTitles(title: title, limit: 1))
                .firstOrNull;

        TransactionCategory? selectedCategory = foundTitle?.category;
        if (selectedCategory == null) {
          selectedCategory = await aiCategorizeEmailMerchant(title);
        }
        if (selectedCategory == null) continue;
```

The existing lines that immediately follow (`title = filterEmailTitle(title);` then `await addAssociatedTitles(title, selectedCategory);`) are unchanged — `addAssociatedTitles` caches whatever category was resolved, including the AI result, so the next scan of the same merchant is a cache hit and Gemini is not called again.

- [ ] **Step 5: Verify it compiles**

Run: `flutter analyze lib/pages/autoTransactionsPageEmail.dart`
Expected: No errors.

- [ ] **Step 6: Run the full test suite**

Run: `flutter test`
Expected: PASS (the Gemini service tests from Task 1; no regressions).

- [ ] **Step 7: Commit**

```bash
git add lib/pages/autoTransactionsPageEmail.dart
git commit -m "feat: categorize first-seen email merchants via Gemini on cache miss"
```

---

## Notes / decisions resolved here

- **Gemini model ID:** default `gemini-2.0-flash` (current free-tier Flash), configurable via the `model` parameter.
- **`responseSchema` shape:** an object with a single `categoryId` string constrained by `enum` to the user's existing category ids (Task 1).
- **No normalization, no `source` column, no DB migration** — see the spec's "Scope revision" note. Cache read = existing `getSimilarAssociatedTitles`; cache write = existing `addAssociatedTitles`; user-lock is automatic (Gemini only runs on a true miss).
- **Behavior with the feature off** is identical to today at both sites (site A: template default; site B: skip). Gemini only changes the miss branch.
- **Phase 0 (Google Sign-In on macOS)** from the spec is a separate prerequisite for *running* the scan on macOS and is out of scope for this plan — the categorization code is platform-neutral and testable without it.

## Self-Review

- **Spec coverage (post-revision):** Gemini service (spec Section 3) → Task 1; settings surface (Section 5) → Task 2; integration at the cache-miss point (Section 4) → Task 3; error-handling/safety (spec + Global Constraints) → Task 1 failure tests + the never-throw wrapper in Task 3. Dropped elements (Sections 1–2: normalization, `source`) are intentionally absent per the scope revision.
- **Placeholder scan:** none — every code/step is concrete. The only conditional notes are import/parameter-name verifications, which are guardrails, not deferred work.
- **Type consistency:** `AiCategoryChoice`, `aiCategorizeMerchant({merchant, categories, apiKey, model, client})`, and `aiCategorizeEmailMerchant(String) -> Future<TransactionCategory?>` are referenced identically across tasks.
- **Constraint check:** no task writes to or deletes `AssociatedTitles` directly; caching flows only through the pre-existing `addAssociatedTitles` call, preserving the automatic user-lock.
