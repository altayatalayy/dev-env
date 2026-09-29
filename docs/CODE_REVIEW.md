# Code review

In-depth review of dev-env: architecture, the Zig sources, the shell scripts,
CI, and the release flow. It covers a logical verification of the design, the
results of machine-checking the parts worth proving, and every defect found —
with the simple ones already fixed.

Method: full read of `src/**` (≈4,500 lines of Zig), `install.sh`,
`release/**`, `.github/workflows/**`, and the test harness; Lean 4 proofs of
the stable pure algorithms; a TLA+ model of the apply/uninstall lifecycle under
crash injection; and targeted reproductions against the fake-installer e2e
harness.

Verification after all changes below:

| Check | Result |
| --- | --- |
| `zig fmt --check src build.zig` | clean |
| `zig build` | succeeds |
| `zig build test` | **115/115** pass (was 114) |
| `shellcheck` over every script | clean |
| `test/e2e/fake/run.sh` (10 scenarios) | passes |
| `formal/run.sh` (Lean + TLC) | passes |

---

## Summary

The architecture is sound and unusually disciplined for a personal project. The
orchestrator/installer split is real (no leakage of tool knowledge into
`dev-env`), ownership boundaries are explicit, state writes are atomic, and the
happy path is provably convergent and idempotent — both of those are now
machine-checked.

Every defect found lives in a **failure path**, not the happy path. That is
exactly the profile you would expect from a codebase with good unit tests and
good e2e tests that all exercise successful runs.

Two defects are serious:

- **[D1]** The `skip` conflict policy destroys the config it promises to
  preserve. Reproduced, fixed, regression-tested.
- **[D2]** `installed.json` is written once, after every side effect. An
  interrupted `apply` leaves untracked files that `clean`/`uninstall` can never
  reclaim, and — in one reachable sequence — permanently convinces `apply` that
  a missing tool is installed. Found by model checking; **not fixed**, because
  the fix changes the state-file lifecycle and deserves your call.

---

## 1. Logical verification of the architecture

I checked the design for internal consistency independently of the code.

### Holds up

**The orchestrator/installer split is real.** `dev-env` never names a tool.
Tool identity crosses the boundary as strings and is resolved against the
installer's advertised catalogue (`planner.selectTools` vs `metadata`), so
`dev-env` can drive a release whose tool set did not exist when it was built.
This is the load-bearing idea and it is implemented without cheating.

**Versions live in one place.** `lock.json` deliberately records no tool
versions; pinning an installer release pins every version transitively. That
makes `upgrade` mean exactly one thing and keeps the lock file free of
migration concerns.

**Ownership is predicate-based, not path-guessing.** Every destructive
operation is gated on `isManagedTarget` / `isManagedExecutable`, both of which
compare on path-component boundaries. This is the right shape, and it is the
part most worth proving — see §2.

**Conflict detection precedes mutation.** `applyConfigs` extracts the new
dotfiles to a scratch directory and scans every leaf target *before* anything
user-visible changes, so the default `fail` policy aborts with nothing
modified. Confirmed by the `fail-file` e2e case, which asserts
`installed.json` was not written.

**Removal runs through the installer that performed the install.**
`installed.json` records `installer_path`, not just the release id, and both
`uninstall` and the removal half of `apply` refuse to proceed if that binary is
gone. Correct: only the release that created a layout knows how to undo it.

**Resolution is package-manager aware.** Dependencies belong to the selected
*method*, not the tool, so `alacritty` pulls `rust` on Linux and nothing on
macOS. The dependency graph is validated across *all* package-manager domains,
not only the host's, so a cycle that only exists on Fedora still fails a build
on Ubuntu.

### Weak points in the design itself

**[A1] The receipt conflates two different claims.** `installed.json` mixes
"this is installed" (`tools`, `configs`, `stow_packages` — drives `computeDiff`)
with "we may delete this" (`owned_prefixes`, `owned_symlinks` — drives
`clean`/`uninstall`). They have *opposite* failure modes under a crash:
over-claiming ownership is harmless, over-claiming installation is fatal. The
schema already separates the fields; nothing exploits that. This is the root
cause of D2.

**[A2] `ResolveResponse` carries an unexpressed structural invariant.**
`resolved_configs[i]` must be provided by `stow_packages[i]`. It holds by
construction (one loop in `installer/planner.zig`), but `apply.configForPackage`
depends on it and would return `UnknownConfigPackage` at runtime if it ever
drifted. A `[]const struct { config, package }` would make it unbreakable.

**[A3] `ConfigDef.stow_package` and the embedded dotfiles tree are unlinked.**
A config naming a stow package the archive does not ship fails at apply time
with a bare `FileNotFound`. *Fixed:* added a test that cross-checks every
`stow_package` against `dotfiles.packages()`.

**[A4] The protocol has no additive-change story.** `src/shared/json.zig`
parses with unknown fields as errors, so *any* struct change is breaking, and
compatibility is exact-version. That is a defensible choice, but it means the
version must be bumped for changes that look additive. Now documented in
`docs/protocol.md` and in a comment on `protocol.version`.

### Incomplete subsystems

**[A5] `dev-env build` produces artifacts nothing consumes.** It writes
per-platform `tar.zst` archives and a `source-builds.json` manifest, and
`src/shared/source_builds.zig` implements `select()` and `verifyFile()` for
looking one up and checking its SHA-256. **Nothing calls either.**
`installer/apply.zig:installSource` always downloads upstream sources and
compiles locally. So the entire premise — "a release server hands the prebuilt
archive to targets that must never compile locally" — is unimplemented on the
consuming side. `test/e2e/release/install-source-tools.sh` builds from source,
so no test notices.

Either wire it up (the installer needs a release-root URL to fetch the manifest
from, which is precisely what the removed `release.json` sidecar looked like it
was reserved for), or delete `build`, `source_builds.zig`, and the release-build
containers. Half of it is dead weight today.

**[A6] Tool environment exports never reach a shell.** `dev-env exports` prints
`NAME=value` lines for `GOROOT`, `GOPATH`, `CARGO_HOME`, `RUSTUP_HOME` and the
`PATH` additions. The shipped `dotfiles/.bashrc` and `dotfiles/.zshenv` set only
`EDITOR` and `PATH`; nothing evaluates `dev-env exports`. After a successful
`apply`, none of the installed toolchains' environment is active.

**[A7] The `shell` dotfiles package is never stowed.** `dotfiles.package_views`
ships `shell` (`.bashrc`, `.zshenv`), but no `ConfigDef` names it as a
`stow_package`, so it is extracted into every release tree and then ignored.
Those files are what put `~/.local/bin` on `PATH` — without them a fresh
install's `dev-env`-managed executables are not reachable. A6 and A7 are the
same gap: the shell integration layer is missing.

I left A5–A7 alone: each is a product decision (implement vs. delete, and how
shell integration should work), not a mechanical fix.

---

## 2. What is now machine-checked

Full detail in [formal-verification.md](formal-verification.md); run everything
with `formal/run.sh`.

### Lean 4 — `formal/lean/`

No `sorry`, no `native_decide`; `formal/run.sh` fails the build if either
appears. Every theorem depends only on Lean's three standard axioms.

- **`Managed.lean`** — the ownership predicate. `underRoot_sound`: acceptance
  implies the path is the root or lies under it at a `/` boundary.
  `underRoot_sibling_rejected`: for *any* root and *any* suffix, a path
  continuing with a non-`/` character is rejected. That is the general form of
  the `stow-source` vs `stow-sources-fake` case, which the code guards against
  and a unit test pins for one input.
- **`Ids.lean`** — `missingFrom` is set difference; `sortedUnique` preserves
  membership and produces no duplicates. The in-place compaction is modelled
  faithfully; `std.mem.sort`'s contract enters as explicit hypotheses rather
  than a silent assumption.
- **`Diff.lean`** — the core. **Convergence**: applying `computeDiff` to any
  receipt yields exactly the lock's resolved tool set. **Idempotence**: the diff
  right after an apply is empty. **Disjointness**: never install and remove the
  same tool. **`isEmpty` ⟺ the states agree**, which is what makes the
  short-circuit in `applyOutcome` safe.
- **`Resolve.lean`** — the fixpoint loop exits exactly when the set is
  dependency-closed, each non-final iteration strictly grows the set, and the
  set never leaves the finite `ToolId` universe.

### TLA+ — `formal/tla/`

`DevEnvApply.tla` models apply/uninstall over `lock.json`, `installed.json`, the
`<opt>` tree, and the stow links in `$HOME`, with a `Crash` action enabled at
every intermediate step. "Crash" is not only power loss — a failed download, a
failing build step, and a config conflict all abort `applyOutcome` after side
effects have landed.

All invariants hold, and liveness holds, on the **crash-free** spec. Under
crashes, the current write policy fails four of them. See D2.

---

## 3. Defects

### D1 — `--config-conflict=skip` destroys the config it preserves ✅ fixed

**Severity: high.** Silent loss of the user's config from their environment.

When `refreshDotfiles` detects that a managed config was edited locally and the
policy is `skip`, `apply` logs *"keeping locally modified config tmux"* and
removes the package from `to_stow`. `syncStowSource` was then called with
`to_stow` only — and it **deletes every stow-source entry not in that list**.
The `$HOME` symlinks point at `stow-source/<pkg>`, so they are left dangling.

Reproduced against the fake installer:

```
after first apply:
  ~/.config/tmux/tmux.conf -> ../../.local/share/dev-env/stow-source/tmux/.config/tmux/tmux.conf
  content: set -g status on
  after edit: my own tmux settings

info: keeping locally modified config tmux      <- the promise

after second apply:
  ~/.config/tmux/tmux.conf -> ../../.local/share/dev-env/stow-source/tmux/...
  BROKEN: the symlink no longer resolves        <- the reality
  stow-source entries: neovim
```

Trigger: apply, edit a managed config, then any later apply that has other work
to do (e.g. `plan --add neovim`) with `--config-conflict=skip`. The user's
edits survive on disk under `releases/<release>/dotfiles/` but nothing points at
them any more.

There was a second-order bug in the same place: because the skipped package was
also dropped from `receipt.stow_packages`, every subsequent `plan` re-added its
config, so the diff was never empty again and `apply` stopped being idempotent
for that machine.

**Fix** (`src/dev_env/apply.zig`): compute the set of packages that must stay
linked as `to_stow` plus any skipped package whose stow-source entry already
exists, drive `syncStowSource` from that, and report it as `stowed` in the
receipt. Only `to_stow` is restowed and only `to_stow` gets `apply-configs`, so
skipped packages are genuinely left alone rather than deleted.

Regression test added to `test/e2e/fake/config-conflicts.sh` (`skip-modified`
case): asserts the content is still readable, the stow-source entry survives,
and `installed.json` lists the package as stowed.

### D2 — an interrupted `apply` leaks files and can permanently mislead the diff ❌ not fixed

**Severity: high.** Found by model checking; not reproducible by the current
test suite because every test runs to completion.

`applyOutcome` writes `installed.json` exactly once, at the very end. Everything
before it — package installs, tool removals, archive extraction, source builds,
dotfiles refresh, stowing — is unrecorded until that write lands.

TLC results (`formal/tla/`, `SavePolicy` selects the write policy):

| Invariant | `final` (today) | `after_install` | `write_ahead` | `two_phase` |
| --- | --- | --- | --- | --- |
| `OwnershipComplete` | ❌ | ❌ | ✅ | ✅ |
| `UninstallLeavesNothing` | ❌ | ❌ | ✅ | ✅ |
| `NoPhantomInstall` | ❌ | ❌ | ❌ | ✅ |
| `DiffEmptyMeansDesiredPresent` | ❌ | ❌ | ❌ | ✅ |

**D2a — ownership leak.** Counterexample: `Plan → ApplyStart → Remove →
Install → Crash`. Result: `disk = {t1}`, `hasReceipt = FALSE`. The tool's
`<opt>` tree and its `~/.local/bin` symlink exist with **no record at all**.
`clean` and `uninstall` both act only on what the receipt names, so those files
are orphaned permanently. The same holds for stow links created between
`Configs` and the final save. On a first-ever `apply` this is worst: no
`installed.json` exists, so `uninstall` prints "nothing installed" and exits.

Note this needs no power cut. A failing `git` build step, a 503 from
ziglang.org, or `error.ConfigConflict` all take this path.

**D2b — phantom installation.** The sharper one. Counterexample:

1. `t1` installed; receipt says `tools = {t1}`.
2. User plans without `t1`. `apply` runs the installer's uninstall — files gone.
3. Crash (or any later step fails) before the receipt is written.
   Receipt still says `tools = {t1}`.
4. User changes their mind and re-selects `t1`.
5. `computeDiff`: `install = lock.tools \ receipt.tools = {}`. Diff empty.
   **`apply` reports "nothing to change" and `t1` is never reinstalled.**

No number of `apply` runs fixes it. `doctor` reports the tool as failing verify
but cannot repair it; only `upgrade` (which forces a full re-apply via
`release_change`) or hand-editing `installed.json` recovers.

**Recommended fix — `two_phase`, verified to satisfy all four invariants.**
Exploit the asymmetry in [A1]: no "mutate, then record" pair is atomic, so pick
per field the direction whose transient error is harmless.

- **ownership** (`owned_prefixes`, `owned_symlinks`) — grow **before** creating,
  shrink **after** destroying. A transient over-claim just means `clean` tries
  to delete a path that is not there, which is a no-op.
- **installed** (`tools`, `configs`, `stow_packages`) — shrink **before**
  destroying, grow **after** creating. A transient under-claim just means the
  next `apply` reinstalls something already present, which is idempotent
  (`installArchive`/`installSource` skip when the version directory exists).

Concretely, in `applyOutcome`:

1. before `uninstallRemovedTools`: write a receipt with `diff.remove_tools`
   dropped from `tools`/`configs`/`stow_packages` and everything this run may
   touch added to `owned_*`;
2. after `client.applyTools`: write a receipt with the installed tools added;
3. after the config phase: the existing final write.

Three atomic temp-file-plus-rename writes instead of one. `receipt_mod.save`
already does the atomic part.

I did not implement this. It changes when state becomes visible on disk, it
touches the one code path the fake e2e suite cannot fault-inject into, and the
right fix should land together with crash-injection tests. Flip
`formal/tla/MC_current.cfg` to `two_phase` and retire it when you do —
`formal/run.sh` currently *expects* that config to fail.

---

## 4. Fixed in this pass

| # | Change | Why |
| --- | --- | --- |
| F1 | `paths.launcher` (`<data>/launcher`) → `paths.launchers` (`<data>/bin`) | **Bug.** `install.sh` writes launchers to `<data>/bin/<version>/dev-env`; nothing ever created `<data>/launcher`. `uninstall` deleted the wrong (nonexistent) directory, left every installed `dev-env` binary behind, and consequently always failed to remove `<data>` — so it *always* printed "kept … (backups remain)" even with no backups. |
| F2 | Removed the dead `deactivate` path; `protocol.version` 1 → 2 | Both call sites always sent `&.{}`. The installer's handling loop and `deactivateBinLinks` were unreachable. Removing a request field is a breaking protocol change by this project's own rule, hence the bump; there are no published releases, so it costs nothing. |
| F3 | `installer_client.discover` skips non-`x.y.z` release directories | **Latent bug.** `newestCompatible` parses every discovered release id; one malformed directory under `installers/` made *every* command fail with `InvalidVersion` instead of being ignored, like the other skip cases already are. |
| F4 | Cross-check test: every `ConfigDef.stow_package` is shipped by the dotfiles archive | [A3]. A typo previously surfaced only at apply time as a bare `FileNotFound`. |
| F5 | Dropped the unread `installers/<version>/release.json` sidecar from `install.sh` | Nothing reads it, and with `--github` it recorded an empty `release_root_url`. Flagged as "noted, not changed" in the previous review; the guidelines say remove dead code. |
| F6 | Removed unused `proto` imports (`dev_env/exports.zig`, `installer/steps.zig`) and the unused `configs.RefreshError` | Dead declarations. |
| F7 | `protocol.validateRequest` folded into `parseRequest` | It took a `command` parameter it discarded with `_ = command;`. |
| F8 | `main.selectedInstaller` → `newestInstaller` | Its `maybe_path` parameter was `null` at its only call site, and the lock branch was already handled by the caller. |
| F9 | CI: corrected the misleading dependency comment; added a `formal` job; added `formal/` to the shellcheck sweep | See C1 below. |
| F10 | `docs/`, `README.md` | Documentation restructure. |

Plus D1 above.

---

## 5. Other findings, not changed

**[C1] `ci.yml`'s `build-test` job cannot pass.** The workflow states that
`zig-cli` and `zig-graph` are URL dependencies fetched by `zig build`.
`build.zig.zon` still declares them as relative `path` dependencies pointing at
sibling checkouts, and neither sibling has a git remote or any commits locally.
On a bare runner `zig build` will fail immediately. I corrected the comment to
state the blocker plainly and added an independent `formal` job that does pass.
Publish both libraries and switch `build.zig.zon` to URL dependencies before
making this a required check. The same blocker applies to
`test/scripts/test-container.sh`, which passes the siblings as Docker build
contexts.

**[C2] `Installer.protocolSupported()` is unreachable in practice.**
`client.local`/`discover` reach it only after `metadata()` succeeded, and
`parseLineHeader` already rejects a foreign protocol. `MetadataResponse.protocol`
and the line header's `protocol` are the same constant in a given binary, so the
body check can never fail on its own. The `newestCompatible` unit test
constructs `protocol + 1` installers directly, i.e. it exercises a state
`discover` cannot produce. Harmless defence-in-depth, but the test overstates
its coverage — real protocol skipping happens via `discover`'s
`metadata(...) catch continue`.

**[C3] `apply.zig` assigns `to_stow.items = filtered.items`.** Writing an
`ArrayList`'s `items` field directly works here (the list is only read
afterwards) but leaves `capacity` describing the old buffer. Prefer replacing
the list value.

**[C4] `configs.classifyAncestorSymlink` only classifies symlink ancestors.** If
an ancestor is a *regular file* (say `$HOME/.config` is a file), the leaf stat
returns `FileNotFound` → `missing` → no conflict, and stow then fails with a
less clear error. Rare, but the conflict scan is the layer that is supposed to
produce the good message.

**[C5] `platform.addAptRepository` interpolates release data into `sh -c`.**
`key_url`, `key_path`, `source_path`, and `source_line` are compile-time
constants in `release.zig`, so there is no injection vector today. Worth a
comment stating that constraint, since it stops being true the moment repository
data becomes configurable.

**[C6] `apply` re-plans on every run.** `apply` calls `planner.buildPlan`, which
re-resolves and rewrites `lock.json`. This is deliberate and good (no stale-lock
application), but it does mean `apply` is not usable offline against a
pre-computed plan, and `plan`'s output can differ from what `apply` then does if
the installer set changed in between. Worth documenting as intended if it is.

**[C7] Test coverage gaps.** No test faults-injects mid-apply (D2's whole
class). `test/e2e/fake/config-conflicts.sh` covered only the conflict-scan
`skip`, never the `refreshDotfiles` `skip` — which is why D1 survived. There is
no unit test for `applyOutcome` itself; it is only reachable through the e2e
harness.

---

## 6. Recommended order of work

1. **D2** — the receipt checkpoint design, with crash-injection e2e tests.
   Highest value: it is the only defect that can permanently wedge a machine.
2. **A5** — decide whether prebuilt source archives are a real feature. If yes,
   wire the manifest into `installSource`; if no, delete `dev-env build`,
   `source_builds.zig`, and the release builder containers.
3. **A6/A7** — shell integration. Today a successful `apply` does not put the
   installed toolchains on `PATH`.
4. **C1** — publish `zig-cli`/`zig-graph` and switch to URL dependencies, so CI
   and the container e2e suite can actually run.
5. **A2** — make the `resolved_configs` ∥ `stow_packages` pairing a single typed
   list at the next protocol bump.
