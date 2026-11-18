# Security policy

## Supported versions

| Version | Supported |
|---|---|
| Latest published release | yes |
| Any older release | no; upgrade to the latest release |

The latest published release is currently v0.1.0 (published as WidgetForge). v0.2.0 (WidgetTriage) is the next planned release and becomes the supported one once it is published.

## Reporting a vulnerability

Please do **not** open a public issue, pull request or discussion with the details of a suspected vulnerability.

GitHub's private vulnerability reporting is **not enabled** for this repository at the moment, so there is no private form to point to. Until it is enabled, open a public issue titled "Security contact request" that says only that you would like to report a security problem, **without any technical details**, and a private way to continue will be arranged there. No personal e-mail address is published for this purpose.

WidgetTriage reads project folders and, with `verify`, `.apk` / `.ipa` archives that may come from untrusted sources. Reports about the following are in scope:

- crashes, hangs or unbounded memory/CPU use on a crafted archive or project;
- reading or writing outside the path that was given on the command line;
- output on stdout that breaks the documented JSON contract in a way that could mislead automation.

Out of scope: security problems of the app being inspected, and diagnostics WidgetTriage does not report (it is a static tool with documented limits).

Useful details: WidgetTriage version, Dart SDK version, a minimal reproducing archive or project, and the observed impact. Remove secrets and company code first.

WidgetTriage is maintained by an individual; no response time is promised.
