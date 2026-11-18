# iOS validation record (WidgetKit, Flutter sample)

This page records what was **actually run** against the iOS side of WidgetForge 0.1.0 (now WidgetTriage; v0.2.0 changes only the name) and what was not. It supports the
iOS rules `WF5001`-`WF5008` (`doctor`); it does not cover `verify` on a real IPA.

## Environment

| Item | Value |
|------|-------|
| Machine | Codemagic macOS 26.5.1 (cloud build machine) |
| Xcode / Swift | Xcode 26.6 (build 17F113) / Swift 6.3.3 |
| Flutter / Dart | 3.32.0 / 3.8.0 |
| Simulator | iPhone 17 Pro, iOS 26.5 |
| Build | Debug, `flutter build ios --simulator --no-codesign`; no Apple Developer signing identity was used |

## Sample

A Flutter project was generated with `flutter create`, and a hand-written SwiftUI WidgetKit extension (`WidgetExt`, one
`StaticConfiguration` widget that shows the time) was added to `ios/Runner.xcodeproj` by a script and embedded in the Runner
app. The extension was **not** created with Xcode's Widget Extension template. The App Group variants used a Dart-side
stand-in for the group id, not the `home_widget` plugin. The sample sources are not part of this repository.

## What was observed

| Observation | Result |
|-------------|--------|
| Xcode project builds with the extension (`.app` + `PlugIns/WidgetExt.appex`) | yes |
| Runner and WidgetExt `CFBundleShortVersionString` / `CFBundleVersion` | `1.0.0` / `1` in both (checked in the built Info.plists) |
| Version-field check before install | `VERSION_CHECK_OK` |
| `simctl install` | succeeded on the first attempt; the app container exists |
| Runner launch | exit 0; process listed by `launchctl` |
| Extension registration | `pluginkit` lists the extension with extension point `com.apple.widgetkit-extension` |
| Widget added to the home screen | yes (added manually over VNC; the widget shows the time, `06:03`, from `Text(entry.date, style: .time)`) |
| `doctor` on the unmodified sample | exit 0, no diagnostics |
| `doctor` after introducing one fault at a time into the project files | each of WF5001-WF5008 was reported; reverting returned the report to clean (WF5003 in three variants) |
| `doctor` on five App Group variants (also built unsigned for the simulator) | the reports matched the predictions written beforehand; no false positive and no false negative among them |

Screenshot of the home screen with the widget: SHA-256
`4946d5381efb35409184288ad091c6a6d4a5f204f190859ce6b93ccca3fdf9ef` (the image itself is not published with this repository).

An earlier run failed to install with `IXErrorDomain code=2` ("Invalid placeholder attributes"). At that time the extension's
built `Info.plist` had no `CFBundleShortVersionString` / `CFBundleVersion` because the Flutter version variables were not
defined for the extension target. After they were defined, install succeeded. These two observations occurred together; no control run
isolated the version fields as the cause, so this page does not claim that.

## What was not run

- **Widget gallery list:** no independent capture of the gallery. Only the result (widget placed on the home screen) was recorded.
- **App Group runtime data sharing** between the app and the widget.
- **Real or signed IPA**, and `verify` rules `WF7001`-`WF7004` against it (those remain synthetic-archive tests only; `WF7002` and `WF7004` stay warnings).
- **Release or Profile builds, physical devices, other iOS versions.**
- **Injected-fault projects were not built** (except the App Group variants above), so the runtime symptoms described in the rule pages
  were not reproduced for the other rules. An unsigned simulator build also does not apply entitlements the way a signed build does.
- **Xcode GUI Widget Extension template** project layout.
- **Embedded entitlements** of the built app were not captured.

## What this does and does not show

It shows that, on one real Xcode 26.6 project of this shape, the iOS rules produced no false positive on the clean sample, reported the
faults that were introduced, and that the sample installs, launches and shows its widget in the simulator. It does not show that
`doctor` is complete, that a clean report means a working widget, or that the rules hold for other project layouts, plugins or toolchain versions.
