## What changed and why

<!-- One or two sentences. Link the issue if there is one. -->

## Verification performed

There is no automated CI. Paste what you actually ran and its result; write **NOT RUN** for anything you did not run.

- `dart analyze`: <result or NOT RUN>
- `dart test`: <result or NOT RUN>
- Dart SDK version / OS: <...>

## Checklist

- [ ] `dart analyze` reports no issues (as reported above)
- [ ] `dart test` passes (as reported above; no tests deleted or skipped to make it pass)
- [ ] No secrets, private keys, company code or personal data in the diff
- [ ] Existing rule IDs, severities, the JSON report contract and exit codes 0/1/2 are unchanged (or the change is described and documented)

### Only for a new or changed rule

- [ ] New diagnostic code is the next free one in its family and is not reused
- [ ] Failing fixture (`fixtures/err_...`) triggers exactly that code, plus a corrected or ambiguous `ok_...` fixture
- [ ] Test added/updated (fixture expectations with exact code, file, line and evidence)
- [ ] `schema/rule-catalog.json` entry added and `docs/errors/WFxxxx.md` written (symptom, cause, scope, fix, fixture)
- [ ] README rule table and `skills/widgetforge/SKILL.md` list the rule; `CHANGELOG.md` updated
