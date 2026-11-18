# WidgetTriage

**Read-only diagnostics CLI for Flutter home screen widgets on Android (AppWidget / RemoteViews) and iOS (WidgetKit extensions).**

WidgetTriage statically inspects a Flutter project's `android/` and `ios/` folders and the project's Dart sources and
reports configuration mistakes in these areas:

- **Android:** `RemoteViews` widget layouts, `AppWidgetProvider` receivers and their provider XML, `AndroidManifest.xml`
  wiring (including `android:exported`), and the Dart entrypoints of separate `FlutterActivity` classes.
- **iOS:** WidgetKit extension targets in the Xcode project (`project.pbxproj`): embedding in the app, the extension
  `Info.plist`, bundle identifier prefix, entitlements and App Groups, the `@main` entry point and the deployment target.

Such mistakes are commonly associated with a widget that does not load, a widget missing from the launcher's picker or
widget gallery, manifest-merger or signing/validation errors, or a blank secondary `FlutterActivity`. WidgetTriage is a
static tool: it does not run the app, a build, a simulator or a device, so it does not observe those symptoms at runtime.
Output is stable, machine-readable JSON designed to be consumed by AI coding agents as well as people. Android-only,
iOS-only and combined Flutter projects are supported; a platform whose project files do not exist is simply not checked.

It does not replace [`home_widget`](https://pub.dev/packages/home_widget). It does not depend on any
widget package and also works for hand-written native widgets. It never modifies the project it inspects.

> WidgetTriage was formerly known as WidgetForge. The project was renamed in v0.2.0. Existing v0.1.0 releases and diagnostic codes remain preserved.

> **Status: v0.2.0** (a rename of v0.1.0; checks and diagnostic codes are unchanged). Not published to pub.dev. Android checks are the most verified; iOS rules were exercised on one Xcode 26.6 / iOS 26.5 simulator sample ([docs/ios-validation.md](docs/ios-validation.md)); IPA verification is Experimental. Licensed under the [MIT License](LICENSE).

## At a glance

- **What:** a read-only CLI that checks a Flutter project's Android (AppWidget / RemoteViews) and iOS (WidgetKit) home screen widget configuration and prints stable, machine-readable diagnostics (29 rules, `WF1001`-`WF7004`).
- **Solves:** the "why does my widget not show up / not load" class of setup mistakes: unregistered receivers, missing provider metadata or `android:exported`, unsupported RemoteViews classes, a WidgetKit extension that is not embedded, App Group or bundle-id mismatches. Each finding names the file, line, literal evidence and a fix.
- **Why not just check by hand:** the same wiring is spread over manifests, provider XML, layouts, Xcode project files, plists and entitlements; the tool checks all of them in one run, repeatably, with evidence an AI coding agent can act on.
- **Run:** `dart pub get && dart run bin/widgettriage.dart doctor --json <flutter_project_root>` ([Quick start](#quick-start)).
- **Agents:** exit codes 0/1/2 and JSON-only stdout; [SKILL.md](skills/widgettriage/SKILL.md) tells Claude Code or Codex when and how to use it ([AI agent integration](#ai-agent-integration)).
- **Not:** a renderer, a build, a runtime test or an auto-fixer. It never modifies the inspected project.

## Quick start

Requires a Dart SDK that satisfies `environment.sdk` in `pubspec.yaml` (`^3.5.0`, i.e. Dart 3.5 or newer and below 4.0).
**Main verification: Dart 3.8.0 (Flutter 3.32.0) on Linux.** On Dart 3.5.4 (Linux) `dart analyze` was clean and all 302 tests passed once; Dart 3.5.0 itself and other platforms were not tested.
From a checkout of this repository (`git clone https://github.com/z0rimo/widgettriage.git`). A fresh clone of the repository was checked with Dart 3.8.0 (`dart pub get`, `dart analyze`, `dart test`, the commands below):

```sh
dart pub get
dart run bin/widgettriage.dart doctor --json /path/to/flutter_project
```

Without `--json` a human-readable report is printed. `path` defaults to the current directory and
must be a Flutter project root: it needs `pubspec.yaml` and at least one platform project, `android/app/src/main/AndroidManifest.xml` and/or `ios/*.xcodeproj/project.pbxproj`.

```sh
dart run bin/widgettriage.dart --help
dart run bin/widgettriage.dart --version
```

### Running it: what has been verified

With `--json`, stdout must be exactly one JSON document; errors and usage messages go to stderr.
The first two rows were verified to meet that in every run tested (Dart SDK 3.8.0, Linux); the git row only partially, as stated; the last two rows are not suitable or not verified.

| How | Status |
|-----|--------|
| `dart run bin/widgettriage.dart ...` | **Verified.** The supported development path. |
| Native executable (JSON automation) | **Verified.** Build once, then call the binary directly: `dart pub get && mkdir -p build && dart compile exe bin/widgettriage.dart -o build/widgettriage`, then `build/widgettriage doctor --json <path>`. Same stdout and exit codes as `dart run`. |
| `dart pub global activate --source git https://github.com/z0rimo/widgettriage.git` | **Verified once against the GitHub repository** on Linux with Dart 3.8.0 (installed from `main` at `93d9fa8` into a temporary pub cache: `widgettriage --version` printed `widgettriage 0.2.0` and `doctor --json` wrote a single JSON document to stdout). Not verified on macOS or Windows or with other SDK versions; check that stdout is one JSON document before relying on it. |
| `dart pub global activate --source path .` | **Not recommended for `--json`.** On Dart SDK 3.8.0 the generated launcher can print pub's `Resolving dependencies...` output to stdout in front of the JSON (see below). |
| pub.dev (`dart pub global activate widgettriage`) | **Not verified.** The package is not published; no behaviour is guaranteed. |

Checked (as WidgetForge v0.1.0, entry point `bin/widgetforge.dart`) from a fresh clone of the GitHub repository (Dart 3.8.0): `dart pub get`, `dart analyze`, `dart test`, `dart run bin/widgetforge.dart doctor --json <project>`. The renamed entry point `bin/widgettriage.dart` was re-run locally for v0.2.0 (not from a fresh clone). Not checked from a fresh clone: the compiled executable (checked from the same source tree) and the git-source activation above.

#### Known issue: path-activated launcher on Dart SDK 3.8.0

Observed on Dart 3.8.0 only; other SDK versions have not been tested, so do not assume it applies to them
(or that it does not). The launcher that `dart pub global activate --source path .` generates points at a
snapshot file that does not exist, so it falls back to `dart pub global run`, which prints dependency
resolution output to **stdout** before WidgetTriage's own output. WidgetTriage's JSON and the exit codes
(0/1/2) are unchanged; only extra text precedes the JSON, so a strict JSON parser fails. The same behaviour
reproduces with an empty dependency-free package, so it comes from the SDK's `pub` tool and not from WidgetTriage.
Whether it occurs also depends on whether a pub snapshot already exists in the checkout.
If you do use a launcher, check that stdout parses as one JSON document before trusting it.

### Exit codes

| Code | Meaning |
|-----:|---------|
| 0 | The checks ran and reported no `error` (warnings, which only `verify` emits for IPA, and notes do not change the code; see "How to read a result") |
| 1 | One or more errors were reported |
| 2 | Usage error, or the path is not a Flutter project / has no analyzable platform project, or the file given to `verify` is not a supported, safe, readable APK/IPA (message on stderr, no JSON) |

### How to read a result

WidgetTriage v0.2.0 is a static diagnostic tool for Android and iOS projects. Read the JSON in this order:

- `diagnostics[]` are the findings, each with a `file`, a `line` (can be `null` when no single line applies), `evidence` and `fix`. Almost all are `error` (counted in `summary.errors`, exit code 1); WF7002 and WF7004 (IPA, unverified) are `warning` and leave the exit code at 0, so read `diagnostics[]` even when the exit is 0.
- `notes[]` are plain strings that are **not** diagnostics: they change neither `summary` nor the exit code. They record
  what could not be checked or what depends on the build variant, for example: layout checks skipped because no widget
  receiver was found; a receiver declared only in a non-main source set (debug, release, a flavor) or removed with
  `tools:node`; `targetSdk` below 31 suppressing the `android:exported` check (WF2004); a Dart entrypoint library that
  `lib/main.dart` does not import, or whose reachability is unknown. A note means "look at this", not "this is fine".
- **Zero diagnostics (exit code 0) does not mean everything was verified.** It means only that the checks implemented in
  this version found nothing in their current scope. Read `notes[]` too, and remember the [limitations](#limitations).
- It is not a guarantee that the widget renders correctly on a device. Nothing was verified on an emulator or device, and
  a successful build does not prove that a widget layout inflates.

**`doctor` vs `verify`:** `doctor` reads a project's *source* (Android manifest, layouts, provider XML, Xcode project, plists) before you build; `verify` reads a *built* `.apk` or `.ipa` and checks what actually ended up inside it.

## Example output

Excerpts of real output (`projectPath` shortened) from the synthetic projects in `fixtures/`.

A project without findings (`doctor --json fixtures/ok_basic`, exit code 0):

```json
{
  "schemaVersion": "1",
  "tool": { "name": "widgettriage", "version": "0.2.0" },
  "summary": { "errors": 0, "warnings": 0, "infos": 0 },
  "checksRun": ["manifest-receivers", "provider-xml", "remoteviews-supported-views", "flutter-activity-entrypoint"],
  "notes": [],
  "diagnostics": []
}
```

A project with a finding (`doctor --json fixtures/err_receiver_missing_exported`, exit code 1):

```json
{
  "code": "WF2004",
  "severity": "error",
  "title": "Widget receiver with intent-filter lacks android:exported",
  "file": "android/app/src/main/AndroidManifest.xml",
  "line": 16,
  "evidence": "<receiver android:name=\".DemoWidgetProvider\"> (no android:exported)",
  "fix": "Add android:exported=\"true\" to this <receiver>.",
  "docs": "docs/errors/WF2004.md"
}
```

(`message` omitted here; the full report also contains `projectPath`, `summary` and `checksRun`.) An empty `diagnostics` list means only that the implemented checks found nothing.

## What it detects

| Code | Problem |
|------|---------|
| [WF1001](docs/errors/WF1001.md) | View not supported by RemoteViews (ConstraintLayout, ScrollView, RecyclerView, EditText, custom views, ...) in a widget layout, including `<include>`d layouts |
| [WF2001](docs/errors/WF2001.md) | AppWidgetProvider class exists but is not registered as `<receiver>` |
| [WF2002](docs/errors/WF2002.md) | Widget receiver lacks the `APPWIDGET_UPDATE` intent-filter |
| [WF2003](docs/errors/WF2003.md) | Widget receiver lacks `android.appwidget.provider` meta-data |
| [WF2004](docs/errors/WF2004.md) | Receiver with an intent-filter lacks `android:exported` |
| [WF3001](docs/errors/WF3001.md) | Provider XML missing, malformed, or not rooted at `<appwidget-provider>` |
| [WF3002](docs/errors/WF3002.md) | `android:initialLayout` missing |
| [WF3003](docs/errors/WF3003.md) | `initialLayout` / `previewLayout` resource not found |
| [WF3004](docs/errors/WF3004.md) | `android:configure` activity not registered in the manifest |
| [WF4001](docs/errors/WF4001.md) | Dart entrypoint named by a separate `FlutterActivity` not found |
| [WF4002](docs/errors/WF4002.md) | That entrypoint lacks `@pragma('vm:entry-point')` |
| [WF4003](docs/errors/WF4003.md) | `FlutterActivity` subclass not registered in the manifest |
| [WF5001](docs/errors/WF5001.md) | iOS: WidgetKit extension target not embedded in an app target |
| [WF5002](docs/errors/WF5002.md) | iOS: extension `Info.plist` lacks `NSExtensionPointIdentifier = com.apple.widgetkit-extension` |
| [WF5003](docs/errors/WF5003.md) | iOS: extension `Info.plist` missing, not referenced, or not a valid property list |
| [WF5004](docs/errors/WF5004.md) | iOS: extension bundle identifier not prefixed with the app bundle identifier |
| [WF5005](docs/errors/WF5005.md) | iOS: `CODE_SIGN_ENTITLEMENTS` points to a file that does not exist |
| [WF5006](docs/errors/WF5006.md) | iOS: App Group used by the widget is not in its entitlements, or app and widget share no App Group |
| [WF5007](docs/errors/WF5007.md) | iOS: no `@main` entry point in the widget extension sources |
| [WF5008](docs/errors/WF5008.md) | iOS: widget extension deployment target below iOS 14 |
| [WF6001](docs/errors/WF6001.md) | `verify` APK: widget receiver without `android:exported` (targetSdk >= 31) |
| [WF6002](docs/errors/WF6002.md) | `verify` APK: widget receiver without provider meta-data |
| [WF6003](docs/errors/WF6003.md) | `verify` APK: provider XML missing |
| [WF6004](docs/errors/WF6004.md) | `verify` APK: provider XML without `initialLayout` |
| [WF6005](docs/errors/WF6005.md) | `verify` APK: `initialLayout` resource missing |
| [WF7001](docs/errors/WF7001.md) | `verify` IPA: Info.plist missing, unreadable or lacking a required key |
| [WF7002](docs/errors/WF7002.md) | `verify` IPA (warning, unverified): widget extension bundle id not prefixed with the app's |
| [WF7003](docs/errors/WF7003.md) | `verify` IPA: widget extension executable missing |
| [WF7004](docs/errors/WF7004.md) | `verify` IPA (warning, unverified): widget extension MinimumOSVersion below 14 |

Every diagnostic carries a stable `code`, the `file` and `line` (`null` if no single line applies), the literal `evidence`, an
explanation and a concrete `fix`. Details: [diagnostic contract](docs/diagnostic-contract.md) and
[JSON Schema](schema/diagnostic-report.schema.json). Agent usage procedure: [SKILL.md](skills/widgettriage/SKILL.md).

## AI agent integration

[`skills/widgettriage/SKILL.md`](skills/widgettriage/SKILL.md) is an agent skill that describes when to use WidgetTriage (widget setup problems only, not general Flutter UI work), how to run it, how to parse the JSON and exit codes, and that source edits need the user's approval. Install it with the installer script below, or by copying the folder `skills/widgettriage/` into the skills directory your agent reads:

| Agent | Project (this project only) | User (all your projects) |
|---|---|---|
| Claude Code | `.claude/skills/widgettriage/SKILL.md` | `~/.claude/skills/widgettriage/SKILL.md` |
| Codex | `.agents/skills/widgettriage/SKILL.md` | `~/.agents/skills/widgettriage/SKILL.md` |

These are the locations given in each tool's own documentation (read in November 2026); the two tools use different directories, so install the folder in each one you use. Other agents: use the location your agent documents for skill or instruction files, or paste the contents of `SKILL.md` into its instructions.

#### Installer script

The CLI and the skill are two separate installs: the skill is a set of instructions for your agent, and it calls the `widgettriage` CLI, which must be available as well (see Quick start). From a checkout of this repository:

```sh
# preview, nothing is written
dart run scripts/install_agent_skill.dart --agent both --scope project --project /path/to/flutter_project --dry-run
# project scope: only that project
dart run scripts/install_agent_skill.dart --agent both --scope project --project /path/to/flutter_project
# user scope: all your projects (~/.agents/skills and ~/.claude/skills)
dart run scripts/install_agent_skill.dart --agent both --scope user
```

`--agent` is `codex`, `claude` or `both` (default `both`); `--scope` is `project` (default) or `user`. It copies files from the checkout (no download, nothing runs on `dart pub get`), reports each agent separately (`INSTALLED`, `ALREADY INSTALLED`, `CONFLICT`, `FAILED`) and exits 1 if any target conflicted or failed. An existing different copy is never overwritten unless you pass `--force`, which replaces only that file inside the `widgettriage` skill directory and keeps the old one as `SKILL.md.bak`; symbolic links at the target are never followed or replaced. Check the result by looking at the printed paths, then start a new agent session. Tested on Linux only (macOS and Windows: not run).

Listing and selecting are different things: a skill in one of these locations is *discoverable* (both tools read its name and description), but whether the model then *chooses* it for a given prompt is the model's decision and is not guaranteed (see "What was tested").

Name collisions: install it in one scope unless you need both. If the same name `widgettriage` exists in several places, Claude Code runs the enterprise skill over the personal one and the personal one over the project one, and Codex does not merge same-named skills (both can appear in its selectors). The documentation of neither tool describes a warning for a duplicate, so check which copy is being loaded if you installed more than once. Both tools document automatic change detection (Claude Code: run `/reload-skills` if the skills directory is new; Codex: restart if an update does not appear).

Installing the skill does not install WidgetTriage itself. The skill first checks whether a `widgettriage` command is on `PATH`; if it is not, it uses an executable or checkout path that you give the agent. Putting the compiled executable (`dart compile exe`, see Quick start) on `PATH` is the most reliable setup, and in read-only environments the compiled executable is preferred, because `dart run` can fail there when Dart tries to write its own telemetry file.

What was tested (small samples on synthetic fixtures, one run per case, so these are observations and not rates; made with an earlier version of the skill's description, so they do not measure the current description):
- **Claude Code 2.1.326** (`claude-sonnet-5-5`): on three prompts about a widget problem that did not name the tool, the skill was called by the agent itself in 3 of 3, and in 0 of 2 prompts about unrelated problems (a Flutter overflow, a React error). With the current instructions the CLI ran in 3 of 3 cases and reported the expected `WF2001`, `WF2003` and `WF5001`; with the earlier instructions it ran in 0 of 6 runs (two rounds of three).
- **Codex CLI 0.167.1:** with the earlier instructions, the agent read the skill file and ran the CLI in 3 of 3 widget prompts, with the expected codes. Whether Codex lists this skill and selects it on its own was not tested, and the current instructions were not tested with Codex.
- Automatic selection is not guaranteed in other agents, versions or projects; invoke the skill explicitly if it is not picked up.

## Verifying a built APK / IPA (`verify`)

```sh
dart run bin/widgettriage.dart verify --json build/app/outputs/flutter-apk/app-release.apk
```

`verify` reads a built `.apk` or `.ipa` (read-only, nothing is extracted or executed) and reports `WF6xxx` (APK) / `WF7xxx` (IPA) findings in the same JSON shape. APK checks cover the final manifest, provider XML and `initialLayout` resolved through `resources.arsc`; IPA checks cover the bundle structure, extension `Info.plist` files (XML and binary) and bundle id / minimum OS. Code signing, entitlements and App Groups are not checked. **IPA verification is Experimental**: it is tested only with synthetic archives (no real Apple build), and its two convention-based rules (WF7002, WF7004) are warnings. Contract, limits and exit codes: [docs/verify-contract.md](docs/verify-contract.md).

## Limitations

- **Static analysis only.** `doctor` is source-only (no Gradle build, emulator or device); `verify` reads a built APK/IPA but only the items listed in docs/verify-contract.md. A clean report means
  none of the checks above fired; it does not prove the widget works.
- **iOS support is new and less verified than Android.** It rests on the Xcode project file, `.xcconfig` files, XML
  plists and Swift sources read statically (the tool itself runs without macOS). It was checked once against a real Xcode 26.6 project
  with a WidgetKit extension that installed and showed its widget in an iOS 26.5 simulator, and the rules reported the faults
  introduced there ([docs/ios-validation.md](docs/ios-validation.md)). Not run: real IPA, App Group runtime sharing, Release builds,
  physical devices, the widget gallery list capture. The Apple documentation pages that could be read do not state several of the values used
  (extension point identifier, App Group entitlement key, bundle identifier prefix, iOS 14 minimum); each iOS rule page
  says so. Build settings are resolved per configuration (Debug/Release), including `.xcconfig` includes; anything that cannot
  be resolved, binary plists, Swift packages and unsupported source trees produce notes, not findings. An app without a
  WidgetKit extension gets a note, not an error; a widget without App Groups is accepted. Not covered: Live Activities,
  App Intents configuration, widget kind/provider structure, `home_widget` iOS setup beyond a literal App Group id.
- Android: Native classes are read with a small Kotlin/Java declaration reader (comments and strings
  ignored; `package`/`import` and inheritance inside the project are followed). Chains that leave the project
  are "unknown" and never reported. Relative manifest names need a readable `namespace`; without it, same-named
  classes cannot be told apart and are not reported. The merged manifest is not computed: only the manifests of
  the project's own source sets are read (see [WF2001](docs/errors/WF2001.md)).
- WF4001/WF4002 handle a single string literal (or `io.flutter.Entrypoint` meta-data) as the entrypoint name and
  do not follow the Dart import graph; a Dart file that `main` never imports is not part of the compiled app
  (see [WF4001](docs/errors/WF4001.md)). Cached engines and Intent extras are not seen.
- Source sets and variants: WidgetTriage does not select a build variant. Receivers that exist only in a non-main
  source set (debug, release, a flavor) are checked on their own and listed in `notes` as variant-dependent;
  `tools:node="remove"` markers are reported as notes. `notes` also records a Dart entrypoint library that
  `lib/main.dart` never imports. A report without such notes does not prove every variant is covered.
- WF2004 reads a numeric `targetSdk` from `android/app/build.gradle(.kts)`; below 31 it is not reported.
- WF1001 accepts the classes that are `@RemoteView`-annotated in `android.jar` (API 34-36) and flags the rest,
  including `<Space>` and `<View>`. `<requestFocus/>` and `<tag/>` are not judged. It does not interpret
  resource qualifiers and does not prove that inflation succeeds ([WF1001](docs/errors/WF1001.md)).
- Android: nothing was verified on an emulator or device. iOS: one simulator run only, see [docs/ios-validation.md](docs/ios-validation.md); no physical device.
- The projects in `fixtures/` reproduce the *configuration shape* of each error and are checked by the
  test suite; they have not been built with the Android toolchain.

## Planned (not implemented)

- Deeper iOS checks (Live Activities, App Intents, widget kinds/providers) and a finding (today only a note) for a missing `.appex` in IPA output.
- Deeper artifact inspection: `.aab` / split APKs, RemoteViews layout contents inside an APK, IPA code signature / entitlements / App Groups (Mach-O), and verification of IPA checks against a real Apple build (not run yet).
- A finding-confidence model (confirmed / suspected / not checked) and a distinct "incomplete" exit code.
- `info` diagnostics, and warning-level findings beyond WF7002 / WF7004.
- MCP integration; optional automatic fixes.
- Release on pub.dev.

## Development

```sh
dart pub get
dart analyze
dart test
```

`test/cli_stdout_contract_test.dart` checks the stdout/stderr/exit-code contract for `dart run` and for a compiled
executable. An opt-in group characterizes the SDK launcher issue above without failing on it; run it with
`WIDGETTRIAGE_TEST_GLOBAL_LAUNCHER=1 dart test test/cli_stdout_contract_test.dart` (see the header of that file).

To contribute a rule or report a false positive, start from a minimal standalone reproducer and include
the Flutter version, Android SDK/AGP version, observed vs expected behaviour and a log excerpt with
sensitive details removed. A new rule needs a failing fixture, a corrected fixture, a regression test,
a schema entry and a `docs/errors/<code>.md` page.

## License

WidgetTriage is released under the [MIT License](LICENSE) (SPDX: `MIT`), Copyright (c) 2026 z0rimo.
You may use, copy, modify, merge, publish, distribute, sublicense and sell it, including for commercial
purposes, free of charge, provided the copyright notice and the permission notice in [LICENSE](LICENSE) are included
in all copies or substantial portions. The software is provided "as is", without warranty of any kind.
Third-party dependencies are not part of this repository and keep their own licenses; their notices (and the Dart SDK notice needed when distributing a compiled executable) are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). That file has not had a legal review.
