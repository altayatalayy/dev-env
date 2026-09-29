# Dependency resolution and install methods

All of this lives inside `dev-env-install` (`src/installer/`). `dev-env` sends a
list of tool names and receives a fully resolved plan; it never reasons about
dependencies itself.

## Release data

`src/installer/release.zig` is the single place release content changes. It
declares, per tool: supported platforms, environment exports, owned config
packages, and a list of **candidate install methods**.

```zig
ToolDef = {
    id: ToolId,                        // enum — the set is fixed per release
    platforms: []Support,              // OS versions × arches
    exports: []EnvExport,              // applied whenever the tool is active
    configs: []ConfigDef,              // stow packages this tool owns
    methods: []PlatformMethod,         // first match by package manager wins
}
```

## Method selection

Two independent gates, in order:

1. `ToolDef.supports(platform)` — is the tool declared for this OS version and
   arch at all? If not, there is no method.
2. `methodForManager(apt | dnf | brew)` — the first method whose `on` list
   contains the host's package manager (an empty `on` matches any).

```
                          ┌── apt/dnf ──▶ source build (needs rust, libfontconfig1-dev, …)
alacritty ── supports? ───┤
                          └── brew ─────▶ cask "alacritty" (brew resolves everything)
```

The four method kinds:

| Kind | Where it lands | Removable by dev-env |
| --- | --- | --- |
| `archive` | `<opt>/<tool>/<version>/`, bin symlinks into `<bin>` | yes |
| `source` | same, after running `build_steps` in an extracted tree | yes |
| `system` | wherever `apt`/`dnf`/`brew` puts it | **no** — reported as `kept_system` |
| `official` | wherever the upstream installer puts it | only if `uninstall_steps` exist |

Because dependencies belong to the *method*, not the tool, resolution is
package-manager aware. This is the reason `resolve` takes a full `Platform` and
not just an arch.

## Two graphs

There are two separate dependency graphs, and `apt`/`dnf`/`brew` package names
are **not** nodes in either — they are leaves handed to the system package
manager.

- **tool → tool**, from a method's `build_dependencies` and
  `runtime_dependencies`.
- **config → config**, from `ConfigDef.config_dependencies`.

A config additionally pulls in its `for_tool` and its own tool dependencies,
which is how `neovim-config` ends up requiring `go`.

`resolver.validate` rejects, before any resolution: references to undefined
tools/configs, a config whose `for_tool` does not own it, self-dependencies, and
cycles — direct or indirect. Cycle detection uses the `zig-graph` DAG, and
crucially it validates the tool graph **across every package-manager domain**,
not only the host's, so a cycle that only exists on Fedora still fails a build
on Ubuntu. `api.metadata`'s test calls `validate` on the real release data, so
bad release content fails `zig build test`.

## The closure

`resolver.resolve` builds the resolved set in two phases:

1. **Config closure** — every config owned by a selected tool, transitively
   closed over `config_dependencies`. Each config inserts its `for_tool` and its
   install (and optionally runtime) tool dependencies into the tool set.
2. **Tool closure** — a fixpoint loop: while anything changed, for each tool in
   the set, add the dependencies of *the method selected for this host*.

`include_runtime_dependencies` is false only for `dev-env build`, which wants
the compile-time closure and nothing more: build a source archive without
dragging in the runtime libraries the finished binary would want.

Results come back in `std.EnumSet` iteration order, i.e. **enum declaration
order** — deterministic, but not the install order.

## Install ordering

`resolver.installOrder` topologically sorts the tools actually being installed
so a toolchain exists before the build that needs it.

```
request:  ["alacritty", "neovim", "rust", "zig"]      (alphabetical, from dev-env)
edges:    rust → alacritty,  zig → neovim
result:   ["rust", "zig", "alacritty", "neovim"]
```

Two properties worth calling out:

- **Edges are added only between requested tools.** A dependency that is not
  part of the request is not invented — installing just `alacritty` when `rust`
  is already present must not drag `rust` back in.
- **Independent tools keep request order**, so plans are stable run to run.

## What `resolve` returns

```zig
ResolveResponse = {
    selected_tools,    // sorted, unique
    resolved_tools,    // sorted, unique — the closure
    resolved_configs,  // parallel to stow_packages
    system_packages,   // { apt, dnf, brew, brew_cask } — merged, sorted, unique
    stow_packages,
    tool_actions,      // per tool: kind, version, build deps, env exports
}
```

`system_packages` merges every method's package dependencies for the host's
manager, deduplicates, and adds two implicit entries: `git` when any config
declares a git checkout, and `stow` whenever there are configs at all — since
`dev-env`, not the installer, runs GNU Stow.

`tool_actions` is what lets `dev-env` keep a receipt without understanding
install methods: it carries the version to record and the env exports to
snapshot, keyed by tool name.

## Step execution

`build_steps`, `install_steps`, and `uninstall_steps` are `{name, argv}` pairs
run through `steps.runStep`:

- Every argv element goes through `{home}`/`{opt}`/`{bin}`/`{cache_dir}`/`{prefix}`
  template rendering.
- `argv[0]` is resolved **against the step environment's `PATH`**, not the
  parent's. Without this, `std.process.spawn` would resolve against the
  installer's own PATH and ignore the toolchain exports the step depends on.
  Names containing `/` are passed through unchanged.
- The step environment is the parent environment plus `<bin>` prepended to
  `PATH` plus every active tool's exports — the same environment `verify` uses
  later, so "it built" and "doctor says it works" mean the same thing.
- stdout and stderr are streamed into a buffer and only logged **if the step
  fails**, keeping successful builds quiet.
