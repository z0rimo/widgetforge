# WidgetTriage

**Read-only diagnostics for Flutter home screen widgets on Android and iOS. Find widget setup mistakes before runtime, with structured JSON output for coding agents.**

[Latest release](https://github.com/z0rimo/widgettriage/releases/latest) · [Changelog](CHANGELOG.md) · [MIT License](LICENSE) · Dart SDK 3.5+ · [Issues](https://github.com/z0rimo/widgettriage/issues)

- **Diagnose widget setup quickly.** One command checks the Android (AppWidget / RemoteViews, manifest, provider XML, Flutter entrypoints) and iOS (WidgetKit extension, plists, entitlements, App Groups) wiring that is spread over many files, and names the file, line, evidence and a fix for each finding (29 rules, `WF1001`-`WF7004`).
- **Read-only.** It never modifies the project it inspects, and it does not build or run anything.
- **Made for coding agents too.** Stable JSON on stdout (`--json`), exit codes 0/1/2, and an optional skill for Codex and Claude Code. You do not need an agent to use the CLI.

It is a *static* tool: it does not render a widget, run the app, test on a device, find every runtime failure, or fix anything automatically. See [Limitations](#limitations).

> WidgetTriage was formerly known as WidgetForge. The project was renamed in v0.2.0. Existing v0.1.0 releases and diagnostic codes remain preserved.

> **Status: v0.3.0.** Not published to pub.dev; install from GitHub as below. Android checks are the most verified; iOS rules were exercised on one Xcode 26.6 / iOS 26.5 simulator sample ([docs/ios-validation.md](docs/ios-validation.md)); IPA verification is Experimental. Licensed under the [MIT License](LICENSE).

## Quick start

**Prerequisites:** a Dart SDK, 3.5 or newer (verified with 3.8.0 on Linux; see [Running it: what has been verified](#running-it-what-has-been-verified)), and `git`.

**1. Install the CLI** from the `v0.3.0` tag (one line, works in Bash and PowerShell):

```sh
dart pub global activate --source git https://github.com/z0rimo/widgettriage.git --git-ref v0.3.0
```

Make sure pub's executable directory is on your `PATH` (`dart` prints the exact directory if it is not): usually `$HOME/.pub-cache/bin` on Linux and macOS and `%LOCALAPPDATA%\Pub\Cache\bin` on Windows. Then check it:

```sh
widgettriage --version
```

**2. Diagnose a Flutter project.** Run it in the project root (it needs `pubspec.yaml` and an `android/` and/or `ios/` project), or pass the path:

```sh
widgettriage doctor --json /path/to/flutter_project
```

Leave out `--json` for a human-readable report. Exit code `0` means no errors were reported, `1` means errors were found, `2` means a usage error or unusable input (message on stderr, no JSON).

**3. Read the result.** For a project with a missing `android:exported` on a widget receiver, `widgettriage doctor` prints (real output from the repository's synthetic fixture `fixtures/err_receiver_missing_exported`, path line shortened):

```text
WidgetTriage doctor: <project>

[ERROR] WF2004 Widget receiver with intent-filter lacks android:exported
  at android/app/src/main/AndroidManifest.xml:16
  evidence: <receiver android:name=".DemoWidgetProvider"> (no android:exported)
  Apps targeting Android 12 (API 31) or higher must set android:exported explicitly on every component with an intent-filter; ...
  fix: Add android:exported="true" to this <receiver>.
  docs: docs/errors/WF2004.md

1 error(s), 0 warning(s).
```

(exit code 1; the long explanation line is shortened here). A clean project prints `0 error(s), 0 warning(s).` and exits 0, which only means the implemented checks found nothing. The `--json` form of both cases is under [Example output](#example-output); how to read it is under [How to read a result](#how-to-read-a-result).

**4. Optional: install the Agent Skill** for Codex and/or Claude Code. This is a separate step from the CLI: the skill only tells your agent when and how to call `widgettriage`. It needs a checkout of this repository, because the installer copies the skill from it:

```sh
git clone https://github.com/z0rimo/widgettriage.git
cd widgettriage
dart pub get
dart run scripts/install_agent_skill.dart --agent both --scope project --project /path/to/flutter_project --dry-run
```

`--dry-run` only shows what would happen; run the same command without it to install into `<project>/.agents/skills/` (Codex) and `<project>/.claude/skills/` (Claude Code). Use `--agent codex` or `--agent claude` for one agent. An existing different copy is reported as a `CONFLICT` and left untouched unless you pass `--force`. Installing into your home directory (`--scope user`) is possible but changes settings shared by all your projects, so try a single project first. Details, paths and the name-collision note: [AI agent integration](#ai-agent-integration).

### Install from a checkout instead

Useful for development, or if you prefer a single executable that an agent can be pointed at:

1. `git clone https://github.com/z0rimo/widgettriage.git && cd widgettriage && dart pub get`
2. Optional: `mkdir -p build && dart compile exe bin/widgettriage.dart -o build/widgettriage` and put `build/` on your `PATH` (or remember its full path).
3. `dart run bin/widgettriage.dart doctor --json /path/to/flutter_project` (or `build/widgettriage doctor --json /path/to/flutter_project`).

## What it checks

- **Android:** `RemoteViews` widget layouts, `AppWidgetProvider` receivers and their provider XML, `AndroidManifest.xml` wiring (including `android:exported`), and the Dart entrypoints of separate `FlutterActivity` classes.
- **iOS:** WidgetKit extension targets in the Xcode project (`project.pbxproj`): embedding in the app, the extension `Info.plist`, bundle identifier prefix, entitlements and App Groups, the `@main` entry point and the deployment target.
- **Built APK / IPA (`verify`):** the widget metadata inside a finished `.apk` (stable) or `.ipa` (Experimental). See [Verifying a built APK / IPA](#verifying-a-built-apk--ipa-verify).

Such mistakes are commonly associated with a widget that does not load, a widget missing from the launcher's picker or widget gallery, manifest-merger or signing/validation errors, or a blank secondary `FlutterActivity`; WidgetTriage does not observe those symptoms at runtime. Android-only, iOS-only and combined Flutter projects are supported; a platform whose project files do not exist is simply not checked. It does not replace [`home_widget`](https://pub.dev/packages/home_widget), does not depend on any widget package and also works for hand-written native widgets. The full list of rules is under [What it detects](#what-it-detects).

## Requirements and what has been verified

Requires a Dart SDK that satisfies `environment.sdk` in `pubspec.yaml` (`^3.5.0`, i.e. Dart 3.5 or newer and below 4.0). Without `--json` a human-readable report is printed. `path` defaults to the current directory and must be a Flutter project root: it needs `pubspec.yaml` and at least one platform project, `android/app/src/main/AndroidManifest.xml` and/or `ios/*.xcodeproj/project.pbxproj`. `dart run bin/widgettriage.dart --help` and `--version` show usage and the version.

### Verified for v0.3.0 (current)

Release commit `0fb1309` (tag `v0.3.0`). "Not run" means exactly that, not "passes".

| Environment | Run for v0.3.0 | Not run |
|---|---|---|
| **Linux (WSL2), Dart 3.8.0**, fresh clones | `dart pub get`, `dart analyze` (clean), `dart test` (347 passed, 6 skipped, 0 failed); all 78 fixture projects give the same `doctor` output as v0.2.0 apart from `tool.version`; compiled executable (`--version`, `doctor`; `verify` was run through `dart run`); `dart pub global activate --source git ... --git-ref v0.3.0` into a temporary pub cache (`widgettriage --version` = `0.3.0`, single JSON document on stdout, exit codes 0/1/2); agent skill installer scenarios (project and user scope, dry-run, re-install, conflict, `--force`, symlink conflict, partial failure) | other Dart versions |
| **Windows 10.0.26100, PowerShell 5.1, Dart 3.8.0** | the same one-line git activation with `--git-ref v0.3.0`, `widgettriage --version`, `doctor --json` (exit 1 with `WF2004`, empty stderr) and a missing path (exit 2); the skill installer scenarios and its test file (37 passed, 8 skipped) were run earlier on the installer code that v0.3.0 ships unchanged | full `dart test`, `verify`, a compiled executable, symbolic-link scenarios (skipped: no symlink privilege) |
| **macOS** | - | everything (NOT RUN) |
| Dart 3.5.0 to 3.7.x | - | NOT RUN for v0.3.0 (a Dart 3.5.4 run of the v0.1.0 test suite is under "Earlier verification records") |
| Agent skill selected by a model | - | NOT RUN for the current skill description |

### Running it: what has been verified

With `--json`, stdout must be exactly one JSON document; errors and usage messages go to stderr.
Rows 1-3 were verified to meet that for v0.3.0 on Linux (Dart 3.8.0); the git row also on Windows PowerShell as stated; the last two rows are not suitable or not verified.

| How | Status |
|-----|--------|
| `dart run bin/widgettriage.dart ...` | **Verified** on Linux. The supported development path. |
| Native executable (JSON automation) | **Verified** on Linux. Build once, then call the binary directly: `dart pub get && mkdir -p build && dart compile exe bin/widgettriage.dart -o build/widgettriage`, then `build/widgettriage doctor --json <path>`. Same stdout and exit codes as `dart run`. |
| `dart pub global activate --source git https://github.com/z0rimo/widgettriage.git --git-ref v0.3.0` | **Verified for the `v0.3.0` tag** on Linux (temporary pub cache, resolved ref = release commit) and, for `--version`, `doctor --json` and a missing path, on Windows PowerShell (Dart 3.8.0). Not run on macOS or with other SDK versions; check that stdout is one JSON document before relying on it. |
| `dart pub global activate --source path .` | **Not recommended for `--json`.** On Dart SDK 3.8.0 the generated launcher can print pub's `Resolving dependencies...` output to stdout in front of the JSON (see below). |
| pub.dev (`dart pub global activate widgettriage`) | **Not available.** The package is not published; no behaviour is guaranteed. |

### Earlier verification records (historical)

Kept as written for the release they describe; they were not repeated for later releases.

- **WidgetForge v0.1.0** (entry point `bin/widgetforge.dart`): main verification on Dart 3.8.0 (Flutter 3.32.0) on Linux from a fresh clone (`dart pub get`, `dart analyze`, `dart test`, `dart run bin/widgetforge.dart doctor --json <project>`). On Dart 3.5.4 (Linux) `dart analyze` was clean and all 302 tests of that release passed once; Dart 3.5.0 itself and other platforms were not tested. Git-source activation was then only checked against a throw-away local repository (clean JSON, 3 consecutive runs, Dart 3.8.0).
- **WidgetTriage v0.2.0** (the rename): git activation from `main` at `93d9fa8` on Linux with Dart 3.8.0 into a temporary pub cache printed `widgettriage 0.2.0` and wrote a single JSON document to stdout; not verified on macOS or Windows at that time.

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

WidgetTriage v0.3.0 is a static diagnostic tool for Android and iOS projects. Read the JSON in this order:

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
  "tool": { "name": "widgettriage", "version": "0.3.0" },
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

`--agent` is `codex`, `claude` or `both` (default `both`); `--scope` is `project` (default) or `user`. It copies files from the checkout (no download, nothing runs on `dart pub get`), reports each agent separately (`INSTALLED`, `ALREADY INSTALLED`, `CONFLICT`, `FAILED`) and exits 1 if any target conflicted or failed. An existing different copy is never overwritten unless you pass `--force`, which replaces only that file inside the `widgettriage` skill directory and keeps the old one as `SKILL.md.bak`; symbolic links at the target are never followed or replaced. Check the result by looking at the printed paths, then start a new agent session.

- **Home directory (`--scope user`):** the first of `HOME`, then `USERPROFILE`, that is an existing directory is used (on Windows it must also be a drive-letter or UNC path, so a POSIX-style `HOME` such as `/home/user` is skipped). Nothing is created; if neither is usable the script stops with an error.
- **Parent-directory symbolic links are followed.** If `.agents` or `.claude` (or a directory above the skill folder) is a symlink, for example to a shared dotfiles folder, the skill is installed where the link points, and the output says so. Installing there is your explicit request; existing files are still protected as described above. A symlink at the `widgettriage` folder itself is always a `CONFLICT`.
- Windows PowerShell example: `dart run scripts\install_agent_skill.dart --agent both --scope project --project C:\path\to\flutter_project`.

Tested on Linux and on Windows (10.0.26100, Windows PowerShell, Dart 3.8.0). On Windows the symbolic-link scenarios were skipped because creating symlinks there needs an elevated or developer-mode account. macOS: not run.

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

## FAQ

**Does WidgetTriage modify my project?** No. `doctor` and `verify` only read files. The optional skill installer writes only inside the `widgettriage` skill folder of the agent directory you choose (see [AI agent integration](#ai-agent-integration)).

**Do I need an AI agent to use it?** No. The CLI runs on its own and prints a human-readable report, or JSON with `--json`. The agent skill is optional.

**Does it support both Android and iOS?** Yes, as static checks of the project files; iOS is newer and less verified (one Xcode / simulator sample). See [Limitations](#limitations).

**Can it check a built APK?** Yes: `widgettriage verify --json app-release.apk` checks the widget metadata in the final manifest and resources (WF6xxx). `.ipa` support is Experimental and was tested with synthetic archives only; `.aab` is not supported.

**Why exit code 1 or 2?** `1` means at least one `error` diagnostic was reported; the JSON on stdout says which. `2` means the tool could not do its job (bad arguments, not a Flutter project root, or an unsupported or unsafe archive); the reason is on stderr and there is no JSON. Warnings and notes never change the exit code.

**Is it on pub.dev?** No. Install it from GitHub as shown in the [Quick start](#quick-start).

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

## Links

[Releases](https://github.com/z0rimo/widgettriage/releases) · [Changelog](CHANGELOG.md) · [Agent skill](skills/widgettriage/SKILL.md) · [Rule pages](docs/errors/) · [Rule catalog](schema/rule-catalog.json) · [JSON Schema](schema/diagnostic-report.schema.json) · [Contributing](CONTRIBUTING.md) · [Security policy](.github/SECURITY.md) · [Issues](https://github.com/z0rimo/widgettriage/issues) ([report a problem or idea](https://github.com/z0rimo/widgettriage/issues/new/choose))

## License

WidgetTriage is released under the [MIT License](LICENSE) (SPDX: `MIT`), Copyright (c) 2026 z0rimo.
You may use, copy, modify, merge, publish, distribute, sublicense and sell it, including for commercial
purposes, free of charge, provided the copyright notice and the permission notice in [LICENSE](LICENSE) are included
in all copies or substantial portions. The software is provided "as is", without warranty of any kind.
Third-party dependencies are not part of this repository and keep their own licenses; their notices (and the Dart SDK notice needed when distributing a compiled executable) are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). That file has not had a legal review.
