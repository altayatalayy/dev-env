# Code Analysis (earlier pass)

> Superseded by [CODE_REVIEW.md](CODE_REVIEW.md). Kept for the record of what
> that pass changed. Two of its "noted, not changed" items have since been
> acted on: the `release.json` sidecar was removed, and the `zig-cli` /
> `zig-graph` dependency declaration is still the blocker described there.

Review of the project against [CODING_GUIDELINES.md](CODING_GUIDELINES.md),
covering the Zig sources, shell scripts, Dockerfiles, tests, and release/CI
setup. Scope: readiness to publish to GitHub and install from GitHub Releases.

## Summary

The codebase already follows the guidelines closely: tagged unions for
behavior-carrying variants, explicit error unions, small focused modules, no
global mutable state, `std.log` logging, deterministic tests with cleanup, no
`set -euo pipefail`, no `TODO`/`FIXME`, no dead-code dumps. The fixes below
close real gaps found during review.

## Fixed

- **Tests silently not running.** `src/dev_env/main.zig`'s test-discovery block
  omitted `host_detect.zig` and `installer_client.zig`, whose tests are not
  reachable from the analyzed code paths. Five tests were never executed.
  Added the missing imports (plus `paths`, `clean`, `uninstall` for
  completeness). Test count went from 109 to 114, all passing.
- **Bash `$?` checks (SC2181).** Project-wide, command results were checked with
  `VAR="$(...)"; if [ $? -ne 0 ]`. The guideline requires `if ! VAR=...`.
  Converted across `install.sh`, `release/*.sh`, and all `test/**/*.sh`.
- **Installer not GitHub-native.** Added `--github <owner/repo>` to `install.sh`,
  resolving the latest tag from the GitHub API and assets from
  `releases/download/<tag>/`. The generic `--release-root-url` path is retained
  for self-hosted servers and the e2e harness.
- **Accidental state deletion.** `install.sh --uninstall` did an unconditional
  `rm -rf` of the data dir. It now refuses directories that do not look like
  dev-env state, and requires an interactive confirmation or `--yes`.
- **Missing CI/CD.** Added `.github/workflows/ci.yml` (fmt, test, build,
  shellcheck) and `release.yml` (build artifacts, publish to GitHub Releases).
- **`.shellcheckrc`** disables SC1091 for the runtime-resolved `common.sh`
  source path, so shellcheck is clean in CI.
- **README** updated to document GitHub install, the dependency layout, build and
  test commands, and CI/CD.

## Noted, not changed

- **Unused `release.json` sidecar.** `install.sh` writes
  `installers/<version>/release.json` with `tag_name` and `release_root_url`, but
  nothing reads it. It is plausibly reserved for a future network upgrade flow;
  left in place. Remove it if that flow is not planned.
- **Thin client wrappers.** `src/dev_env/installer_client.zig` has one wrapper
  per protocol command. They are not pure forwarders — each binds a distinct
  request/response type and command tag — so they are kept.

## Tests

No duplicate test names, no tautological assertions, and no redundant tests were
found. Coverage is behavior-oriented: resolution and ordering
(`installer/resolver.zig`), plan shaping per package manager
(`installer/planner.zig`), config conflict classification and backup/skip
policies (`dev_env/configs.zig`), and failure paths throughout.

## Verification

- `zig fmt --check src build.zig` — clean
- `zig build` — succeeds
- `zig build test` — 114/114 pass
- `shellcheck` over all scripts — clean
- Fake e2e suite (`test/scripts/test-container.sh`, ubuntu-24.04) — passes:
  platform, smoke, exports, plan-change, apply-idempotent, upgrade-downgrade,
  config-conflicts, doctor, clean-uninstall, protocol-failure.

## Follow-ups for publishing

- Declare `zig-cli` and `zig-graph` as URL dependencies in `build.zig.zon` (the
  workflows assume `zig build` fetches them). Until then, keep them as sibling
  checkouts for local builds.
- The containerized e2e flow (`test/scripts/test-container.sh`,
  `containers/test/Dockerfile.builder`) still passes the dependencies as Docker
  build contexts from sibling directories. Update it alongside the URL-dependency
  migration, then it can be re-added as a CI job.
