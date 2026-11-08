# winrt_ocr_flutter

**Version 0.1.0** — production-readiness hardening pass. See
`CHANGELOG.md` for version history.

On-device Windows OCR for Flutter, via `Windows.Media.Ocr` (C++/WinRT).
Designed to slot behind a per-platform OCR dispatch abstraction in a
consuming app, alongside mobile OCR engines for Android/iOS — this
package only ever handles the Windows branch.

**It has been built and run for real** (not just reviewed source) — see
"Verification status" below: it compiles (debug **and** release), links,
registers, and correctly recognizes real multi-line text through the
actual `Windows.Media.Ocr` pipeline on a real Windows 11 machine, and its
Dart-side method-channel contract has real `flutter test` coverage (see
"Testing"). Package identity (MSIX), previously assumed mandatory from
Microsoft's documentation, turned out NOT to be required on the test
machine — see "Package identity (MSIX) — documented requirement vs.
observed behavior" for the full, important caveat before relying on that.

## Contents

- [Verification status](#verification-status--read-this-first)
- [Toolchain used for verification](#toolchain-used-for-verification)
- [Fixes required to compile](#fixes-required-to-compile)
- [What this is](#what-this-is)
- [Installation](#installation)
- [Testing](#testing)
- [Versioning and dependency policy](#versioning-and-dependency-policy)
- [Package identity (MSIX)](#package-identity-msix--documented-requirement-vs-observed-behavior)
- [Integrating into a consuming app](#integrating-into-a-consuming-app)
- [Ownership and repository](#ownership-and-repository)
- [Publishing checklist](#publishing-checklist)

## Verification status — read this first

**Built and exercised on a real Windows machine** (see exact toolchain
versions below) via a throwaway `flutter create --platforms=windows` test
harness depending on this package as a `path:` dependency. Findings:

- [x] Compiles clean with MSVC (0 errors after two real fixes — see
      "Fixes required to compile" below) and links against `windowsapp.lib`.
- [x] `generated_plugin_registrant.cc` registers
      `WinrtOcrFlutterPluginCApiRegisterWithRegistrar` automatically — no
      manual registration step, confirming Flutter's standard
      federated-plugin mechanism works for this plugin.
- [x] Dart → native invocation succeeds with no `MissingPluginException`.
- [x] **Actual OCR text recognition verified correct**, including
      multi-line receipts: an on-disk PNG rendered with
      `"WALMART" / "MILK 3.48" / "BREAD 2.50"` on three lines came back
      as `"WALMART\nMILK 3.48\nBREAD 2.50"` — exact text, exact line
      order, decimals intact, via the real
      `StorageFile`→`BitmapDecoder`→`OcrEngine.RecognizeAsync` pipeline
      (nothing hardcoded or mocked in this plugin).
- [x] Clean failure path verified: a nonexistent file path surfaced as
      `WinrtOcrException("An item cannot be found at the specified
      path...")` — caught, not a crash, not a hang.
- [x] **Package identity was NOT required** on this machine/OS build —
      see the corrected "Package identity" section below; this
      contradicts what Microsoft's own documentation says elsewhere, so
      treat it as machine-specific evidence, not a blanket guarantee.

This was tested in a throwaway local harness, not any specific consuming
app's own exported build — the plugin itself is unmodified between the
two, but a different app's `windows/runner/` scaffold and app manifest
could differ in ways that affect OCR-engine availability. Retest once
integrated into the real target app's build.

## Toolchain used for verification

- Flutter 3.44.6 (stable channel), Dart 3.12.2
- Visual Studio Community 2026, version 18.8.12023.21 (MSVC toolset
  14.51.36231)
- Windows 10 SDK 10.0.26100.0
- Windows 11 Home 64-bit, 25H2
- CMake bundled with Visual Studio
  (`Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`) —
  no separate CMake/Ninja install needed; VS's "Desktop development with
  C++" workload provides it.

Build commands used: `flutter build windows --debug` (initial
verification) **and** `flutter build windows --release` (0.1.0 hardening
pass — confirms the same CMake configuration compiles under release
optimizations, not just debug) — both from a
`flutter create --platforms=windows` harness with this package declared
as a `path:` dependency (see "Installation" for why a path dependency was
used for this verification). Both configurations produced identical,
correct OCR results when run. Re-run and re-verified after the
`nb_windows_ocr` → `winrt_ocr_flutter` rename with identical results.

## Fixes required to compile

Two real, plugin-local bugs were found and fixed by actually compiling
against this toolchain — both are now already applied in this package's
source, not just documented:

1. **C++ standard mismatch.** Flutter's generated Windows app template
   defines `apply_standard_settings()` (in the *consuming app's*
   `windows/CMakeLists.txt`, not this plugin — can't be edited here)
   which hard-pins every target, including plugins, to `cxx_std_17`.
   C++/WinRT's coroutine support (`co_await`, `winrt::fire_and_forget`)
   needs the standard C++20 `<coroutine>` header; under C++17 it falls
   back to the deprecated `<experimental/coroutine>` header, which this
   MSVC/STL version rejects outright (`error C2338: ... STL1011 ...`).
   Fixed by adding `target_compile_features(${PLUGIN_NAME} PUBLIC
   cxx_std_20)` to `windows/CMakeLists.txt` right after
   `apply_standard_settings(...)` — CMake resolves a target's actual
   `/std:` flag as the highest standard requested across all
   `target_compile_features` calls for that target, so this raises only
   `winrt_ocr_flutter_plugin` to C++20 without touching the consuming
   app's own C++17 setting or any other plugin.
2. **Missing include for the ranged-for over `OcrResult.Lines()`.**
   `for (auto const &line : ocr_result.Lines())` failed with
   `error C3779: ... consume_Windows_Foundation_Collections_IIterable<D,T>::begin ...`
   because `<winrt/Windows.Media.Ocr.h>` alone doesn't fully instantiate
   `IVectorView<T>`'s iterator support. Fixed by adding
   `#include <winrt/Windows.Foundation.Collections.h>` to
   `windows/winrt_ocr_flutter_plugin.cpp`.

A separate, harness-only issue was hit and worked around in the *test
harness*, not this plugin: a stale `.plugin_symlinks` symlink from copying
the harness directory (delete `windows/flutter/ephemeral` and rerun), a
Windows `MAX_PATH` (260 char) failure from building inside a deeply
-nested scratch path (use a short path instead), and a missing
`build/native_assets/windows` directory that Flutter's newer native-assets
feature expects even for projects using none (create the empty directory).
None of these are `winrt_ocr_flutter` issues.

## What this is

- `lib/winrt_ocr_flutter.dart` — the Dart-facing API:
  `WinrtOcr.recognizeText(String imagePath) -> Future<String>`.
- `windows/winrt_ocr_flutter_plugin.{h,cpp}` — the native implementation:
  loads the image at the given path via `StorageFile` + `BitmapDecoder`,
  runs `OcrEngine.RecognizeAsync`, and joins `OcrResult.Lines` with `\n`
  (preserving Windows.Media.Ocr's own line order — no reordering,
  normalization, or parsing here; this package returns raw OCR text
  only). Every failure path resolves the method channel with an `Error`
  (or `''` for "engine unavailable") rather than crashing the process.
- `windows/CMakeLists.txt` + the `include/` C-API header — standard
  Flutter Windows plugin registration boilerplate, so once this package
  is a declared pub dependency, Flutter's build tooling auto-discovers
  and links it via the standard federated-plugin mechanism (confirmed
  working — see "Verification status").
- `test/winrt_ocr_flutter_test.dart` — Dart-side method-channel contract
  tests (see "Testing").
- `CHANGELOG.md`, `LICENSE`, `analysis_options.yaml` — standard Flutter
  plugin package structure; see "Versioning and dependency policy" and
  "Publishing checklist".

No image bytes or OCR output are logged anywhere in this plugin.

## Installation

Not yet published (see "Publishing checklist"). For now, add it as a path
dependency:

```yaml
# Local/unpublished (path dependency — what this README's own
# verification used):
dependencies:
  winrt_ocr_flutter:
    path: ../path/to/winrt_ocr_flutter

# Once published (pub.dev or a private/self-hosted pub server):
dependencies:
  winrt_ocr_flutter: ^0.1.0
```

Then run `flutter pub get`. No manual native-plugin registration step is
needed — Flutter's standard federated-plugin mechanism auto-generates the
`windows/flutter/generated_plugin_registrant.cc` entry from this package's
`pubspec.yaml` `flutter.plugin.platforms.windows` declaration (confirmed
working — see "Verification status"). No other install step, no
additional Windows SDK components beyond what "Toolchain used for
verification" lists, and no application manifest changes are required for
the plugin itself to build and run.

## Testing

Two independent layers of verification exist for this package:

1. **Dart-side unit tests** (`test/winrt_ocr_flutter_test.dart`, run with
   `flutter test` from this package's directory) — mock the
   `winrt_ocr_flutter` method channel via
   `TestDefaultBinaryMessengerBinding` and verify the Dart-side contract:
   the exact method name and argument shape sent to the channel, that a
   string/`null`/`PlatformException` channel response each decode to the
   documented, safe result (`String`, `''`, and `WinrtOcrException`
   respectively), and that `WinrtOcrException`'s message falls back to
   the platform error code when no message is given. These do **not**
   exercise the real native `Windows.Media.Ocr` call — that's covered by
   item 2. All 7 tests pass.
2. **Real native integration** (see "Verification status" above) — an
   actual compiled Windows binary, run against real rendered test images,
   confirming the full `StorageFile → BitmapDecoder → OcrEngine →
   RecognizeAsync` pipeline produces correct text with correct line
   ordering, and that failures (a bad file path) surface cleanly. This is
   the layer `dart test`/`flutter test` structurally cannot reach (no
   Windows Runtime available in a headless Dart test process), so it was
   done by building and running the plugin for real rather than skipped.

Run both before trusting a future change to this package:

```bash
# From this package's directory
flutter test
flutter analyze
```

## Versioning and dependency policy

- **Semantic versioning, pre-1.0.** `0.1.0` (this release) — API-stable
  hardening + rename pass; `0.0.1` — initial working implementation
  (originally named `nb_windows_ocr`, see `CHANGELOG.md`). No breaking
  functional changes: `recognizeText(String) -> Future<String>` has been
  stable since `0.0.1`, only its enclosing class/package name changed in
  `0.1.0`. See `CHANGELOG.md` for the full history.
- **`environment.sdk: '>=3.2.0 <4.0.0'`, `environment.flutter:
  '>=3.19.0'`** — the Dart/Flutter floor needed for the C++/WinRT
  coroutine support and `flutter.plugin.platforms.windows` federation
  this package relies on. Verified against Flutter 3.44.6 / Dart 3.12.2
  (see "Toolchain used for verification") — well above the floor, so
  there's headroom; the floor itself has not been independently tested
  against an older SDK.
- **Runtime dependencies: `flutter` (SDK) only.** `plugin_platform_interface`
  was removed in 0.1.0 — it was declared but never used (this plugin has
  exactly one platform implementation, so the multi-implementation
  platform-interface pattern doesn't apply). No third-party OCR package
  dependency of any kind.
- **Native dependency: `windowsapp.lib`** (linked in `windows/CMakeLists.txt`)
  — the Windows SDK's own umbrella WinRT import library, present on every
  Windows 10+ SDK install; not a package, nothing to version or update.
- **Dev dependencies: `flutter_test` (SDK), `flutter_lints ^3.0.0`.**
  Bumping `flutter_lints` is safe at any time (dev-only, doesn't affect
  consumers) — not done in 0.1.0 to keep this hardening pass's diff
  minimal.

## Package identity (MSIX) — documented requirement vs. observed behavior

Microsoft's docs (and a Microsoft Q&A thread, ["Is the OCR API supported
from Win32 Applications without package
identity?"](https://learn.microsoft.com/en-us/answers/questions/4354/is-the-ocr-api-supported-from-win32-applications-w))
state that `Windows.Media.Ocr.OcrEngine` requires the calling process to
have **package identity** (MSIX or a sparse package). **That did not hold
up empirically**: on this test machine (Windows 11 Home 25H2, see exact
build below), `OcrEngine.TryCreateFromUserProfileLanguages()` returned a
valid, non-null engine and `RecognizeAsync` correctly recognized real text
from a completely unpackaged debug `.exe` (no `Package.appxmanifest`,
no MSIX, no sparse package — see "Verification status" above).

**Do not treat this as proof MSIX is unnecessary in production.** It's
one data point on one machine/OS build. Plausible explanations, none
confirmed: Windows 11's more recent servicing may have relaxed this
restriction for this specific API surface; the restriction may be
real but conditional on something this test machine happens to have
(a signed developer/enterprise policy, a Windows feature, a language
pack); or Microsoft's docs may be stale/overly conservative. **Before
relying on this in production, verify on a clean, representative
end-user Windows 10 and Windows 11 machine** (ideally a fresh VM with no
developer tooling installed) — if it fails there, package identity is
still the fix, and everything below still applies.

If a target machine *does* need package identity, this plugin already
degrades safely: `OcrEngine::TryCreateFromUserProfileLanguages()`
returning `nullptr` is reported as a clean `Error` result (see
`RecognizeTextAsync`'s null check), never a crash.

If verification on representative machines shows package identity IS
needed, giving a consuming app's shipped Windows build package identity
is a separate native packaging step, independent of this Dart package.
The standard, well-established way to do it for a Flutter Windows app:

1. Add the [`msix`](https://pub.dev/packages/msix) pub package (official
   -adjacent, ~2M downloads, actively maintained) as a dev dependency of
   the consuming app's own Flutter project (not this package).
2. Configure `msix_config` in that project's `pubspec.yaml`
   (`identity_name`, `publisher`, `publisher_display_name`, and either a
   test certificate for local/sideload use or a real code-signing
   certificate for distribution).
3. Run `flutter build windows` then `dart run msix:create` to produce a
   package-identity-bearing `.msix` — this is what the OCR engine actually
   needs to run correctly; the app still functions as before, just now
   installed/launched as a packaged app instead of a bare `.exe`.
4. Distribute via the Microsoft Store, sideloading, or an enterprise MSIX
   deployment tool, instead of (or alongside) any current unpackaged
   distribution.

This is real native/build-pipeline engineering work independent of this
package — it should be scoped and executed by whoever owns the consuming
app's actual Windows build/release process, since it changes how that
app is packaged and distributed, not just its OCR capability.

## Integrating into a consuming app

This package is designed to sit behind a per-platform OCR dispatch
abstraction: a consuming app typically has its own `OcrEngine`-style
interface (`Future<String> recognizeText(Uint8List bytes)` or similar)
with separate implementations per platform (e.g. ML Kit for Android/iOS).
To back the Windows branch:

```dart
import 'package:winrt_ocr_flutter/winrt_ocr_flutter.dart';

class MyWindowsOcrEngine implements MyOcrEngineInterface {
  @override
  Future<String> recognizeText(Uint8List bytes) async {
    // Windows.Media.Ocr needs a file path (via StorageFile/BitmapDecoder),
    // not raw bytes — write to an app-owned temp file first, matching
    // whatever temp-file lifecycle the consuming app already uses for its
    // other OCR engines, then clean it up afterward.
    final path = await writeToAppOwnedTempFile(bytes);
    try {
      return await WinrtOcr.recognizeText(path);
    } on WinrtOcrException {
      return ''; // treat engine-level failures like "no text found"
    } finally {
      await deleteQuietly(path);
    }
  }
}
```

`WinrtOcr.recognizeText` never throws for "no text found" (returns `''`)
and only throws `WinrtOcrException` for engine-level failures (missing
language pack, no package identity, a bad file path, etc.) — a consuming
app's catch-all should treat that the same as an empty result, exactly as
shown above.

## Ownership and repository

- **Copyright owner:** Danielle Drayson. See `LICENSE`.
- **License:** proprietary, All Rights Reserved — not MIT/Apache/BSD/GPL
  or any open-source license. No copying, modification, distribution,
  sublicensing, reverse engineering, republication, or commercial use
  without prior written permission from the copyright owner. Standard
  AS-IS/no-warranty disclaimer included.
- **Repository:** `https://github.com/EmpireBusinessSolutions/winrt_ocr_flutter`
  (private) — set as `repository:` in `pubspec.yaml`.
- No `homepage` — the repository URL covers discovery; this isn't a
  public package with a separate docs/marketing site.

## Publishing checklist

**Dry-run validated with the finalized metadata above.**
`flutter pub publish --dry-run` (which runs even with `publish_to: none`
set — that field only blocks the real publish command, not the dry run)
passes with **zero warnings and zero errors**. Package name, description,
version, SDK/Flutter constraints, `platforms`/`pluginClass` declaration,
dependency list, `README.md`, `CHANGELOG.md`, `LICENSE` content, file
layout, and archive size all validate clean. `flutter test` (7/7) and
`flutter analyze` (0 issues) both re-confirmed passing alongside this.

Remaining before the actual `flutter pub publish` (or a private-server
equivalent):

- [ ] **Recommended, not blocking:** reproduce the "Verification status"
      results on a **second, independent Windows machine** (ideally a
      clean VM with no developer tooling) before treating Windows OCR as
      fully production-certified — this is a production-validation step,
      not a publishing gate.
- [ ] Decide: publish to public pub.dev, or a private/self-hosted pub
      server the consuming app's build environment can reach? Given the
      proprietary license, **public pub.dev is very unlikely to be the
      right choice** — pub.dev is a public package registry, and a
      proprietary, all-rights-reserved license on a publicly listed
      package would expose the source to the exact copying/distribution
      the license prohibits. A private/self-hosted pub server (or a
      plain git/path dependency, where the consuming build system
      supports one) is the fit consistent with the ownership decisions
      above. This is the copyright owner's call, not something to
      default silently.
- [ ] Authenticate to wherever publishing actually happens (`dart pub
      login` for pub.dev, `dart pub token add <url>` for a private
      server) — not yet done in this workspace.
- [ ] Add a `CHANGELOG.md` entry for whatever version is about to be
      published if it differs from `0.1.0` (append, don't rewrite
      history).
- [ ] Remove `publish_to: none` from `pubspec.yaml` only as the final
      step, immediately before running the actual publish command.
