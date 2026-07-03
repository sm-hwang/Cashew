# macOS Global Keyboard Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add platform-aware global keyboard shortcuts (⌘ on macOS, Ctrl elsewhere) for new transaction, tabs, search, settings, refresh/sync, and back — extending the existing shortcut plumbing.

**Architecture:** Convert the existing top-level `shortcuts` map into a pure `buildShortcuts({required bool isMacOS})` (unit-tested), add four new `Intent`s + `CallbackAction`s in `keyboardIntents.dart`, and guard ⌘N against double-open via a lifecycle counter in `addTransactionPage.dart`. `main.dart` already wires `shortcuts`/`keyboardIntents` app-wide — unchanged.

**Tech Stack:** Flutter (`Shortcuts`/`Actions`/`Intent`, `SingleActivator`), FVM Flutter 3.22.3.

## Global Constraints

- **Build/test only with FVM**: `fvm flutter ...` (project pinned to 3.22.3). Never bare `flutter`.
- Modifiers are platform-aware: `SingleActivator(key, meta: isMacOS, control: !isMacOS)`; `isMacOS = getPlatform() == PlatformOS.isMacOS`.
- Shortcut set: mod+N new txn (guarded), mod+1–4 tabs (root-only, existing), Esc back (existing), mod+F search, mod+, settings, mod+R refresh/sync.
- ⌘N only opens when `openAddTransactionPages == 0`.
- All changes in `lib/struct/keyboardIntents.dart` + a counter in `lib/pages/addTransactionPage.dart`; `main.dart` unchanged.
- Escape stays a bare `SingleActivator(LogicalKeyboardKey.escape)` (no modifier), both platforms.
- All paths relative to `budget/`. Run commands from `budget/`.

---

## File Structure

- **Modify** `lib/struct/keyboardIntents.dart` — `buildShortcuts` pure fn, new Intents, new actions, imports.
- **Create** `test/keyboard_shortcuts_test.dart` — unit tests for `buildShortcuts`.
- **Modify** `lib/pages/addTransactionPage.dart` — `openAddTransactionPages` counter + initState/dispose.

Current `keyboardIntents.dart` layout: imports (1–4), `keyboardIntents` actions map (~6–49), `shortcuts` map (~51–60), Intent classes `EscapeIntent`/`Digit1–4Intent` (~62–80).

---

## Task 1: Platform-aware `buildShortcuts` + new Intents (pure, unit-tested)

Define the new intents and the pure shortcut-map builder, and rewire the top-level `shortcuts`. No action callbacks yet — a shortcut with no matching action is simply inert, so this is safe to ship alone.

**Files:**
- Modify: `lib/struct/keyboardIntents.dart`
- Test: `test/keyboard_shortcuts_test.dart`

**Interfaces:**
- Produces: `Map<ShortcutActivator, Intent> buildShortcuts({required bool isMacOS})`; new `Intent` classes `NewTransactionIntent`, `SearchTransactionsIntent`, `OpenSettingsIntent`, `RefreshSyncIntent`; top-level `shortcuts` now `= buildShortcuts(isMacOS: getPlatform() == PlatformOS.isMacOS)`.
- Consumes: existing `EscapeIntent`, `Digit1Intent`…`Digit4Intent`; `getPlatform`/`PlatformOS` from `package:budget/functions.dart`.

- [ ] **Step 1: Write the failing test**

Create `test/keyboard_shortcuts_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/keyboardIntents.dart';

void main() {
  test('macOS uses Cmd (meta) modifiers', () {
    final s = buildShortcuts(isMacOS: true);
    expect(s[const SingleActivator(LogicalKeyboardKey.keyN, meta: true)],
        isA<NewTransactionIntent>());
    expect(s[const SingleActivator(LogicalKeyboardKey.keyF, meta: true)],
        isA<SearchTransactionsIntent>());
    expect(s[const SingleActivator(LogicalKeyboardKey.comma, meta: true)],
        isA<OpenSettingsIntent>());
    expect(s[const SingleActivator(LogicalKeyboardKey.keyR, meta: true)],
        isA<RefreshSyncIntent>());
    expect(s[const SingleActivator(LogicalKeyboardKey.digit1, meta: true)],
        isA<Digit1Intent>());
    expect(
        s.containsKey(
            const SingleActivator(LogicalKeyboardKey.keyN, control: true)),
        isFalse);
  });

  test('non-macOS uses Ctrl (control) modifiers', () {
    final s = buildShortcuts(isMacOS: false);
    expect(s[const SingleActivator(LogicalKeyboardKey.keyN, control: true)],
        isA<NewTransactionIntent>());
    expect(s[const SingleActivator(LogicalKeyboardKey.digit1, control: true)],
        isA<Digit1Intent>());
    expect(
        s.containsKey(
            const SingleActivator(LogicalKeyboardKey.keyN, meta: true)),
        isFalse);
  });

  test('Escape present and modifier-independent on both platforms', () {
    expect(
        buildShortcuts(isMacOS: true)[
            const SingleActivator(LogicalKeyboardKey.escape)],
        isA<EscapeIntent>());
    expect(
        buildShortcuts(isMacOS: false)[
            const SingleActivator(LogicalKeyboardKey.escape)],
        isA<EscapeIntent>());
  });

  test('full expected key set present', () {
    final s = buildShortcuts(isMacOS: true);
    // escape + 4 digits + N + F + comma + R
    expect(s.length, 9);
    expect(s.values.whereType<Digit4Intent>().length, 1);
    expect(s.values.whereType<RefreshSyncIntent>().length, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `fvm flutter test test/keyboard_shortcuts_test.dart`
Expected: FAIL — `buildShortcuts` / the new intent classes are undefined.

- [ ] **Step 3: Add the import**

In `lib/struct/keyboardIntents.dart`, add to the imports (after line 4):

```dart
import 'package:budget/functions.dart';
```

- [ ] **Step 4: Replace the `shortcuts` map with `buildShortcuts` + top-level `shortcuts`**

Replace the entire existing `Map<ShortcutActivator, Intent> shortcuts = { ... };` block (the one starting `Map<ShortcutActivator, Intent> shortcuts =`) with:

```dart
Map<ShortcutActivator, Intent> buildShortcuts({required bool isMacOS}) {
  SingleActivator mod(LogicalKeyboardKey key) =>
      SingleActivator(key, meta: isMacOS, control: !isMacOS);
  return {
    const SingleActivator(LogicalKeyboardKey.escape): const EscapeIntent(),
    mod(LogicalKeyboardKey.digit1): const Digit1Intent(),
    mod(LogicalKeyboardKey.digit2): const Digit2Intent(),
    mod(LogicalKeyboardKey.digit3): const Digit3Intent(),
    mod(LogicalKeyboardKey.digit4): const Digit4Intent(),
    mod(LogicalKeyboardKey.keyN): const NewTransactionIntent(),
    mod(LogicalKeyboardKey.keyF): const SearchTransactionsIntent(),
    mod(LogicalKeyboardKey.comma): const OpenSettingsIntent(),
    mod(LogicalKeyboardKey.keyR): const RefreshSyncIntent(),
  };
}

Map<ShortcutActivator, Intent> shortcuts =
    buildShortcuts(isMacOS: getPlatform() == PlatformOS.isMacOS);
```

- [ ] **Step 5: Add the new Intent classes**

At the end of `lib/struct/keyboardIntents.dart` (after the existing `Digit4Intent` class), add:

```dart
class NewTransactionIntent extends Intent {
  const NewTransactionIntent();
}

class SearchTransactionsIntent extends Intent {
  const SearchTransactionsIntent();
}

class OpenSettingsIntent extends Intent {
  const OpenSettingsIntent();
}

class RefreshSyncIntent extends Intent {
  const RefreshSyncIntent();
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `fvm flutter test test/keyboard_shortcuts_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/struct/keyboardIntents.dart test/keyboard_shortcuts_test.dart
git commit -m "feat: platform-aware keyboard shortcut map (meta on macOS)"
```

---

## Task 2: Actions + ⌘N double-open guard

Wire the four new intents to real actions, and add the guard counter. These are navigation side effects (need the live navigator), so acceptance is `fvm flutter analyze` clean + the full suite green + manual verification.

**Files:**
- Modify: `lib/struct/keyboardIntents.dart` (imports + the `keyboardIntents` actions map)
- Modify: `lib/pages/addTransactionPage.dart` (counter + initState/dispose)

**Interfaces:**
- Consumes: Task 1's intents; `pushRoute` (`functions.dart`), `AddTransactionPage` + `openAddTransactionPages` (`addTransactionPage.dart`), `TransactionsSearchPage` (`transactionsSearchPage.dart`), `navigatorKey` (`main.dart`, already imported), `pageNavigationFrameworkKey` + `runAllCloudFunctions` (`navigationFramework.dart`, already imported).

- [ ] **Step 1: Add the counter to addTransactionPage.dart**

In `lib/pages/addTransactionPage.dart`, add a top-level variable (e.g. immediately above `class AddTransactionPage`):

```dart
// Number of AddTransactionPage instances currently mounted. Used to guard the
// ⌘/Ctrl+N shortcut from stacking a second add/edit-transaction page.
int openAddTransactionPages = 0;
```

- [ ] **Step 2: Increment/decrement in the page lifecycle**

In `_AddTransactionPageState.initState` (the `void initState()` at ~`:727`), add immediately after `super.initState();`:

```dart
    openAddTransactionPages++;
```

Then add a `dispose` override to `_AddTransactionPageState` (it has none). Insert it just above the `@override` that precedes `void initState()` (~`:726`):

```dart
  @override
  void dispose() {
    openAddTransactionPages--;
    super.dispose();
  }

```

- [ ] **Step 3: Add imports to keyboardIntents.dart**

In `lib/struct/keyboardIntents.dart`, add (if not already present):

```dart
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/transactionsSearchPage.dart';
```

(`package:budget/functions.dart` was added in Task 1; `navigatorKey` comes from the existing `main.dart` import; `pageNavigationFrameworkKey`/`runAllCloudFunctions` from the existing `navigationFramework.dart` import.)

- [ ] **Step 4: Add the four action callbacks**

In the `keyboardIntents` actions map in `lib/struct/keyboardIntents.dart`, add these entries (e.g. after the existing `Digit4Intent` entry, before the map's closing `};`):

```dart
  NewTransactionIntent: CallbackAction<NewTransactionIntent>(
    onInvoke: (NewTransactionIntent intent) {
      if (openAddTransactionPages == 0) {
        pushRoute(navigatorKey.currentContext, AddTransactionPage());
      }
      return null;
    },
  ),
  SearchTransactionsIntent: CallbackAction<SearchTransactionsIntent>(
    onInvoke: (SearchTransactionsIntent intent) {
      pushRoute(navigatorKey.currentContext, TransactionsSearchPage());
      return null;
    },
  ),
  OpenSettingsIntent: CallbackAction<OpenSettingsIntent>(
    onInvoke: (OpenSettingsIntent intent) {
      pageNavigationFrameworkKey.currentState?.changePage(3, switchNavbar: true);
      return null;
    },
  ),
  RefreshSyncIntent: CallbackAction<RefreshSyncIntent>(
    onInvoke: (RefreshSyncIntent intent) {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) runAllCloudFunctions(ctx);
      return null;
    },
  ),
```

- [ ] **Step 5: Verify it analyzes clean**

Run: `fvm flutter analyze lib/struct/keyboardIntents.dart lib/pages/addTransactionPage.dart`
Expected: No errors. (Pre-existing info-level deprecations elsewhere in `addTransactionPage.dart` are acceptable; the edited regions must add none.)

- [ ] **Step 6: Run the full suite**

Run: `fvm flutter test`
Expected: PASS — Task 1's `keyboard_shortcuts_test.dart` and all prior tests; the only acceptable failure is the pre-existing `widget_test.dart` counter stub (predates this work).

- [ ] **Step 7: Commit**

```bash
git add lib/struct/keyboardIntents.dart lib/pages/addTransactionPage.dart
git commit -m "feat: wire keyboard shortcut actions + guard cmd+N double-open"
```

## Manual verification (macOS)

- [ ] **⌘N** opens a new transaction; pressing **⌘N again** while it's open does nothing (no stacked page). Closing it, then ⌘N, opens one again.
- [ ] **⌘1–4** switch the main tabs from the home root.
- [ ] **Esc** closes an open page / returns toward home.
- [ ] **⌘F** opens the transactions search page.
- [ ] **⌘,** switches to the More/Settings tab.
- [ ] **⌘R** triggers a sync/refresh (watch for the scan/loading indicator).
- [ ] Typing letters (incl. n/f/r) in a text field inserts them normally (shortcuts only fire with ⌘).

## Notes / decisions resolved here

- `main.dart` unchanged: it already reads top-level `shortcuts` + `keyboardIntents`.
- ⌘N guard uses a mount counter, so it also won't stack on top of an open *edit* transaction (intended).
- Escape and ⌘1–4 keep existing behavior (root-only tab switching guard lives in their existing callbacks, untouched).

## Self-Review

- **Spec coverage:** Section 1 (platform-aware `buildShortcuts`) → Task 1 Steps 4/6 + test; Section 2 (intents + actions table) → Task 1 Step 5 + Task 2 Step 4; Section 3 (⌘N guard counter) → Task 2 Steps 1–2 + the `openAddTransactionPages == 0` check in Step 4; Testing (pure `buildShortcuts` unit test + manual callbacks) → Task 1 test + Manual verification; Non-goals (traversal, overlay, menu bar) untouched.
- **Placeholder scan:** none — full code in every code step; only conditional note is "add import if not already present."
- **Type/name consistency:** `buildShortcuts({required bool isMacOS})`, the four intent class names, `openAddTransactionPages`, and the action entries all use identical names across Tasks 1–2 and the test.
