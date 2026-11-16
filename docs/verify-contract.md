# `widgetforge verify` contract (APK / IPA artifacts)

`verify` inspects a **built** `.apk` or `.ipa`. `doctor` (source) is unchanged. Both print the same report shape
(`schema/diagnostic-report.schema.json`, `schemaVersion` `"1"`); no field was added.

```sh
widgetforge verify [--json] <file.apk|file.ipa>
```

| Exit | Meaning |
|------|---------|
| 0 | the implemented artifact checks found nothing (not a guarantee, read `notes`) |
| 1 | at least one `error` (`WF6xxx` / `WF7xxx`), report on stdout. `warning` diagnostics (WF7002, WF7004) do **not** cause exit 1 |
| 2 | usage error, or the file is not a supported archive, is unsafe (limits below) or unreadable; message on stderr, **no stdout** |

## Report differences from `doctor`

- `projectPath` is the artifact path as given; `diagnostics[].file` is the path **inside the archive** (`AndroidManifest.xml`, `res/xml/x.xml`, `Payload/App.app/PlugIns/W.appex/Info.plist`); `line` is `null`.
- `checksRun` is `apk-widget-artifact` or `ipa-widget-structure`.
- Source rules (`WF1xxx`-`WF5xxx`) are never emitted by `verify`, artifact rules (`WF6xxx` APK, `WF7xxx` IPA) never by `doctor`. The `code` field is validated by pattern (`^WF[0-9]{4}$`), see [diagnostic-contract.md](diagnostic-contract.md); the rule list is in [`schema/rule-catalog.json`](../schema/rule-catalog.json).
- The type is decided from contents, not the extension: `AndroidManifest.xml` at the root = APK, `Payload/<name>.app/` = IPA. `.aab`, a second `.app`, or an archive that is both are rejected (exit 2).

## Rules

| Code | Meaning |
|------|---------|
| [WF6001](errors/WF6001.md) | final manifest: widget receiver without `android:exported` at targetSdk >= 31 |
| [WF6002](errors/WF6002.md) | widget receiver without `android.appwidget.provider` meta-data |
| [WF6003](errors/WF6003.md) | provider XML named by the meta-data is missing (resolved through `resources.arsc`) |
| [WF6004](errors/WF6004.md) | provider XML has no `android:initialLayout` |
| [WF6005](errors/WF6005.md) | `initialLayout` resource has no layout file |
| [WF7001](errors/WF7001.md) | Info.plist (app or extension) missing, unparseable, or missing a required key |
| [WF7002](errors/WF7002.md) | **warning**: widget extension bundle id not prefixed `<app id>.` (unverified convention) |
| [WF7003](errors/WF7003.md) | widget extension `CFBundleExecutable` missing from the archive |
| [WF7004](errors/WF7004.md) | **warning**: widget extension `MinimumOSVersion` < 14 (failure below 14 unverified) |

Source vs. artifact: `WF2003`<->`WF6002`, `WF3002`<->`WF6004`, `WF3003`<->`WF6005`, `WF2004`<->`WF6001`, `WF5003`<->`WF7001`, `WF5004`<->`WF7002`, `WF5008`<->`WF7004`.
A source finding that is absent from the artifact (or the reverse) points to a build variant, merger, shrinking or packaging difference; WidgetForge does not diff the two for you.

## What is not checked (always written to `notes`)

APK: layout contents (RemoteViews classes), configure activities, Dart entrypoints, signature, dex, split APKs, install/render.
IPA: code signature, provisioning, **entitlements and App Groups** (inside signed Mach-O data), Swift code, timelines, install/render.
Unresolvable or non-literal values (for example when `resources.arsc` is absent or over the read limit) become notes, never findings.
No Android SDK, Xcode or macOS is needed: archives are read in pure Dart. `apkanalyzer` / `aapt2` were used only to compare results (see "Limits of the evidence" below).

## Safety: the archive is untrusted input

Read-only; nothing is extracted to disk, nothing inside is executed. The central directory is parsed first; only a few entries are inflated into memory.

| Limit | Value | Result |
|-------|-------|--------|
| archive file size | 2 GiB | exit 2 |
| central directory entries | 65,534 (the largest count a non-ZIP64 archive can declare) | exit 2 |
| entry name length | 1,024 bytes | exit 2 |
| inflated size of `resources.arsc` | 128 MiB | skipped, note |
| inflated size of other read entries (manifest, XML, plists) | 8 MiB | exit 2 |
| compression ratio of a read entry | 1,100 : 1 | exit 2 |
| wall-clock time | 30 s, checked between read/inflate steps (not preemptive; a single inflate is bounded by the size limits) | exit 2 |

Also exit 2: not a ZIP, truncated or corrupt data, ZIP64, multi-disk, encrypted entries, duplicate paths, absolute paths, `..`, backslashes or NUL in paths, unsupported compression method for an entry that must be read. Entries that are never read are not judged. An entry that inflates beyond its declared size is cut off. For every entry that is read: the CRC-32 must match, the local header name must match the central directory, and the encrypted flag must be clear. Entry paths with empty or `.` segments are rejected (they would collide after normalization). Case-only collisions are not treated as duplicates.

**Not supported (exit 2, never a pass):** ZIP64. Because the classic end-of-central-directory record holds a 16-bit entry count, an archive with 65,535 or more entries (or any size/offset of 4 GiB or more) is rejected, even if it is a valid APK/IPA. Multi-disk archives, encryption and compression methods other than stored/deflate (for entries that must be read) are also unsupported. Measured on Linux with the compiled executable: 65,000 entries, 0.06 s / 36 MB; a 128 MiB compressed `resources.arsc`, 0.65 s / 270 MB peak; a 1 GiB unread entry, no cost.

## Basis of the IPA rules (status: Experimental)

IPA verification stays **Experimental** until it has been run against real Apple builds. Evidence classes: **A** stated on an Apple documentation page that could be read;
**B** common convention; **C** assumption checked only against synthetic archives; **D** needs a real Xcode build or install.

| Condition | Class |
|-----------|-------|
| IPA layout `Payload/<name>.app/`, extensions under `PlugIns/*.appex`, per-bundle `Info.plist` with `CFBundleIdentifier`, `CFBundleExecutable`, `MinimumOSVersion`, `NSExtension > NSExtensionPointIdentifier` | B and C; no Apple page that could be read states the IPA layout or how the containing app is identified; D for real IPAs (including Xcode's binary plists) |
| WidgetKit was introduced in iOS 14.0 | **A**: the `metadata.platforms` field of Apple's WidgetKit documentation data lists iOS `introducedAt: 14.0` (not a prose sentence; the HTML page returned only its title) |
| `com.apple.widgetkit-extension` is a valid extension point identifier | **A**: it is listed among the possible values on Apple's `NSExtensionPointIdentifier` page (JSON data form; the page describes none of the values and gives no purpose) |
| that value is what identifies a WidgetKit *widget* extension | **B** (Xcode's Widget Extension template, the value's name) and D; no readable page states the purpose. If this were wrong, widget extensions would not be recognized and a note says so: a missed check, never a false finding |
| WF7002: extension identifier must start with `<app id>.` | not stated on any readable page -> **B**, D |
| WF7004: a `MinimumOSVersion` below 14 breaks the widget extension (build or install failure) | availability is class A, but that a lower value *fails* is not stated -> **D** |

Consequences: WF7002 and WF7004 are `warning` and carry "unverified" in `message` and `evidence`; they do not change the exit code, and a user should not edit identifiers or deployment targets on this basis alone.
WF7001 and WF7003 (missing or unreadable `Info.plist`, executable absent from the archive) remain `error`: they describe the archive's own content, not an Apple rule.
Both warnings apply only to an extension recognized as a widget extension, and WF7002 only when the app's own identifier is readable.

## Limits of the evidence

APK checks were compared with `apkanalyzer` and `aapt2` on a real Flutter debug and release build (Linux). That comparison was a one-time check made earlier; it is not repeated by the test suite.

The APK files committed under `test/artifacts/` are different: they are small archives built with `aapt2` only (`test/tool/make_apk_fixtures.sh`) from manifests and resources written for this project. They contain a binary manifest, `resources.arsc` and a few XML resources, but no dex code and no merged library components. They are regression fixtures for the binary-manifest and resource-table readers, release-style resource path shortening and the receiver counts; they do **not** cover the same ground as the earlier real Flutter builds (for example, manifests merged from Flutter/AndroidX libraries), and no claim of equivalent coverage is made. IPA checks have **only synthetic-archive tests**; no real IPA was produced or inspected, and verification of IPA checks on macOS/Xcode was NOT RUN (the separate `doctor` simulator run is in [ios-validation.md](ios-validation.md)).
