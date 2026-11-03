# Migration review handoff

Review the migration of `dev-env` and `dev-env-lib`. Read
`/home/aatalay4/projects/work/coding_guideline.md` and verify claims against the
code; documentation may be stale. Run dev-env only in containers.

The library owns the generic CLI, installer engine, protocol, documentation,
Lean models, and fake-installer lifecycle tests. The personal repository owns
its catalog, dotfiles, release tests, and installer build. It pins the public
library by commit and package hash. Ubuntu 24.04 is the only supported platform;
the incompatible platform and package schema changes use protocol version 3.

The migration is incomplete:

- Publish and bootstrap the generic CLI independently of personal installer
  releases, and provide a generic way to register an environment installer.
- Consume CI-built source artifacts during installation. Select by tool,
  version, and platform; verify the archive; fail clearly when it is missing.
  Test artifact relocation and ensure installation never silently builds source.
- Review state ownership, upgrade and uninstall behavior, failure recovery,
  artifact provenance, CI isolation, and the library's consumer-facing API.

The former TLA+ models were removed. Extend Lean coverage as needed for lifecycle
safety, fair progress, interrupted apply and uninstall, and ownership
checkpoints. Compare the abstract properties with the implementation and add
failure-injection tests; existing proofs do not verify filesystem operations.

The latest container checks passed 112 Zig tests, the fake-installer lifecycle
suite, and the Lean axiom audit. The user has no host installation to migrate.
The `dev-env-lib` tmux session points to `~/projects/personal/dev-env-lib`.
