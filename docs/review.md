# Current code review (2026-09-30)

This replaces the two earlier review snapshots. It checks their findings against
the current tree and records the remaining work. The previous Lean and TLA+
results are described in [formal-verification.md](formal-verification.md); they
were not rerun for this update.

## What was checked

- Installer release definitions, dependency resolution, config application,
  receipt writes, dotfiles, shell exports, build and release scripts, and CI.
- `zig build`, `zig build test --summary all` (115/115), the local fake-installer
  e2e suite, Zig formatting, shell syntax and ShellCheck, Neovim Lua syntax, and
  a temporary tmux server loading the copied config.
- The current `build.zig.zon` pins `zig-cli` and `zig-graph` to GitHub commits.
  GitHub Actions is checked separately from this local review.

The complete source-build release matrix and crash-injection model were not run
for this review. Passing local tests therefore do not establish that every new
upstream source archive builds on every supported Linux target. The copied
Neovim plugins were syntax-checked but not fetched and exercised as a full
editor session.

## Managed versions

| Tool | Release definition after this update | Source |
| --- | --- | --- |
| Git | 2.56.0 on Linux; Homebrew on macOS | [Git source release](https://git-scm.com/install/source) |
| Neovim | 0.12.5 on Linux; Homebrew on macOS | [Neovim releases](https://github.com/neovim/neovim/releases) |
| tmux | 3.7c on Linux; Homebrew on macOS | [tmux releases](https://github.com/tmux/tmux/releases) |
| Go | 1.27.1 on Linux; Homebrew on macOS | [Go downloads](https://go.dev/dl/) |
| Zig | 0.16.0, already current | [Zig downloads](https://ziglang.org/download/) |
| Alacritty | 0.17.0 on Linux; Homebrew cask on macOS | [Alacritty releases](https://github.com/alacritty/alacritty/releases) |
| Rust | `stable` channel (1.98.1 when checked) | [Rust releases](https://blog.rust-lang.org/releases/) |
| Docker Engine | official package repository (29.8.1 when checked) | [Docker Engine notes](https://docs.docker.com/engine/release-notes/29/) |

## Earlier findings now resolved

| Finding | Current state |
| --- | --- |
| D1: `--config-conflict=skip` breaks a managed config link | Fixed in `src/dev_env/apply.zig`; fake e2e covers the modified-config case. |
| A3: config names an absent dotfiles package | A test in `src/installer/dotfiles.zig` checks every declared Stow package. |
| A4: additive protocol changes lack a compatibility rule | Exact-version compatibility is documented in `docs/protocol.md`. |
| C1: CI cannot fetch sibling `zig-cli` / `zig-graph` | Both are pinned GitHub dependencies in `build.zig.zon`; the container test no longer needs sibling build contexts. |
| C3: direct replacement of `ArrayList.items` | The skipped-config filter now compacts the existing list without losing its capacity metadata. |
| Old `release.json` sidecar and wrong launcher cleanup path | Both were fixed in the earlier review pass. |

## Partially resolved

**A6/A7: shell integration.** The shipped `.bashrc` and `.zshenv` now read
`dev-env exports` as data, avoiding `eval`. The `shell` Stow package is declared
as a config for Git, and Neovim's config depends on it. This covers the default
all-tools selection, Git, and Neovim. A selection containing only Go or Rust
still has no shell package, so its exported environment is not loaded by a
newly installed managed dotfile. A standalone shell config in the protocol, or
another explicit opt-in mechanism, would close that gap without forcing Git
into unrelated selections.

**C7: coverage.** The fake e2e suite covers the D1 skip regression. It still
does not inject a failure between tool/config side effects and the receipt
write, which is the main D2 scenario.

## Open findings

### D2 / A1: interrupted apply can lose ownership or claim a missing tool

`applyOutcome` writes `installed.json` once, after package changes, tool
removals/installations, and Stow operations. A failure before that write leaves
an old or absent receipt. For example, remove a tool, fail during a later
install, then select the removed tool again: the old receipt still lists it, so
`computeDiff` can report no install work while the executable is missing.
First-time failures can leave an unrecorded tool tree or Stow links that
`clean`/`uninstall` cannot reclaim.

The receipt already separates installation claims (`tools`, `configs`,
`stow_packages`) from ownership claims (`owned_prefixes`, `owned_symlinks`). A
proper fix should write ownership ahead of creation and record installation
after success, with crash-injection tests. The existing TLA+ `two_phase` model
is the proposed design. This is the highest-priority remaining correctness
problem; it was not changed in this pass.

### A5: prebuilt source archives are published but unused by installs

`dev-env build` writes platform-specific source archives and
`source-builds.json`; `src/shared/source_builds.zig` can select and verify an
archive. `src/installer/apply.zig:installSource` still downloads upstream
sources and compiles on the target machine. The release artifacts need a
consumer and a release-root URL, or the unused builder path should be retired.

### A2: config/package pairing is positional

`ResolveResponse.resolved_configs[i]` is assumed to match
`stow_packages[i]`. The planner currently creates both in one loop, but the
protocol does not encode the pairing. A typed pair at the next protocol change
would remove this fragile invariant.

### C2, C4, C5, C6: smaller design and error-path issues

- C2: `protocolSupported()` adds a redundant check after the protocol header
  has already been accepted; the related unit test does not exercise actual
  installer discovery.
- C4: a regular file at an ancestor such as `$HOME/.config` is reported as a
  missing leaf, and Stow later fails with a less useful error. Conflict
  scanning should identify and deduplicate the blocking ancestor, including
  when `--config-conflict=backup` is used.
- C5: apt repository fields are compile-time constants but are interpolated
  into `sh -c`. If repository data ever becomes configurable, this needs
  argument-safe handling.
- C6: `apply` intentionally re-plans and rewrites `lock.json`; an installer
  change between `plan` and `apply` can change the result. This should be
  documented as a deliberate online behavior.

## New observations from this update

- The copied Neovim config initially assumed `XDG_DATA_HOME` and `$MASON` were
  set. It now uses Neovim's `stdpath("data")` for both paths. Its plugin lockfile
  contains public repository revisions; personal scripts and caches were not
  copied.
- The copied Alacritty config referenced a user-specific hotkey executable
  and `/bin/zsh`; those were omitted. The Rose Pine import was copied as a
  plain theme file, without its nested Git checkout.
- The copied tmux config used a fixed `/usr/bin/zsh` and required `xclip` for
  one key binding. It now uses the user's shell and tmux's own copy command.
- These version and dotfile changes are newer than the already published
  `v0.1.0` tag. The default build/release identifier is now `0.1.1`; that
  release still needs fresh source-build validation before publication.

## Suggested order

1. Add receipt checkpoints and crash-injection tests for D2/A1.
2. Decide whether installers should consume the prebuilt archives (A5).
3. Make shell integration available for Go/Rust-only selections (A6/A7).
4. Fix ancestor-file conflict reporting and add a focused test (C4).
5. Fold the remaining protocol/behavior clarifications into the next protocol
   change (A2/C2/C5/C6).
