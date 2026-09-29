# The dev-env ↔ installer protocol

Defined in `src/shared/protocol.zig`. Current version: **1**.

## Transport

`dev-env` spawns `dev-env-install <command>` per operation:

- **stdin** — one JSON request object, then EOF.
- **stdout** — line-delimited JSON: zero or more `progress` messages, then
  exactly one `response` message. Nothing else may be written here.
- **stderr** — inherited from `dev-env`; free-form human diagnostics.
- **exit status** — non-zero means the whole call failed, regardless of what
  was written to stdout.

Every message carries `protocol`, `kind` (`progress` | `response`), and
`command`. The client parses a small `LineHeader` first, which lets it reject a
mismatched protocol before attempting to decode a payload whose shape it may
not understand.

```
dev-env                                 dev-env-install
   │  spawn argv = [bin, "apply"]              │
   │─────────────────────────────────────────▶ │
   │  {"protocol":1,"platform":…,"install":…}  │
   │─────────────────────────────────────────▶ │ (stdin closed)
   │  {"protocol":1,"kind":"progress",…}       │
   │ ◀─────────────────────────────────────────│
   │  {"protocol":1,"kind":"response",…}       │
   │ ◀─────────────────────────────────────────│
   │  exit 0                                   │
```

## Commands

| Command | Request | Response | Purpose |
| --- | --- | --- | --- |
| `metadata` | *(none)* | `MetadataResponse` | release id, protocol, supported platforms, tool/config catalogue |
| `resolve` | `ResolveRequest` | `ResolveResponse` | dependency closure, system packages, per-tool actions |
| `apply` | `ApplyRequest` | `ApplyResponse` | install/activate tools; report what is now installed |
| `verify` | `VerifyRequest` | `VerifyResponse` | per-tool health check for `doctor` |
| `apply-configs` | `ConfigApplyRequest` | `ConfigApplyResponse` | run config install steps + git checkouts after stowing |
| `uninstall` | `UninstallRequest` | `UninstallResponse` | remove release-owned tools; report kept system packages |
| `extract-dotfiles` | `ExtractDotfilesRequest` | `ExtractDotfilesResponse` | write the embedded dotfiles tree to a directory |

`metadata` is the only command that takes no input and touches nothing, which
is what makes installer *discovery* cheap: `dev-env` runs `metadata` against
every `installers/<release>/dev-env-install` it finds and skips any that fail,
report a mismatched release id, or speak another protocol.

## Compatibility rule

Compatibility is decided by `version` alone — there is no negotiation, no
capability list, and no minor-version tolerance:

```zig
if (found_protocol != version) return error.UnsupportedProtocol;
```

Checked in three places: on request parse (installer side), on every response
line header (client side), and on message body validation. An installer whose
protocol differs is invisible to `newestCompatible`, so a future release can
raise the version without breaking an older `dev-env` — it simply will not be
selected.

The practical consequence: **any change to a request or response struct is a
breaking change**, because `src/shared/json.zig` parses with unknown fields as
errors. Adding an optional field with a default still breaks *older installers
reading newer requests*. Bump `version` for anything but a purely additive
response field.

## Names are strings at the boundary

Tools and configs cross as plain strings (`"neovim"`, `"tmux-config"`), never as
enums. Inside the installer they map onto release-owned enums (`tools.ToolId`,
`tools.ConfigId`) via `resolver.toolByName` / `configByName`; an unmappable name
is a hard error.

This is what lets `dev-env` stay ignorant of the tool set. It also means the
*orchestrator can never validate a tool name itself* — it only knows the names
the selected installer advertised in `metadata`, which is exactly what
`planner.selectTools` checks against.

## Structural coupling in `ResolveResponse`

Two fields are positionally parallel and must stay the same length:

```zig
resolved_configs: []const []const u8,  // "neovim-config"
stow_packages:    []const []const u8,  // "nvim"
```

`resolved_configs[i]` is provided by `stow_packages[i]`. `dev-env` relies on
this to map a stow package back to its config name
(`apply.configForPackage`). The pairing is produced by a single loop in
`installer/planner.zig`, so it holds by construction, but it is an implicit
invariant that a type could express instead.

## Progress events

`ProgressEvent` is intentionally weakly typed — an `event` string plus optional
`tool`, `config`, `packages`, `tools`, and `detail`. The client renders known
event names (`install_started`, `build_finished`, `step_skipped`, …) and falls
back to a generic line for anything else, so a newer installer emitting new
event names does not break an older client. Progress is display-only: no
control flow depends on it.

## Environment exports

`EnvExport` carries `{name, value, mode}` where `mode` is `set` or
`prepend_path`. Values are `{home}`/`{opt}`/`{bin}`/`{cache_dir}`/`{prefix}`
templates (see `src/shared/templates.zig`), rendered on whichever side needs a
concrete path. They are stored *unrendered* in `installed.json` so relocating
the layout does not invalidate the receipt, and rendered at `dev-env exports`
time.

`dev-env exports` validates every name and value before printing
(`[A-Za-z_][A-Za-z0-9_]*`, no newlines), so a malicious or malformed export in
a receipt cannot inject extra lines into a shell's `eval`.
