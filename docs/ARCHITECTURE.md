# Architecture

dev-env installs a personal development environment — language toolchains,
terminal tools, and their dotfiles — into a managed, versioned layout under
`~/.local`, and keeps that layout converged on a declared desired state.

## Two binaries, one protocol

The system is split into two executables that never share memory and only
ever talk over a line-delimited JSON protocol on stdin/stdout.

```
        ~/.local/bin/dev-env  (launcher symlink)
                  |
   +--------------v---------------+        JSON over stdio        +---------------------------+
   |          dev-env             | ---------------------------> |      dev-env-install      |
   |  (orchestrator, long-lived)  | <--------------------------- |  (one release's content)  |
   +------------------------------+   progress* then response    +---------------------------+
   | lock.json / installed.json   |                              | tool + config definitions |
   | host detection               |                              | dependency resolution     |
   | system packages (apt/dnf/brew)|                             | archive/source/official   |
   | GNU Stow, conflict policy    |                              |   install methods         |
   | backups, clean, uninstall    |                              | embedded dotfiles archive |
   +------------------------------+                              +---------------------------+
```

**`dev-env`** is the stable orchestrator. It knows *nothing* about which tools
exist. It detects the host, decides *what should be true*, computes the diff
against *what is true*, and drives the installer. It owns everything that must
outlive any single release: state files, `$HOME` config placement, backups, and
removal.

**`dev-env-install`** is one immutable release's payload. It knows the tool set,
the versions, the dependency graph, the install methods, and carries the
dotfiles tree embedded in its own binary. Multiple releases coexist under
`installers/<release>/`, and `dev-env` picks one.

The split exists so that **upgrading the tool set is just installing another
installer binary** — no change to the orchestrator, no migration of state.

`src/shared/` holds only what genuinely crosses the boundary: the protocol
types, the platform model, JSON helpers, template rendering, and version
ordering.

## The desired/actual loop

Everything dev-env does is one convergence loop over two JSON files:

| File | Meaning | Written by |
| --- | --- | --- |
| `lock.json` | **desired** state: selected tools, resolved closure, chosen installer release, install layout | `plan`, `apply`, `upgrade` |
| `installed.json` | **actual** state: installed tools and versions, stowed packages, owned symlinks and prefixes | `apply`, `clean` |

```
  host + CLI flags ──▶ selectTools ──▶ installer.resolve ──▶ lock.json
                                                               │
                          installed.json ──▶ computeDiff ◀─────┘
                                                 │
                                                 ▼
                      system packages → installer.apply → dotfiles → stow → installed.json
```

Deliberately, **`lock.json` records no tool versions**. Versions belong to the
installer release, so pinning a release pins every version transitively. That
keeps the lock file small and makes "upgrade" mean exactly one thing: select a
newer installer release.

## Command surface

| Command | Effect |
| --- | --- |
| `plan` | write `lock.json`, print the diff, change nothing else |
| `apply` | converge to `lock.json` using the locked installer |
| `upgrade` | re-lock to the newest compatible installer, then converge |
| `doctor` | verify host, state files, and each installed tool |
| `exports` | print `NAME=value` lines for the installed tools' environment |
| `build` | source-build this release's tools into release archives (builder-side) |
| `clean` | drop inactive tool versions and old release state |
| `uninstall` | unstow configs, remove release-owned tools, delete state |

## Ownership boundaries

The design rests on a strict split of *who may delete what*. Every destructive
operation is gated on an ownership predicate rather than on a path guess.

- **dev-env owns** `$XDG_DATA_HOME/dev-env/**`, the `dev-env` launcher symlink,
  and the config symlinks it created in `$HOME` via GNU Stow.
- **the installer owns** `<opt>/<tool>/<version>/` trees and the executable
  symlinks in `<bin>` that point into them.
- **nobody owns** system packages. `apt`/`dnf`/`brew` packages are installed but
  *never removed*; uninstall reports them as `kept_system`.
- **the user owns** everything else in `$HOME`. A pre-existing file where a
  config would land is a *conflict*, resolved by an explicit policy
  (`fail` — default, `backup`, or `skip`), never by silent overwrite.

Two predicates enforce this and are the safety core of the whole system:
`configs.isManagedTarget` (is this symlink target inside a dev-env root?) and
`apply.isManagedExecutable` (does this bin link point into our opt root?). Both
compare on **path-component boundaries**, so `/…/stow-source` never matches
`/…/stow-sources-fake`. Both are formally verified — see
[formal-verification.md](formal-verification.md).

## Configs: the stow-source indirection

Dotfiles are not stowed from the release tree directly. A stable indirection
layer sits in between:

```
  $HOME/.config/nvim
    -> ~/.local/share/dev-env/stow-source/nvim/.config/nvim     (stow creates this)
  ~/.local/share/dev-env/stow-source/nvim
    -> ~/.local/share/dev-env/releases/<release>/dotfiles/nvim  (dev-env creates this)
```

Switching releases therefore only retargets the `stow-source` links; the links
in `$HOME` never have to be rewritten. Before anything user-visible changes,
`apply` extracts the new release's dotfiles to a scratch directory and scans
every leaf target for conflicts, so a conflicting `$HOME` aborts the run
*before* any file moves.

## Platform model

A `Platform` is a tagged union (`ubuntu`/`debian`/`fedora`/`macos`) carrying an
OS version and an arch. It selects two independent things:

1. **Support** — does this release declare the tool available here at all?
2. **Package-manager domain** (`apt`/`dnf`/`brew`) — which install *method*
   applies.

The same tool can be a source build on apt/dnf and a plain brew formula on
macOS, with different dependencies each way. Resolution is therefore
package-manager aware: `alacritty` pulls in `rust` on Linux (where it is
compiled) and nothing on macOS (where brew resolves it).

## Further reading

- [protocol.md](protocol.md) — the JSON boundary, commands, and compatibility rules
- [state-model.md](state-model.md) — lock/receipt schemas, the diff, and lifecycle invariants
- [resolution.md](resolution.md) — the dependency graphs, method selection, and install ordering
- [formal-verification.md](formal-verification.md) — what is machine-checked, and how to run it
- [CODING_GUIDELINES.md](CODING_GUIDELINES.md) — style and review rules
