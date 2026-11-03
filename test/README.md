# dev-env tests

## Layout

- `zig build test`: unit/component tests embedded next to the Zig code.
- `../dev-env-lib/formal/run.sh`: Lean proofs, lifecycle failure witnesses, and
  the axiom audit ([coverage and assumptions](../docs/formal-verification.md)).
- `test/e2e/fake`: fast lifecycle tests using a protocol-compatible fake installer.
- `test/e2e/release`: heavier tests that use the real installer/tool flows.
- `containers/release`: release builder Dockerfiles.
- `containers/test`: test runner Dockerfiles.

The default matrix command runs unit/component tests once, builds the native
Linux binaries, then runs the fast fake-installer suite on:

- `ubuntu-24.04-x86_64`

```sh
test/scripts/test-container.sh
```

ARM Linux targets are still supported by the release build, but they are not part of the default test matrix because the current host cannot run ARM containers. They can be selected explicitly with `TEST_TARGETS` on a machine with working ARM/container support.

## Feature Matrix

Pure selection, diffing, protocol, and path behavior should stay in Zig unit/component tests. Full lifecycle behavior should use the fake-installer e2e suite. Real downloads, upstream installers, source builds, and bootstrap URL installs belong in release e2e or release-container tests.

Paths beginning with `dev-env-lib/` refer to the sibling library repository.

| Feature | Expected behavior | Test coverage |
| --- | --- | --- |
| CLI parsing/help/errors | Commands and flags parse consistently; invalid flags fail early. | `dev-env-lib/src/dev_env/cli.zig`, `dev-env-lib/src/installer/main.zig` unit tests |
| Installer protocol | JSON lines, progress, final responses, and protocol mismatches are rejected safely. | `dev-env-lib/src/shared/protocol.zig`; `test/e2e/fake/protocol-failure.sh` |
| Platform detection | Host OS/version/arch maps to supported platform unions. | `dev-env-lib/src/dev_env/host_detect.zig`; `test/e2e/fake/platform.sh` |
| Installer discovery | Newest compatible installer is selected; explicit release/path choices are honored. | `dev-env-lib/src/dev_env/installer_client.zig`; `test/e2e/fake/smoke.sh` |
| Plan and lock | `lock.json` records installer, platform, layout, selected tools, resolved tools, and configs. | `dev-env-lib/src/dev_env/planner.zig`; `test/e2e/fake/smoke.sh` |
| Selected tools | `--tools`, `--add`, and `--remove` update the desired selection and reject unknown tools. | `dev-env-lib/src/dev_env/planner.zig`; `test/e2e/fake/plan-change.sh` |
| Plan removal | Removing a selected tool and applying uninstalls owned tool files, removes configs, and keeps remaining tools. | `test/e2e/fake/plan-change.sh` |
| Tool environment exports | `dev-env exports` prints installed tool environment variables as `NAME=value` lines suitable for shell config consumption. | `dev-env-lib/src/dev_env/exports.zig`; `test/e2e/fake/exports.sh` |
| Apply/idempotency | Apply installs only missing tools/configs and repeated apply does not rewrite state. | `dev-env-lib/src/dev_env/apply.zig`; `test/e2e/fake/apply-idempotent.sh` |
| Config conflicts | `fail`, `backup`, and `skip` preserve user files according to policy. | `dev-env-lib/src/dev_env/configs.zig`; `test/e2e/fake/config-conflicts.sh` |
| Stow refresh/delete | Managed dotfiles are restowed, removed configs are unstowed, and stale stow links are detected. | `dev-env-lib/src/dev_env/stow.zig`; `test/e2e/fake/plan-change.sh`, `test/e2e/fake/doctor.sh` |
| Upgrade/downgrade | Upgrade chooses the newest compatible installer; explicit older plans can be applied. | `test/e2e/fake/upgrade-downgrade.sh` |
| Doctor/verify | Doctor reports host/state, runs installer verification, and fails on unhealthy tools. | `dev-env-lib/src/installer/verify.zig`; `test/e2e/fake/doctor.sh` |
| Clean | Inactive versions left by upgrades and old release state are removed without deleting active tools. | `test/e2e/fake/clean-uninstall.sh` |
| Full uninstall | Managed tools, configs, launcher, and state are removed; backups are kept when requested. | `dev-env-lib/src/installer/uninstall.zig`; `test/e2e/fake/clean-uninstall.sh` |
| Source build release assets | Source-built tools produce archives and `source-builds.json` for the release root. | `dev-env-lib/src/dev_env/build.zig`; `release/build.sh` |
| Install from URL | Bootstrap script downloads a release, installs `dev-env`, and can plan from the installed release. | `install.sh`; `test/e2e/release/install-bootstrap.sh` |
| Install selected real tools | Archive, official-installer, source-build, and Docker/system-package paths work for selected tools only. | `test/e2e/release/install-archives.sh`, `install-rust.sh`, `install-source-tools.sh`, `install-docker.sh` |
| Package managers | apt/dnf/brew package sets are selected per host, third-party repositories are configured by the owning manager, and no-op states stay unchanged. | `dev-env-lib/src/shared/platform.zig`, `dev-env-lib/src/dev_env/system/manager.zig`; release/test containers |
| Config Git checkouts | Config-owned plugin repositories are cloned declaratively, existing checkouts are preserved, and `git` is added automatically. | `dev-env-lib/src/installer/git.zig`, planner unit tests; release containers |
| Release matrix | Linux x86_64 release builders produce distro assets; arm and macOS cross builds stay script-ready. | `release/build.sh`, `release/build-release.sh` |

## External states that can cause problems

Unsupported OS/version/arch; no compatible installer; installer protocol mismatch; corrupt or stale `lock.json`/`installed.json`; lock platform different from the host; missing recorded installer; package manager already changed outside dev-env; package manager failure; interrupted partial installs; existing foreign executable links; foreign config files/directories/symlinks; locally modified managed configs; stale stow-source links; missing tool binaries; missing opt dirs; old release state; missing backups; network/download failures.

Handle these by failing before mutation when the desired state is unsafe, treating no-op package/tool states as unchanged, preserving foreign user files unless a backup policy is selected, backing up or skipping config conflicts according to policy, never claiming failed work succeeded (future ownership checkpoints may still
write an honest partial receipt), making doctor fail on verification errors, and keeping cleanup/uninstall limited to paths recorded as dev-env-owned.

## Formal coverage and failure injection

Lean covers pure path/set/diff/closure rules, config-skip membership and an
abstract lifecycle. Its expected failure witnesses preserve D2/A1; they do not
mean the Zig implementation has been fixed. The fake suite currently lacks
systematic failure injection between side effects and receipt writes. Add those
tests with the checkpoint implementation, including interrupted uninstall and
partial Stow/tool operations. Update the first-config-conflict expectation from
“no receipt” to a partial receipt with truthful claims and complete ownership.
