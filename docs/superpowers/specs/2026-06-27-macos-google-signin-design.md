# macOS Google Sign-In (Phase 0) — Design

**Date:** 2026-06-27
**Status:** Approved for planning
**App:** Cashew (`budget/`, Flutter)
**Branch:** `macos-google-signin`

## Summary

Google Sign-In does not work on the macOS build, so the email scan, Gmail API,
Drive, and the new AI categorization feature cannot run there. This is the
"Phase 0" prerequisite called out in the AI-email-categorization design.

The macOS desktop support already merged wraps Firebase init in a try/catch so
startup doesn't crash (`main.dart:50`), but three things are still missing for
sign-in to actually work on macOS:

1. macOS has no OAuth client ID wired in — the sign-in code falls into the
   `GoogleSignIn.standard()` branch (no client ID) and fails.
2. `macos/Runner/Info.plist` has no OAuth redirect URL scheme.
3. The macOS app sandbox lacks the `com.apple.security.network.client`
   entitlement, which blocks **all** outbound traffic (sign-in, Gmail, Drive,
   Gemini).

This design fills exactly those gaps. It is platform-isolated: no behavior on
Android, iOS, or web changes.

## Goals

- Google Sign-In completes on macOS with the Gmail scopes, so the email scan
  (and therefore AI categorization) runs on macOS.
- No regression to sign-in on Android, iOS, or web.
- Fail safe: a missing/misconfigured client ID degrades to the existing
  sign-in error snackbar, never a crash (consistent with the macOS
  "never crash startup" approach).

## Non-Goals

- Firebase cloud sync on macOS (still unconfigured; the app runs without it).
- Drive backup enablement on macOS (the same OAuth client could cover Drive
  scopes later, but it is not a goal here).
- Code signing, notarization, or distribution.
- File-based data migration — **already supported** via the existing
  "Export Data File" / "Import" in Settings (`settingsPage.dart:617–619`,
  `exportDB.dart`). On macOS it writes the full `.sql` DB dump into the app's
  sandbox container (`~/Library/Containers/com.budget.budget/Data/Documents/`);
  this works today and is out of scope. A future "native Save As dialog"
  polish for that export was deferred by the user.

## Decisions (resolved during brainstorming)

| Decision | Choice |
|---|---|
| OAuth client | **New** iOS-type OAuth client registered to the macOS bundle id `com.budget.budget` (the iOS client is bound to `com.budget.tracker-app` and cannot be reused) |
| Client ID storage | Injected at build time, **never committed**. Dart reads `String.fromEnvironment('GOOGLE_MACOS_CLIENT_ID')` (via `--dart-define`); the macOS `Info.plist` redirect scheme reads `$(GOOGLE_REVERSED_CLIENT_ID)` from a **git-ignored** `macos/Runner/Configs/Secrets.xcconfig`. |
| Secret handling | **Keep the client ID out of the git repo** (user requirement). Two git-ignored inputs (a `--dart-define` value and `Secrets.xcconfig`), each with a committed `.example` template. The code compiles without them (empty string) and macOS sign-in fails gracefully until they are supplied. NB: this plugin version (`google_sign_in_ios 5.9.0`) does **not** read `GIDClientID` from `Info.plist` — it requires the client ID passed from Dart — so Dart must inject it; a single shared file is not possible. |
| Export-for-migration polish | Out of scope; revisit later |

## Prerequisite — your Google Cloud Console work (project `267621253497`)

These steps cannot be done in code; they produce the client ID the
implementation needs:

- Create a new **OAuth client of type iOS** registered to bundle id
  **`com.budget.budget`**.
- Confirm the OAuth consent screen lists the Gmail readonly + modify scopes
  (it should already, since Gmail works on Android/iOS) and add your Google
  account as a **test user** if the app is in "testing".
- This yields a **client ID** (`267621253497-XXXX.apps.googleusercontent.com`)
  and its **reversed client ID** (`com.googleusercontent.apps.267621253497-XXXX`).

The implementer will need the actual client ID value to wire in; until it is
provided, the code change can be staged with the constant left empty (sign-in
on macOS then fails gracefully via the existing error path).

## Architecture

The change set is four edits across config and one Dart file. No new modules.

### Section 1 — Client ID constant (build-time, not committed)

`firebase_options.dart` already holds the iOS client ID as a literal and
throws `UnsupportedError` for macOS in `currentPlatform`. Add a sibling
constant for macOS that is read directly (bypassing `currentPlatform`) and
sourced from a compile-time environment value so the real id is **never
committed**:

```dart
// macOS uses its own OAuth client (bundle com.budget.budget). Injected at
// build time via --dart-define so the value is not committed. Read directly —
// currentPlatform throws on macOS and cannot carry this.
static const String macosClientId =
    String.fromEnvironment('GOOGLE_MACOS_CLIENT_ID');
```

Supplied at run/build time, e.g.
`flutter run -d macos --dart-define=GOOGLE_MACOS_CLIENT_ID=<id>` or via a
git-ignored `--dart-define-from-file` JSON. When absent it is the empty
string and macOS sign-in fails gracefully.

### Section 2 — Sign-in branch

`accountAndBackup.dart:132` currently is:

```dart
googleSignIn = getPlatform() == PlatformOS.isIOS
    ? signIn.GoogleSignIn(
        clientId: DefaultFirebaseOptions.currentPlatform.iosClientId,
        scopes: scopes)
    : signIn.GoogleSignIn.standard(scopes: scopes);
```

Add a macOS arm so macOS passes its own client ID instead of falling into
`standard()`:

```dart
googleSignIn = getPlatform() == PlatformOS.isIOS
    ? signIn.GoogleSignIn(
        clientId: DefaultFirebaseOptions.currentPlatform.iosClientId,
        scopes: scopes)
    : getPlatform() == PlatformOS.isMacOS
        ? signIn.GoogleSignIn(
            clientId: DefaultFirebaseOptions.macosClientId, scopes: scopes)
        : signIn.GoogleSignIn.standard(scopes: scopes);
```

The existing scope list (userinfo, drive appdata, and the Gmail scopes when
`gMailPermissions == true`) is unchanged. The existing try/catch around the
whole function already handles failure with the standard error snackbar.

### Section 3 — Info.plist URL scheme (build variable, not committed)

`macos/Runner/Info.plist` gains a `CFBundleURLTypes` entry registering the
reversed client ID as a URL scheme (the OAuth redirect target). The committed
plist references a **build variable** so the real value stays out of git:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>$(GOOGLE_REVERSED_CLIENT_ID)</string>
    </array>
  </dict>
</array>
```

`GOOGLE_REVERSED_CLIENT_ID` is defined in a **git-ignored**
`macos/Runner/Configs/Secrets.xcconfig`, optionally `#include?`'d from the
existing `Debug.xcconfig` and `Release.xcconfig`. A committed
`Secrets.xcconfig.example` documents the format
(`com.googleusercontent.apps.267621253497-XXXX`). The real file is added to
`.gitignore`.

### Section 4 — Sandbox entitlements

Add `com.apple.security.network.client` to **both**
`macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements` (Release currently has only
`app-sandbox`). Without it the sandbox blocks every outbound connection —
sign-in, Gmail, Drive, and Gemini. The existing `network.server` (debug) and
`app-sandbox` keys are kept.

## Error handling & safety

- Platform-isolated: only the macOS arm and macOS Runner config are touched;
  iOS/Android/web sign-in paths are untouched.
- A missing/empty `macosClientId` or misconfigured client surfaces as the
  existing `sign-in-error` snackbar via the current try/catch — never a crash.
- No secrets introduced (client ID and reversed client ID are public values
  embedded in the shipped app).

## Testing

OAuth and platform entitlements cannot be unit-tested. Verification is manual,
on a Mac:

1. Build and run the macOS app.
2. In Auto Transactions, toggle **Read Emails** → Google Sign-In completes and
   the consent screen shows the Gmail scopes.
3. `testIfHasGmailAccess()` returns true (the app proceeds without forcing a
   re-sign-in).
4. Trigger an email scan → a transaction is created from a matching email.
5. With a Gemini key set and AI categorization on, a first-seen merchant gets
   an AI-assigned category (confirming outbound network works under the new
   entitlement).

Regression check: sign-in still works on at least one of Android/iOS/web
(unchanged code path, but confirm the added ternary arm didn't disturb it).

## Open items for the plan

- The actual macOS client ID + reversed client ID values (provided by the user
  from GCP). These go **only** into the git-ignored `--dart-define` input and
  `Secrets.xcconfig` — never into a committed file.
- Exact `.gitignore` entries and the `#include?` wiring for `Secrets.xcconfig`.
