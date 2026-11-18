# Changelog

## Unreleased

- Agent Skill: the `description` in `skills/widgettriage/SKILL.md` was rewritten (shorter, states when to use it and what it does not do). Earlier skill-selection observations were made with the previous wording. `name` is unchanged.
- New `scripts/install_agent_skill.dart` installs the skill for Codex and/or Claude Code (project or user scope, `--dry-run`, `--force`); tests in `test/install_agent_skill_test.dart`. No change to the CLI, the 29 rules, the JSON report or exit codes.

## 0.2.0

Rebrand release: WidgetForge is now **WidgetTriage**. No diagnostic logic changed.

- Renamed: GitHub repository `z0rimo/widgetforge` -> `z0rimo/widgettriage` (GitHub redirects the old URL), Dart package and CLI executable `widgetforge` -> `widgettriage`, Agent Skill `widgetforge` -> `widgettriage` (`skills/widgettriage/SKILL.md`), `bin/widgettriage.dart`, `lib/widgettriage.dart`, and the opt-in test environment variables `WIDGETFORGE_*` -> `WIDGETTRIAGE_*`.
- JSON report: `tool.name` is now `"widgettriage"` and `tool.version` is `"0.2.0"`. **Consumers that compare `tool.name` to `"widgetforge"` must accept the new value.** The product name inside free-text `notes` and `message` strings and the human-readable output also changes (verified over all fixtures: output is identical to 0.1.0 once "WidgetForge" is read as "WidgetTriage"). `schemaVersion` stays `"1"`; the schema's `tool.name` constant and `$id` follow the new name.
- Unchanged: the 29 rules and their IDs (`WF1001`-`WF7004`), severities, exit codes 0/1/2, findings structure, fixtures and test expectations.
- Upgrade: replace `widgetforge` with `widgettriage` in commands (`dart run bin/widgettriage.dart doctor --json <project>`), in `.claude/skills/` or `.agents/skills/` (copy `skills/widgettriage/`), and in any script that reads `tool.name`. No `widgetforge` alias is kept. Still not published to pub.dev (`publish_to: none`).
- The v0.1.0 tag and Release are preserved as published; the history below is kept under its original name.

## 0.1.0

First implementation. Not published to pub.dev (`publish_to: none`).

- Report schema: `diagnostics[].code` is validated by the pattern `^WF[0-9]{4}$` instead of an enum (it no longer checks that an ID exists); `schemaVersion` stays `"1"`. New `schema/rule-catalog.json` lists the 29 implemented rules and is checked against the code, `docs/errors/` and the README by tests.
- WF7002 and WF7004 (IPA `verify`) have `warning` severity (exit code unchanged) with the unverified basis stated in their message and evidence; IPA verification is Experimental.
- `widgetforge verify [--json] <file.apk|file.ipa>` (read-only, pure Dart, bounded ZIP reader): diagnostics WF6001-WF6005 (APK) and WF7001-WF7004 (IPA), docs in `docs/verify-contract.md`. APK checks were compared once with `apkanalyzer`/`aapt2` on real builds; the committed APK test fixtures are small `aapt2`-built archives (`test/tool/make_apk_fixtures.sh`) with narrower coverage; IPA checks tested with synthetic archives only (no Apple build).
- `widgetforge doctor [--json] [path]` (read-only; Android and iOS, in Android-only, iOS-only and combined projects) with exit codes 0/1/2.
- Diagnostics WF1001, WF2001-WF2004, WF3001-WF3004, WF4001-WF4003.
- JSON report `schemaVersion: "1"` and `schema/diagnostic-report.schema.json`.
- Fixtures and automated tests.
- Per-code troubleshooting pages under `docs/errors/`.
- `test/cli_stdout_contract_test.dart`: stdout/stderr/exit-code contract for `dart run` and a compiled executable;
  opt-in characterization of the Dart SDK 3.8.0 path-launcher stdout issue (not a WidgetForge defect).
- Documented verified run paths and the known path-launcher limitation in README and SKILL.
- License: MIT (`LICENSE`, Copyright (c) 2026 z0rimo).
- Accuracy fixes (rule IDs, JSON schema and exit codes unchanged):
  - WF5001/WF5003/WF5007: the reported `line` is the widget target's own declaration in `project.pbxproj` (found by object id), not a same-named `PBXGroup`.
  - WF2001/WF4003: classes are read by a declaration reader instead of a regular expression; comments/strings,
    abstract and base classes no longer produce findings; constructor arguments, indirect subclasses and
    same-named classes in other packages are handled; receivers/activities in other source-set manifests count.
  - WF4001/WF4002: overrides are scoped to their own class, findings are deduplicated, only a plain string literal is
    trusted, `getDartEntrypointLibraryUri()` and `io.flutter.Entrypoint(Uri)` meta-data are honored, declarations are
    matched per top-level function (same-line pragma, comments/blank lines before the declaration).
  - WF1001: `AbsoluteLayout` is accepted, `<requestFocus/>`/`<tag/>` are not judged, `<ViewStub android:layout>` is
    followed, `<view class="...">` is judged by its class, qualified names are matched exactly, XML comments no longer
    disturb line numbers; the message no longer quotes unobserved launcher text.
  - 27 new fixtures, `test/accuracy_test.dart` (exact code/file/line/evidence, schema validation, goldens) and
    `test/source_parsers_test.dart`.
- Pre-release accuracy gate (rule IDs, JSON schema and exit codes unchanged):
  - Receivers declared only in another source set are now checked on their own (WF2002-WF2004, WF3xxx, WF1001) and
    reported in `notes` as variant-dependent; `tools:node="remove"` is a note, not a declaration.
  - WF2004 respects a numeric `targetSdk` below 31.
  - WF3004 compares fully-qualified class names (namespace-aware) instead of simple names; message states the documented basis.
  - A Dart entrypoint library not reachable from `lib/main.dart` through import/export/part is reported in `notes`.
  - 11 more fixtures, extended `test/accuracy_test.dart`.
- Release metadata: `repository` in `pubspec.yaml` and the JSON Schema `$id` now use the GitHub location
  (`https://github.com/z0rimo/widgetforge`, `.../v0.1.0/schema/diagnostic-report.schema.json`). The `$id` resolves only once
  the `v0.1.0` tag exists. `publish_to: none` is unchanged.
- `docs/errors/WF1001`, `WF2004`, `WF3004`: Android documentation sources added; runtime-symptom wording aligned with the README.
- iOS WidgetKit static diagnostics WF5001-WF5008 (embedding, extension Info.plist, bundle identifier prefix, entitlements,
  App Groups, `@main`, deployment target) from `project.pbxproj`, `.xcconfig`, XML plists and Swift sources; 26 iOS/combined
  fixtures, `test/ios_test.dart`. Schema: eight new `code` values only. Validated on one Xcode 26.6 / iOS 26.5 simulator sample (see below); not on real IPAs or devices.
- Android-only projects produce the same report as before; the `--help` options `--help`/`--version` now have descriptions.
- `docs/ios-validation.md`: record of one Codemagic macOS 26.5.1 / Xcode 26.6 / iOS 26.5 simulator run of a Flutter + WidgetKit sample (build, install, launch, extension registered, widget shown on the home screen, `doctor` clean on the sample and reporting WF5001-WF5008 for faults introduced one at a time). Not run: widget gallery capture, App Group runtime sharing, real IPA / `verify` WF7001-WF7004, Release builds, devices. Rule IDs, schema and exit codes unchanged.
- `repository` and Schema `$id` metadata are unchanged; `publish_to: none` remains.
