# macOS Google Sign-In (Phase 0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Google Sign-In (with Gmail scopes) work on the sandboxed macOS build so the email scan and AI categorization run there.

**Architecture:** Platform-isolated. Add a macOS OAuth client ID constant read directly (never via `DefaultFirebaseOptions.currentPlatform`, which throws on macOS), branch the existing `signInGoogle` to use it on macOS, and give the macOS Runner the OAuth redirect URL scheme plus the outbound-network sandbox entitlement. No Android/iOS/web behavior changes.

**Tech Stack:** Flutter / Dart, `google_sign_in ^6.2.1` (endorsed `google_sign_in_macos`), macOS app sandbox (entitlements), Xcode `Info.plist`.

## Global Constraints

- **Provided at implementation time by the user** (from Google Cloud Console, project `267621253497`): a new **iOS-type OAuth client** registered to macOS bundle id `com.budget.budget`, yielding two literal values the implementer substitutes:
  - `MACOS_CLIENT_ID` — form `267621253497-XXXX.apps.googleusercontent.com`
  - `REVERSED_CLIENT_ID` — form `com.googleusercontent.apps.267621253497-XXXX` (the `MACOS_CLIENT_ID` with the two dot-separated halves swapped, minus the `.apps.googleusercontent.com` suffix appended to the front-reversed form). If the user supplies it explicitly, use that; otherwise derive it from `MACOS_CLIENT_ID`.
- These values are **not secrets** (they ship inside the app binary / Info.plist) and are committed to the repo.
- If `MACOS_CLIENT_ID` is not yet available, the code still compiles with an empty string and macOS sign-in fails gracefully via the existing error snackbar — but the feature is not "done" until the real value is in and manual verification (final section) passes.
- macOS bundle id is `com.budget.budget`; iOS is `com.budget.tracker-app` — they differ, which is why a dedicated macOS client is required.
- Platform isolation: do not change the iOS/Android/web sign-in code paths.
- `DefaultFirebaseOptions.currentPlatform` throws `UnsupportedError` on macOS — never call it on the macOS path.
- All paths below are relative to `budget/` (the Flutter app root). Run all `flutter` commands from `budget/`.

---

## File Structure

- **Modify** `lib/firebase_options.dart` — add `macosClientId` const (after the `ios` options block, ~`:75`).
- **Modify** `lib/widgets/accountAndBackup.dart` — add the macOS arm to the `GoogleSignIn` platform branch (`:132–136`).
- **Modify** `macos/Runner/Info.plist` — add `CFBundleURLTypes` with the reversed-client-ID scheme.
- **Modify** `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements` — add `com.apple.security.network.client`.

No new files. No unit tests (OAuth, plist, and sandbox entitlements are not unit-testable); acceptance is `flutter analyze` clean, `plutil -lint` clean, and the manual macOS checklist in the final section.

---

## Task 1: Wire the macOS OAuth client ID into sign-in

Add the client-ID constant and the macOS branch so `signInGoogle` constructs a `GoogleSignIn` with the macOS client ID instead of falling into `GoogleSignIn.standard()`.

**Files:**
- Modify: `lib/firebase_options.dart` (after `:75`)
- Modify: `lib/widgets/accountAndBackup.dart` (`:132–136`)

**Interfaces:**
- Produces: `DefaultFirebaseOptions.macosClientId` (`static const String`).
- Consumes: existing `getPlatform()` / `PlatformOS.isMacOS` (from `lib/functions.dart`), `signIn.GoogleSignIn` (the `google_sign_in` import aliased `signIn` already present in `accountAndBackup.dart`).

- [ ] **Step 1: Add the `macosClientId` constant**

In `lib/firebase_options.dart`, immediately after the closing `);` of the `static const FirebaseOptions ios = FirebaseOptions(...)` block (ends at `:75`) and before the class's closing `}`, add:

```dart

  // macOS uses google_sign_in_macos with its own OAuth client registered to
  // bundle com.budget.budget. Read this directly — currentPlatform throws
  // UnsupportedError on macOS, so it cannot carry the macOS client ID.
  static const String macosClientId =
      'MACOS_CLIENT_ID';
```

Replace `MACOS_CLIENT_ID` with the real value the user provides (form `267621253497-XXXX.apps.googleusercontent.com`). If not yet available, leave the empty string `''` and note it in your report — macOS sign-in will then fail gracefully until the value is filled.

- [ ] **Step 2: Add the macOS arm to the sign-in platform branch**

In `lib/widgets/accountAndBackup.dart`, replace the existing branch at `:132–136`:

```dart
      googleSignIn = getPlatform() == PlatformOS.isIOS
          ? signIn.GoogleSignIn(
              clientId: DefaultFirebaseOptions.currentPlatform.iosClientId,
              scopes: scopes)
          : signIn.GoogleSignIn.standard(scopes: scopes);
```

with:

```dart
      googleSignIn = getPlatform() == PlatformOS.isIOS
          ? signIn.GoogleSignIn(
              clientId: DefaultFirebaseOptions.currentPlatform.iosClientId,
              scopes: scopes)
          : getPlatform() == PlatformOS.isMacOS
              ? signIn.GoogleSignIn(
                  clientId: DefaultFirebaseOptions.macosClientId,
                  scopes: scopes)
              : signIn.GoogleSignIn.standard(scopes: scopes);
```

Confirm `firebase_options.dart` is already imported in `accountAndBackup.dart` (the iOS branch already references `DefaultFirebaseOptions`, so it is). Do not change the `scopes` list or any other line.

- [ ] **Step 3: Verify it analyzes clean**

Run: `flutter analyze lib/firebase_options.dart lib/widgets/accountAndBackup.dart`
Expected: No errors. (Pre-existing info-level deprecation warnings elsewhere in `accountAndBackup.dart` are acceptable, but the two edited regions must introduce none.)

- [ ] **Step 4: Verify the package still resolves with the macOS plugin**

Run: `flutter pub get`
Expected: resolves successfully. `google_sign_in_macos` is an endorsed plugin of `google_sign_in ^6.2.1` and is pulled in transitively; no pubspec change is required.

- [ ] **Step 5: Commit**

```bash
git add lib/firebase_options.dart lib/widgets/accountAndBackup.dart
git commit -m "feat: wire macOS OAuth client id into Google sign-in"
```

---

## Task 2: macOS Runner config — URL scheme and network entitlement

Register the OAuth redirect URL scheme and grant the sandbox outbound-network access. Without the entitlement the sandbox blocks all outbound traffic (sign-in, Gmail, Drive, Gemini); without the URL scheme the OAuth redirect cannot return to the app.

**Files:**
- Modify: `macos/Runner/Info.plist`
- Modify: `macos/Runner/DebugProfile.entitlements`
- Modify: `macos/Runner/Release.entitlements`

**Interfaces:**
- Consumes: `REVERSED_CLIENT_ID` (from Global Constraints).
- Produces: nothing consumed by Dart code; this is native app configuration that Task 1's runtime sign-in depends on.

- [ ] **Step 1: Add the URL scheme to Info.plist**

In `macos/Runner/Info.plist`, inside the top-level `<dict>`, add a `CFBundleURLTypes` entry (place it as a sibling of the other top-level keys, e.g. just before the closing `</dict>`):

```xml
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>REVERSED_CLIENT_ID</string>
			</array>
		</dict>
	</array>
```

Replace `REVERSED_CLIENT_ID` with the real reversed client id (form `com.googleusercontent.apps.267621253497-XXXX`). If `MACOS_CLIENT_ID` was left empty in Task 1, leave a clearly-marked empty `<string></string>` and note it — but the manual verification cannot pass until it is filled.

- [ ] **Step 2: Lint the Info.plist**

Run: `plutil -lint macos/Runner/Info.plist`
Expected: `macos/Runner/Info.plist: OK`

- [ ] **Step 3: Add `network.client` to DebugProfile.entitlements**

In `macos/Runner/DebugProfile.entitlements`, inside the `<dict>`, add the key alongside the existing ones (keep `app-sandbox`, `cs.allow-jit`, `network.server`):

```xml
	<key>com.apple.security.network.client</key>
	<true/>
```

Resulting `<dict>` should contain: `com.apple.security.app-sandbox` (true), `com.apple.security.cs.allow-jit` (true), `com.apple.security.network.server` (true), and `com.apple.security.network.client` (true).

- [ ] **Step 4: Add `network.client` to Release.entitlements**

In `macos/Runner/Release.entitlements`, inside the `<dict>`, add (keep the existing `app-sandbox`):

```xml
	<key>com.apple.security.network.client</key>
	<true/>
```

Resulting `<dict>` should contain: `com.apple.security.app-sandbox` (true) and `com.apple.security.network.client` (true).

- [ ] **Step 5: Lint both entitlements files**

Run: `plutil -lint macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements`
Expected: both report `OK`.

- [ ] **Step 6: Commit**

```bash
git add macos/Runner/Info.plist macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements
git commit -m "feat: add macOS OAuth redirect scheme and outbound-network entitlement"
```

---

## Final manual verification (run on a Mac, after the real client ID is in)

This feature cannot be unit-tested — OAuth, the URL scheme, and sandbox entitlements only exercise at runtime on macOS. Perform this checklist once the real `MACOS_CLIENT_ID` / `REVERSED_CLIENT_ID` are committed:

- [ ] `flutter run -d macos` builds and launches.
- [ ] In **Auto Transactions**, toggle **Read Emails** → the Google consent screen appears and lists the Gmail scopes; sign-in completes without error.
- [ ] The app does not immediately bounce you back to a re-sign-in prompt (`testIfHasGmailAccess()` returns true).
- [ ] Trigger a scan (the refresh action) → a transaction is created from a matching bank email (requires at least one configured `ScannerTemplate`).
- [ ] With a Gemini API key set and **AI Categorization** on, a first-seen merchant receives an AI-assigned category — confirming outbound network works under the new entitlement.
- [ ] Regression: sign-in still works on one of Android / iOS / web (the added ternary arm must not disturb the existing paths).

If sign-in fails with a redirect/`canceled` error, re-check that `REVERSED_CLIENT_ID` in `Info.plist` exactly matches the client id and that both entitlements files have `network.client`.

---

## Notes / decisions resolved here

- **`macosClientId` placement:** a `static const String` on `DefaultFirebaseOptions`, read directly — never through `currentPlatform`.
- **No pubspec change:** `google_sign_in_macos` ships transitively with `google_sign_in ^6.2.1`.
- **Out of scope** (per spec): Firebase cloud sync on macOS, Drive backup on macOS, signing/notarization, and the export-to-file "native Save As" polish (file-based migration already works on macOS via the existing Export/Import).

## Self-Review

- **Spec coverage:** Section 1 (client ID constant) → Task 1 Step 1; Section 2 (sign-in branch) → Task 1 Step 2; Section 3 (Info.plist URL scheme) → Task 2 Steps 1–2; Section 4 (network.client on both entitlements) → Task 2 Steps 3–5; Testing section → Final manual verification; error-handling/safety (graceful failure via existing try/catch, platform isolation) → Global Constraints + Task 1's additive branch. GCP prerequisite → Global Constraints (user-provided values).
- **Placeholder scan:** the only placeholders are `MACOS_CLIENT_ID` / `REVERSED_CLIENT_ID`, which are genuinely external user-supplied config values (like an API key), explicitly defined in Global Constraints with their exact form and substitution instructions — not vague "TBD" work. Every code/config edit is shown in full.
- **Type/name consistency:** `DefaultFirebaseOptions.macosClientId` is defined in Task 1 Step 1 and consumed in Task 1 Step 2 under the identical name; `PlatformOS.isMacOS` matches the enum in `lib/functions.dart`; `REVERSED_CLIENT_ID` is used consistently in Task 2.
