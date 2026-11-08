# Changelog

## 0.1.0

Production-readiness hardening pass. No functional API change from
0.0.1 — only the package/API naming below.

- **Renamed the package from `nb_windows_ocr` to `winrt_ocr_flutter`** as
  part of establishing this as a standalone, generically-branded package
  (not tied to any specific consuming app). Renamed accordingly:
  - `NbWindowsOcr` → `WinrtOcr`, `NbWindowsOcrException` →
    `WinrtOcrException` (public Dart API).
  - `lib/nb_windows_ocr.dart` → `lib/winrt_ocr_flutter.dart`.
  - MethodChannel name `nb_windows_ocr` → `winrt_ocr_flutter`.
  - Native plugin class `NbWindowsOcrPlugin` → `WinrtOcrFlutterPlugin`,
    C-API entry point `NbWindowsOcrPluginCApiRegisterWithRegistrar` →
    `WinrtOcrFlutterPluginCApiRegisterWithRegistrar`, native namespace
    `nb_windows_ocr` → `winrt_ocr_flutter`, all native file/header names
    and CMake target names updated to match.
  - `repository:` set to `https://github.com/EmpireBusinessSolutions/winrt_ocr_flutter`.
  - `LICENSE` copyright line simplified to `Copyright © 2026 Danielle
    Drayson` (no change in ownership — the qualifier referencing a
    specific consuming app's brand was removed from this now-standalone
    package's own identity).
  - Re-verified end-to-end after the rename: `flutter test`,
    `flutter analyze`, `flutter pub publish --dry-run`,
    `flutter build windows --debug`, and `flutter build windows
    --release` all re-run and passing post-rename — see README.md
    "Verification status".
- Removed the unused `plugin_platform_interface` dependency (this plugin
  has exactly one platform implementation; the platform-interface pattern
  is for plugins that need a shared Dart interface across multiple
  platform-specific implementations, which doesn't apply here).
- Added `test/winrt_ocr_flutter_test.dart` — Dart-side unit tests covering
  the method-channel contract (method name, argument shape, success
  decoding, `PlatformException` → `WinrtOcrException` conversion,
  null-result handling) via `TestDefaultBinaryMessengerBinding`'s mock
  channel handler. Run with `flutter test`.
- Added `analysis_options.yaml`, `LICENSE`, and this changelog, matching
  standard Flutter plugin package structure.
- Verified a `--release` Windows build (not just `--debug`) compiles and
  links cleanly with the same CMake configuration.
- Documentation: reorganized README.md into clear installation,
  versioning/dependency, and integration sections.
- `flutter pub publish --dry-run` passes with zero warnings.

## 0.0.1

Initial implementation. Wraps `Windows.Media.Ocr` via C++/WinRT behind a
single `recognizeText(imagePath)` method channel call — see README.md for
full architecture and evaluation notes. (Originally developed and named
`nb_windows_ocr`; renamed to `winrt_ocr_flutter` in 0.1.0 — see above.)

- Built, linked, registered, and run successfully on a real Windows 11
  25H2 machine (Flutter 3.44.6, Visual Studio Community 2026 18.8.2,
  Windows 10 SDK 10.0.26100.0) via a throwaway local test harness.
- Verified correct multi-line OCR text extraction end-to-end (exact text,
  exact line order, decimals intact) against real rendered test images.
- Verified clean failure handling (nonexistent file path) — no crash.
- Two plugin-local compile fixes applied and documented (C++ standard
  mismatch with Flutter's app-level `apply_standard_settings()`; a
  missing `<winrt/Windows.Foundation.Collections.h>` include).
- Package identity (MSIX) was empirically NOT required for the OCR engine
  to function on the verification machine, contradicting Microsoft's own
  documentation — flagged as a single data point requiring verification
  on a representative end-user machine before being relied on.
