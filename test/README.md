# dev-env tests

## Layout

- `zig build test`: unit/component tests embedded next to the Zig code.
- `test/integration`: fast lifecycle tests using a protocol-compatible fake installer.
- `test/e2e`: heavier tests that use the real installer/tool flows.
- `containers/release`: release builder Dockerfiles.
- `containers/test`: test runner Dockerfiles.

The default matrix command runs unit/component tests once, builds the native Linux binaries, then runs the fast integration suite on the supported amd64 Linux targets:

- `ubuntu-24.04-x86_64`
- `ubuntu-26.04-x86_64`
- `fedora-44-x86_64`

```sh
test/scripts/test-container.sh
```

ARM Linux targets are still supported by the release build, but they are not part of the default test matrix because the current host cannot run ARM containers. They can be selected explicitly with `TEST_TARGETS` on a machine with working ARM/container support.

## Feature inventory that should be covered

Plan and lock handling; platform/arch detection; changing selections with `--tools`, `--add`, and `--remove`; apply/idempotent apply; upgrade; explicit downgrade; config conflict policies; config refresh; GNU Stow restow/delete; tool activation/deactivation; source build archive generation; archive install; official installer flows; verification; doctor; clean; uninstall; installer discovery; protocol/progress handling; package-manager changed/no-change behavior; release build matrix for supported Linux targets and macOS cross assets.

## External states that can cause problems

Unsupported OS/version/arch; no compatible installer; installer protocol mismatch; corrupt or stale `lock.json`/`installed.json`; lock platform different from the host; missing recorded installer; package manager already changed outside dev-env; package manager failure; interrupted partial installs; existing foreign executable links; foreign config files/directories/symlinks; locally modified managed configs; stale stow-source links; missing tool binaries; missing opt dirs; old release state; missing backups; network/download failures.

Handle these by failing before mutation when the desired state is unsafe, treating no-op package/tool states as unchanged, preserving foreign user files unless a backup policy is selected, backing up or skipping config conflicts according to policy, never writing a successful receipt after a failed apply, making doctor fail on verification errors, and keeping cleanup/uninstall limited to paths recorded as dev-env-owned.
