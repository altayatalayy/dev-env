# Formal verification

Two things in dev-env are worth machine-checking: the **pure algorithms** that
decide what to install and what may be deleted, and the **lifecycle** those
algorithms drive. Neither changes often, and both are hard to test exhaustively
— a diff has too many input shapes, and a crash can land between any two
syscalls.

Everything else (release content, install steps, download URLs) changes every
release and is covered by unit and container tests instead.

| Tool | Artifact | Scope |
| --- | --- | --- |
| Lean 4 | `formal/lean/` | pure functions: ownership predicate, set helpers, the diff, dependency closure |
| TLA+ | `formal/tla/` | the apply/uninstall state machine, with crash injection |

## Running

```sh
formal/run.sh          # everything
formal/run.sh lean     # Lean proofs + axiom check
formal/run.sh tla      # TLA+ models
```

**Lean** needs `elan`. If it is installed but not on your `PATH`, activate it
first — the runner does this itself, but an interactive session needs it too:

```sh
source $HOME/.elan/env
cd formal/lean && lake build
```

The pinned toolchain is in `formal/lean/lean-toolchain` (Lean 4.32.2). There are
no external dependencies — no mathlib — so a cold build takes seconds.

**TLA+** needs a JRE. `formal/run.sh` downloads `tla2tools.jar` into the
gitignored `formal/tla/.tools/` on first use.

`formal/run.sh` fails the run if any theorem depends on `sorry` or on
`native_decide`, so a proof can never quietly become an assumption.

## What Lean proves

Source: `formal/lean/DevEnv/`. Each module states the Zig it models in its
header comment.

### `Managed.lean` — the ownership predicate

Models `configs.isManagedTarget` and the identical `apply.isManagedExecutable`.
This is the gate on every destructive filesystem operation, so it is the single
most safety-critical function in the project. Paths are modelled as raw
`List Char`, not as component lists, because the entire point is that a *byte*
prefix is not a *path* prefix.

- `underRoot_sound` — if the predicate accepts a path, that path is either the
  root itself or lies beneath it at a `/` boundary. Nothing else is ever
  accepted.
- `underRoot_self`, `underRoot_child` — everything genuinely under the root is
  accepted (no false negatives, which would strand files as unremovable).
- `underRoot_sibling_rejected` — for *any* root and *any* suffix, a path that
  continues with a character other than `/` is rejected. This is the general
  form of the `stow-source` vs `stow-sources-fake` case, which is also pinned
  as a concrete `decide` example.
- `underRoot_shorter_rejected` — a path shorter than the root is rejected.

### `Ids.lean` — the set helpers

Models `src/shared/ids.zig`.

- `mem_missingFrom`, `missingFrom_eq_nil_iff` — `missingFrom` is exactly set
  difference, and it is empty exactly when one list is contained in the other.
- `mem_sortedUnique` — `sortedUnique` neither loses nor invents names.
- `nodup_sortedUnique` — the result has no duplicates.

The in-place compaction (`copy[len - 1]` compared against the next element) is
modelled faithfully and proved. The *sort* is not re-verified: `std.mem.sort`'s
contract enters as explicit hypotheses (it permutes, and its output is pairwise
ordered under an antisymmetric relation), so the assumption is visible in the
theorem statement rather than hidden.

### `Diff.lean` — the heart of the system

Models `planner.computeDiff` plus the tool-merge step of `apply.applyOutcome`.

- `install_remove_disjoint` — a tool is never installed and removed in the same
  run, including across an installer release change.
- `appliedTools_eq_desired` — **apply converges**: from *any* receipt, applying
  the computed diff yields exactly the lock's resolved tool set.
- `diff_after_apply_isEmpty` — **apply is idempotent**: the diff computed right
  after an apply is empty, so a second run short-circuits.
- `isEmpty_iff_agree` — an empty diff is equivalent to the two states
  describing the same sets, which is what makes the short-circuit safe.

### `Resolve.lean` — dependency closure

Models the fixpoint loop in `resolver.resolve`.

- `closed_of_fixpoint` / `fixpoint_of_closed` — the loop's exit condition is
  *exactly* dependency closure, so `resolved_tools` is never a partial closure.
- `length_lt_of_not_fixpoint` — every non-final iteration strictly grows the
  set.
- `step_mem_universe` — the set never leaves the universe of declared tools,
  which in the implementation is the finite `ToolId` enum. With the previous
  theorem this bounds the loop at `|ToolId|` iterations.

## What TLA+ checks

Source: `formal/tla/DevEnvApply.tla`. The model is the apply/uninstall state
machine over `lock.json`, `installed.json`, the `<opt>` tree, and the stow links
in `$HOME` — with a `Crash` action enabled at every intermediate step.

"Crash" is not only power loss. A failed download, a failing build step, and a
config conflict all abort `applyOutcome` after some side effects have already
landed, so these traces are ordinary failure paths.

### The key distinction

`installed.json` already carries two different kinds of claim, and they have
opposite failure modes:

| Field | Claim | Over-claiming is |
| --- | --- | --- |
| `tools`, `configs`, `stow_packages` | *this is installed* — drives `computeDiff` | **fatal**: apply concludes there is nothing to do and never repairs the machine |
| `owned_prefixes`, `owned_symlinks` | *we may delete this* — drives `clean`/`uninstall` | **harmless**: deleting an absent path is a no-op |

No "mutate the machine, then write the receipt" pair is atomic. The only way to
be safe across a crash is therefore to pick, per field, the direction whose
transient error is the harmless one:

- **ownership** grows *before* creating, shrinks *after* destroying (optimistic)
- **installed** shrinks *before* destroying, grows *after* creating (pessimistic)

### Invariants

- `OwnershipComplete` — everything on disk or stowed in `$HOME` is recorded as
  removable.
- `UninstallLeavesNothing` — a completed uninstall leaves nothing behind.
- `NoPhantomInstall` — the receipt never claims something is installed that is
  not.
- `DiffEmptyMeansDesiredPresent` — when apply reports "nothing to change",
  everything the lock asks for really is present.
- `EventuallyConverges` (liveness, crash-free runs) — once the user stops
  re-planning, apply reaches the locked state.

### Results

`SavePolicy` selects the implementation under test, which is what makes the
model useful as a design tool rather than just a checker:

| Invariant | `final`<br>(today) | `after_install` | `write_ahead` | `two_phase` |
| --- | --- | --- | --- | --- |
| `TypeOK` | ✅ | ✅ | ✅ | ✅ |
| `OwnershipComplete` | ❌ | ❌ | ✅ | ✅ |
| `UninstallLeavesNothing` | ❌ | ❌ | ✅ | ✅ |
| `NoPhantomInstall` | ❌ | ❌ | ❌ | ✅ |
| `DiffEmptyMeansDesiredPresent` | ❌ | ❌ | ❌ | ✅ |

All invariants hold for every policy on the **crash-free** spec, and liveness
holds there too: the current implementation is correct when nothing goes wrong.
Both defects live strictly in the failure paths. See
[review.md](review.md) for the counterexample and the proposed
change.

`MC_current.cfg` is expected to *fail* — it is the regression test for the
defects. `formal/run.sh` treats a passing `MC_current.cfg` as an error, so once
the implementation is fixed the config must be flipped to `two_phase` and
`MC_current.cfg` retired.

## Scope and honesty about it

These artifacts are models, not the program. Specifically:

- The Lean definitions are hand-transcribed from the Zig. They are checked
  against it by review, not mechanically. Each module names the function it
  models so the two can be diffed when either changes.
- The TLA+ model abstracts tools and config packages to opaque names and treats
  each installer step as one atomic action. It says nothing about archive
  extraction, build steps, or GNU Stow's own behaviour.
- Nothing here replaces the unit tests or the container e2e suite; it covers the
  cases those cannot reach.
