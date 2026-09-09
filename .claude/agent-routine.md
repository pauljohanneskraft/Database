# Agent routine policy

`CLAUDE.md` describes the project, its layout and the contracts the test suite encodes. Read it
first; this file only adds what is specific to working here autonomously.

## Eligible work

Issues labeled `agent-ready`. This project suits the agent well: pure Swift, no UI, no device
dependencies, and a real test suite, so most changes can be judged by reading the diff and the
tests.

Prefer bug fixes with a failing case, added or tightened tests, work contained within one component
from CLAUDE.md's table, and documentation of existing behaviour.

Do not attempt changes that cross the storage / buffer-manager / slotted-page / B+-tree layering, or
that alter an on-disk format, unless the issue explicitly asks for it and says how existing segment
files should be handled. Do not add third-party dependencies. Do not relax a contract from CLAUDE.md
to make a change easier — if one genuinely blocks the issue, hand the issue back and explain which.

## Verification

**You cannot build or test this project in the cloud session.** It is a Swift 6.2 package and the
session is Linux with no Swift toolchain. Do not spend a run trying to install one.

Verification happens in CI (`.github/workflows/ci.yml`, macos-15) after you push, and you read the
results with `gh pr checks` on your next run. CI runs the three commands listed at the top of
CLAUDE.md's Build / test section — lint, then `swift build --build-tests`, then
`swift test --no-parallel` — and stops at the first failure, so a lint violation means the tests
never ran.

Because CI is your only compiler, before every push:

- Re-read each changed hunk and the code around it. Confirm every symbol you used actually exists
  in this repository — do not rely on memory of an API's shape.
- Check the diff against `.swift-format` by eye. `--strict` turns every warning into an error, so
  one 121-column line fails the build before anything is compiled.
- Keep changes small. A large blind diff usually means several CI round-trips.

## Conventions

- Tests use **swift-testing** (`@Test`, `#expect`), not XCTest.
- Comments explain *why* a thing is done that way, not what the line does.

## Review

Request review from `pauljohanneskraft` when a pull request is ready.

## Concurrency

No limit on open agent pull requests. Work existing ones first — red CI, then unaddressed review
comments, then incomplete drafts — but when every open agent PR is waiting on CI or on review, start
a new `agent-ready` issue rather than stopping. A new PR is better than no development.

The `improvements` branch is several commits ahead of `main` and unpushed. Agent PRs branch from
`main`, so expect conflicts with that work until it lands.

## Human-set stop signs

`agent-blocked` on an issue or a pull request means hands off. Never add or remove it yourself.
