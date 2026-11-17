# Contributing to WidgetForge

Thanks for helping. WidgetForge is a read-only static diagnostics CLI; accuracy and honest scope matter more than coverage.

## Before you open anything
- Search existing issues. For a vulnerability, follow [.github/SECURITY.md](.github/SECURITY.md) and do not file a public issue.
- Use the issue forms: bug, false positive / false negative, rule request, installation problem.
- Never attach secrets, private keys, tokens, company or customer code, or personal data. Reduce your case to a minimal synthetic project.

## Development
Requires a Dart SDK satisfying `environment.sdk` in `pubspec.yaml` (maintainer testing was done on Dart 3.8.0; 3.5.4 was run once; 3.5.0 itself was not tested).

```sh
dart pub get
dart analyze
dart test
```

Both `dart analyze` and `dart test` must pass. Do not delete or skip tests to make them pass.

This repository has **no automated CI**: nothing runs on a pull request by itself, and a green check is not available. The maintainer runs `dart analyze` and `dart test` locally before every change. Contributors run them too and report the actual results in the pull request; anything you did not run is written as **NOT RUN**.

## Changing behaviour
- Rule IDs are stable: never renumber or reuse a code, and do not change the meaning of an existing one.
- The JSON report (`schema/diagnostic-report.schema.json`, `schemaVersion "1"`) and exit codes 0/1/2 are a contract; changes need a clear compatibility note in the pull request and in `CHANGELOG.md`.
- A finding must name the file, line (or `null` when no single line applies) and the literal evidence. Static analysis does not prove runtime behaviour; keep documentation claims within what was verified.

## Adding a rule
1. Pick the next free code in its family (1xxx RemoteViews, 2xxx manifest receiver, 3xxx provider XML, 4xxx FlutterActivity entrypoint, 5xxx iOS WidgetKit, 6xxx APK `verify`, 7xxx IPA `verify`). Check it is not already used.
2. Implement the check under `lib/src/checks/` (or `lib/src/artifact/` for `verify`) and register it.
3. Add a failing fixture `fixtures/err_<name>` that triggers exactly that code (copy `ok_basic`, break one thing) and, where useful, an `ok_<name>` fixture for the boundary case. Fixtures must be synthetic; do not copy real apps or third-party sample code.
4. Add the expectation (code, file, line, evidence) to the tests (`test/doctor_test.dart`, `test/accuracy_test.dart`, `test/ios_test.dart` as appropriate).
5. Add the entry to `schema/rule-catalog.json` and write `docs/errors/WFxxxx.md` (symptom, cause, detection scope, fix, fixture). Add the row to the README rule table and cover the code in `skills/widgetforge/SKILL.md`.
6. Run `dart analyze` and `dart test`: `test/catalog_test.dart` checks that the catalog, the code, the docs pages, the README table and the skill agree.

## Pull requests
- Keep them small and focused; fill in the template, including the verification you actually performed.
- Commit messages: describe the change itself. Do not add tool or co-author trailers on anyone's behalf.
- By contributing you agree that your contribution is licensed under the repository's [MIT License](LICENSE).
