# macOS Global Keyboard Shortcuts — Design

**Date:** 2026-07-03
**Status:** Approved for planning
**App:** Cashew (`budget/`, Flutter)
**Branch:** `macos-google-signin` (continuing macOS work)

## Summary

Cashew has a small keyboard-shortcut foundation (`lib/struct/keyboardIntents.dart`,
wired app-wide in `main.dart:118-119` via `shortcuts:` + `actions:`): **Escape**
(back/home) and **Ctrl+1–4** (switch main tabs, only at root). On macOS the Ctrl
modifier is wrong muscle-memory (⌘ is expected), and there are no shortcuts for
the most common actions.

This adds a set of **global, platform-aware shortcuts** (⌘ on macOS, Ctrl
elsewhere) for the highest-value actions, extending the existing intents/actions
maps. This is effort **(A)** of a two-part idea; focus/arrow **traversal (B)** is a
separate, later spec.

## Goals

- macOS-native modifiers: ⌘ on macOS, Ctrl on Windows/Linux/web.
- Shortcuts for: new transaction, switch tabs, search, settings, refresh/sync,
  and close/back.
- Reuse the existing `Shortcuts`/`Actions`/`Intent` plumbing; no `main.dart`
  change.

## Non-Goals

- Focus/arrow-key traversal through lists and forms (effort **B**, separate spec).
- A shortcut cheat-sheet / help overlay.
- A native macOS menu bar with menu items.
- Rebindable/customizable shortcuts.

## Decisions (resolved during brainstorming)

| Decision | Choice |
|---|---|
| Modifier | Platform-aware: ⌘ (`meta`) on macOS, Ctrl (`control`) elsewhere, via `SingleActivator`. |
| Shortcut set | ⌘N new txn, ⌘1–4 tabs, Esc back, ⌘F search, ⌘, settings, ⌘R refresh/sync. |
| ⌘N double-open | Guarded: only opens when no `AddTransactionPage` is currently mounted. |
| Scope of tabs | ⌘1–4 keep the existing "only at root" guard; the other new shortcuts fire from any screen. |
| Location | All in `keyboardIntents.dart` (+ a small lifecycle counter in `addTransactionPage.dart`); `main.dart` unchanged. |

## Architecture

### Section 1 — Platform-aware shortcut map

Replace the current `LogicalKeySet(control, …)` entries with `SingleActivator`s
whose modifier is chosen by platform, and add the new ones. Extract the map
construction into a pure function so it is unit-testable:

```dart
Map<ShortcutActivator, Intent> buildShortcuts({required bool isMacOS});
```

- `isMacOS` is derived at the call site from `getPlatform() == PlatformOS.isMacOS`.
- Each entry uses `SingleActivator(key, meta: isMacOS, control: !isMacOS)`.
- Exposed as the existing top-level `shortcuts` value
  (`shortcuts = buildShortcuts(isMacOS: getPlatform() == PlatformOS.isMacOS)`),
  so `main.dart:118` keeps consuming `shortcuts` unchanged.

### Section 2 — Intents & actions

Keep `EscapeIntent`, `Digit1Intent`…`Digit4Intent` and their existing callbacks.
Add four intents + `CallbackAction`s in the `keyboardIntents` map:

| Shortcut | Intent | Action (callback) |
|---|---|---|
| mod+N | `NewTransactionIntent` | if `openAddTransactionPages == 0`: `pushRoute(navigatorKey.currentContext!, AddTransactionPage())` |
| mod+1–4 | `Digit1–4Intent` | existing `changePage(n, switchNavbar: true)` at root |
| Esc | `EscapeIntent` | existing pop / return to home tab |
| mod+F | `SearchTransactionsIntent` | `pushRoute(navigatorKey.currentContext!, TransactionsSearchPage())` |
| mod+, | `OpenSettingsIntent` | `pageNavigationFrameworkKey.currentState?.changePage(3, switchNavbar: true)` |
| mod+R | `RefreshSyncIntent` | `runAllCloudFunctions(navigatorKey.currentContext!)` |

Key mappings: N=`keyN`, F=`keyF`, R=`keyR`, comma=`comma`, digits=`digit1`…`digit4`.

Both `AddTransactionPage()` and `TransactionsSearchPage()` have no required
constructor args (verified). `runAllCloudFunctions` and `changePage` are existing
functions already used elsewhere.

### Section 3 — ⌘N double-open guard

In `lib/pages/addTransactionPage.dart`, add a top-level counter:

```dart
int openAddTransactionPages = 0;
```

Increment it in the `AddTransactionPage` `State.initState` and decrement in
`dispose`. `NewTransactionIntent`'s action checks `openAddTransactionPages == 0`
before pushing, so ⌘N never stacks a second add/edit-transaction page on top of
an open one.

## Behavior & edge cases

- Modifier-based shortcuts do not interfere with typing in text fields (they
  don't insert characters), so no focus guard is needed. Esc keeps its current
  behavior.
- ⌘1–4 remain root-only (existing `!navigatorKey.currentState!.canPop()` guard);
  ⌘N/F/,/R fire from any screen.
- ⌘R triggers the full cloud sync (which includes the email scan) — same path as
  the manual refresh.

## Testing

- Unit-test the pure `buildShortcuts({required bool isMacOS})`:
  - macOS → representative activators (e.g. N, F, digit1) are `SingleActivator`
    with `meta == true` and `control == false`.
  - non-macOS → `control == true`, `meta == false`.
  - the full expected key set is present (N, 1–4, F, comma, R) plus Escape.
- The action callbacks (navigation, sync) require the live navigator and are
  verified manually on macOS (open new txn, search, settings, refresh, tab
  switching, and the ⌘N double-open guard).

## Open items for the plan

- Whether `iOS` (external keyboards) should also use `meta` — default: `meta`
  only on macOS; iOS/others use `control` (revisit if desired).
- Exact `SingleActivator` for the comma key on non-US layouts (use
  `LogicalKeyboardKey.comma`; acceptable if some layouts differ).
