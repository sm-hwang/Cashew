# macOS Google Sign-In (Phase 0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Google Sign-In (with Gmail scopes) work on the sandboxed macOS build so the email scan and AI categorization run there — with the OAuth client ID kept out of the git repo.

**Architecture:** Platform-isolated and secret-out-of-repo. The Dart client ID comes from a compile-time `String.fromEnvironment` (`--dart-define`), never via the throwing `currentPlatform`. The macOS `Info.plist` redirect scheme references a build variable supplied by a git-ignored `Secrets.xcconfig`. The sandbox gets the outbound-network entitlement. No Android/iOS/web behavior changes.

**Tech Stack:** Flutter / Dart, `google_sign_in ^6.2.1` (provides `google_sign_in_ios 5.9.0` on macOS), macOS app sandbox (entitlements), Xcode `Info.plist` + `.xcconfig`.

## Global Constraints

- **The real OAuth client ID must NEVER be committed to git** (user requirement). It lives only in git-ignored inputs: a `--dart-define` value and `macos/Runner/Configs/Secrets.xcconfig`. Committed files use placeholders / build variables / `.example` templates only.
- Two values, both supplied by the user from Google Cloud Console (project `267621253497`, a new iOS-type OAuth client registered to bundle `com.budget.budget`):
  - `GOOGLE_MACOS_CLIENT_ID` — form `267621253497-XXXX.apps.googleusercontent.com`
  - `GOOGLE_REVERSED_CLIENT_ID` — form `com.googleusercontent.apps.267621253497-XXXX` (the client id with the `NNN-XXXX` and `apps.googleusercontent.com` halves swapped)
- This plugin version (`google_sign_in_ios 5.9.0`) resolves the client id as `runtimeClientIdentifier ?: GoogleService-Info.plist` and does **not** read `GIDClientID` from `Info.plist` — so Dart must pass the client id; there is no single-file shortcut.
- Code must compile and degrade gracefully when the values are absent: `macosClientId` becomes `''`, and macOS sign-in fails via the existing error snackbar (never a crash).
- `DefaultFirebaseOptions.currentPlatform` throws `UnsupportedError` on macOS — never call it on the macOS path.
- macOS bundle id is `com.budget.budget`; iOS is `com.budget.tracker-app` — they differ, which is why a dedicated macOS client is required.
- Platform isolation: do not change the iOS/Android/web sign-in code paths.
- All paths below are relative to `budget/` (the Flutter app root). Run all `flutter` commands from `budget/`.

---

## File Structure

- **Modify** `lib/firebase_options.dart` — add `macosClientId` const sourced from `String.fromEnvironment` (after the `ios` block, ~`:75`).
- **Modify** `lib/widgets/accountAndBackup.dart` — add the macOS arm to the `GoogleSignIn` platform branch (`:132–136`).
- **Modify** `macos/Runner/Info.plist` — add `CFBundleURLTypes` referencing `$(GOOGLE_REVERSED_CLIENT_ID)`.
- **Modify** `macos/Runner/Configs/Debug.xcconfig` and `Release.xcconfig` — `#include?` the secrets file.
- **Create (committed)** `macos/Runner/Configs/Secrets.xcconfig.example` — template.
- **Create (git-ignored, not committed)** `macos/Runner/Configs/Secrets.xcconfig` — real reversed client id.
- **Modify** `.gitignore` — ignore `Secrets.xcconfig`.
- **Modify** `macos/Runner/DebugProfile.entitlements` and `Release.entitlements` — add `com.apple.security.network.client`.

No unit tests (OAuth, plist, entitlements, and `--dart-define` injection are not unit-testable); acceptance is `flutter analyze` clean, `plutil -lint` clean, a git-tracking check that the real id is absent from committed files, and the manual macOS checklist in the final section.

---

## Task 1: Dart sign-in wiring (client id from --dart-define)

Add the env-sourced client-id constant and the macOS branch so `signInGoogle` constructs `GoogleSignIn` with it instead of falling into `GoogleSignIn.standard()`.

**Files:**
- Modify: `lib/firebase_options.dart` (after `:75`)
- Modify: `lib/widgets/accountAndBackup.dart` (`:132–136`)

**Interfaces:**
- Produces: `DefaultFirebaseOptions.macosClientId` (`static const String`, from `String.fromEnvironment('GOOGLE_MACOS_CLIENT_ID')`).
- Consumes: existing `getPlatform()` / `PlatformOS.isMacOS` (`lib/functions.dart`), `signIn.GoogleSignIn` (the `google_sign_in` import aliased `signIn`, already in `accountAndBackup.dart`).

- [ ] **Step 1: Add the env-sourced `macosClientId` constant**

In `lib/firebase_options.dart`, immediately after the closing `);` of the `static const FirebaseOptions ios = FirebaseOptions(...)` block (ends at `:75`), before the class's closing `}`, add:

```dart

  // macOS uses its own OAuth client (bundle com.budget.budget). Injected at
  // build time via --dart-define so the value is NOT committed to the repo.
  // Read directly — currentPlatform throws UnsupportedError on macOS.
  // Empty when not supplied; macOS sign-in then fails gracefully.
  static const String macosClientId =
      String.fromEnvironment('GOOGLE_MACOS_CLIENT_ID');
```

- [ ] **Step 2: Add the macOS arm to the sign-in platform branch**

In `lib/widgets/accountAndBackup.dart`, replace the branch at `:132–136`:

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

Do not change the `scopes` list or any other line. `DefaultFirebaseOptions` is already imported (the iOS branch references it).

- [ ] **Step 3: Verify it analyzes clean**

Run: `flutter analyze lib/firebase_options.dart lib/widgets/accountAndBackup.dart`
Expected: No errors. (`String.fromEnvironment` is a valid const constructor; no warning expected.)

- [ ] **Step 4: Verify graceful compile without the value**

Run: `flutter analyze` confirms compilation; the constant defaults to `''` with no `--dart-define`. No runtime call is made here, so nothing to execute.

- [ ] **Step 5: Commit**

```bash
git add lib/firebase_options.dart lib/widgets/accountAndBackup.dart
git commit -m "feat: wire macOS Google sign-in client id from --dart-define"
```

Note for the controller/reviewer: confirm no real client id string appears in this diff — only `String.fromEnvironment('GOOGLE_MACOS_CLIENT_ID')`.

---

## Task 2: macOS Info.plist + git-ignored secrets wiring

Register the OAuth redirect URL scheme via a build variable, supply that variable from a git-ignored xcconfig, and keep the real value out of git.

**Files:**
- Modify: `macos/Runner/Info.plist`
- Modify: `macos/Runner/Configs/Debug.xcconfig`, `macos/Runner/Configs/Release.xcconfig`
- Create (committed): `macos/Runner/Configs/Secrets.xcconfig.example`
- Create (git-ignored): `macos/Runner/Configs/Secrets.xcconfig`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `GOOGLE_REVERSED_CLIENT_ID` (user-provided, Global Constraints).
- Produces: native config consumed at runtime by Task 1's sign-in (the redirect scheme).

- [ ] **Step 1: Add the URL scheme (build variable) to Info.plist**

In `macos/Runner/Info.plist`, inside the top-level `<dict>` (e.g. just before its closing `</dict>`), add:

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

- [ ] **Step 2: Lint the Info.plist**

Run: `plutil -lint macos/Runner/Info.plist`
Expected: `macos/Runner/Info.plist: OK`

- [ ] **Step 3: Create the committed example template**

Create `macos/Runner/Configs/Secrets.xcconfig.example` with a placeholder (NOT the real value):

```
// Copy this file to Secrets.xcconfig (git-ignored) and fill in the real value.
// The reversed client id is the macOS OAuth client id with its halves swapped:
//   <id>.apps.googleusercontent.com  ->  com.googleusercontent.apps.<id>
GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.267621253497-XXXX
```

- [ ] **Step 4: Create the git-ignored real secrets file**

Create `macos/Runner/Configs/Secrets.xcconfig` with the **real** reversed client id supplied by the user (do this only locally; it must not be committed):

```
GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.<REAL_VALUE>
```

If the real value is not yet available, copy the `.example` placeholder for now and note it — manual verification cannot pass until it is real.

- [ ] **Step 5: Optionally include the secrets file from the build configs**

In `macos/Runner/Configs/Debug.xcconfig`, append:

```
#include? "Secrets.xcconfig"
```

In `macos/Runner/Configs/Release.xcconfig`, append:

```
#include? "Secrets.xcconfig"
```

(`#include?` is an optional include — a clean checkout without `Secrets.xcconfig` still builds; the URL scheme just expands to empty.)

- [ ] **Step 6: Git-ignore the real secrets file**

In `budget/.gitignore`, under the existing `# Keys` section, add:

```
# macOS Google sign-in secret (real client id; keep out of git)
/macos/Runner/Configs/Secrets.xcconfig
```

- [ ] **Step 7: Verify the real value is NOT tracked by git**

Run: `git status --porcelain macos/Runner/Configs/`
Expected: shows `Secrets.xcconfig.example` (and the modified configs) but **NOT** `Secrets.xcconfig`.

Run: `git check-ignore macos/Runner/Configs/Secrets.xcconfig`
Expected: prints the path (confirming it is ignored).

- [ ] **Step 8: Commit (verify the diff carries no real id)**

```bash
git add macos/Runner/Info.plist macos/Runner/Configs/Debug.xcconfig macos/Runner/Configs/Release.xcconfig macos/Runner/Configs/Secrets.xcconfig.example .gitignore
git commit -m "feat: macOS OAuth redirect scheme via git-ignored xcconfig"
```

Before committing, confirm the staged diff contains only `$(GOOGLE_REVERSED_CLIENT_ID)`, the `XXXX` placeholder, and `#include?` lines — no real client id. (`git diff --cached | grep -i "\|<REAL_VALUE>"` should print nothing.)

---

## Task 3: macOS outbound-network entitlement

Grant the sandbox outbound network access. Without it the sandbox blocks all outbound traffic (sign-in, Gmail, Drive, Gemini).

**Files:**
- Modify: `macos/Runner/DebugProfile.entitlements`
- Modify: `macos/Runner/Release.entitlements`

**Interfaces:**
- Produces: native sandbox capability required by Task 1's runtime sign-in and all outbound HTTP.

- [ ] **Step 1: Add `network.client` to DebugProfile.entitlements**

In `macos/Runner/DebugProfile.entitlements`, inside the `<dict>`, add (keep the existing `app-sandbox`, `cs.allow-jit`, `network.server`):

```xml
	<key>com.apple.security.network.client</key>
	<true/>
```

- [ ] **Step 2: Add `network.client` to Release.entitlements**

In `macos/Runner/Release.entitlements`, inside the `<dict>`, add (keep the existing `app-sandbox`):

```xml
	<key>com.apple.security.network.client</key>
	<true/>
```

- [ ] **Step 3: Lint both entitlements files**

Run: `plutil -lint macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements`
Expected: both report `OK`.

- [ ] **Step 4: Commit**

```bash
git add macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements
git commit -m "feat: add macOS outbound-network sandbox entitlement"
```

---

## Final manual verification (run on a Mac, with the real values in place)

OAuth, URL schemes, sandbox entitlements, and `--dart-define` injection only exercise at runtime on macOS. With the real `Secrets.xcconfig` present, run:

- [ ] `flutter run -d macos --dart-define=GOOGLE_MACOS_CLIENT_ID=<real-client-id>` builds and launches. (Tip: keep the id in a git-ignored JSON and use `--dart-define-from-file=<that.json>` to avoid retyping.)
- [ ] In **Auto Transactions**, toggle **Read Emails** → the Google consent screen appears, lists the Gmail scopes, and sign-in completes without error.
- [ ] The app does not immediately bounce back to a re-sign-in prompt (`testIfHasGmailAccess()` returns true).
- [ ] Trigger a scan → a transaction is created from a matching bank email (requires a configured `ScannerTemplate`).
- [ ] With a Gemini key set and **AI Categorization** on, a first-seen merchant receives an AI-assigned category — confirming outbound network works under the new entitlement.
- [ ] Regression: sign-in still works on one of Android / iOS / web (the added ternary arm must not disturb the existing paths).

If sign-in fails with a redirect/`canceled` error: confirm `Secrets.xcconfig` exists with the correct `GOOGLE_REVERSED_CLIENT_ID`, that the `--dart-define` client id matches it, and that both entitlements have `network.client`.

---

## Notes / decisions resolved here

- **Secret handling:** client id kept out of git — Dart via `--dart-define` (`String.fromEnvironment`), Info.plist via `$(GOOGLE_REVERSED_CLIENT_ID)` from a git-ignored `Secrets.xcconfig`; committed `.example` template documents the format.
- **No `GIDClientID` shortcut:** `google_sign_in_ios 5.9.0` requires the client id passed from Dart; it does not read `GIDClientID` from `Info.plist`.
- **No pubspec change:** macOS support ships transitively with `google_sign_in ^6.2.1`.
- **Out of scope** (per spec): Firebase cloud sync on macOS, Drive backup on macOS, signing/notarization, and the export "native Save As" polish (file-based migration already works on macOS).

## Self-Review

- **Spec coverage:** Section 1 (env-sourced client-id constant) → Task 1; Section 2 (sign-in branch) → Task 1 Step 2; Section 3 (Info.plist `$(GOOGLE_REVERSED_CLIENT_ID)` + git-ignored xcconfig + `.example` + `.gitignore`) → Task 2; Section 4 (network.client on both entitlements) → Task 3; secret-out-of-repo requirement → Global Constraints + Task 1 note + Task 2 Steps 4/6/7/8; Testing → Final manual verification; graceful-failure/platform-isolation → Global Constraints + Task 1's additive branch.
- **Placeholder scan:** committed artifacts intentionally use `$(GOOGLE_REVERSED_CLIENT_ID)`, `XXXX`, and `<REAL_VALUE>` — these are required not-committed markers, defined with exact form in Global Constraints, not vague "TBD" work. The only non-committed real value goes into the git-ignored `Secrets.xcconfig` (Task 2 Step 4) and the `--dart-define` (final verification).
- **Type/name consistency:** `DefaultFirebaseOptions.macosClientId` defined (Task 1 Step 1) and consumed (Task 1 Step 2) identically; env key `GOOGLE_MACOS_CLIENT_ID` and build var `GOOGLE_REVERSED_CLIENT_ID` are used consistently across tasks and the final checklist; `PlatformOS.isMacOS` matches `lib/functions.dart`.
