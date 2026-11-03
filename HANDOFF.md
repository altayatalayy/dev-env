# Migration review handoff

Review the migration of this project into `dev-env-lib` and the personal
`dev-env` environment. Read `/home/aatalay4/projects/work/coding_guideline.md`
and inspect the actual code; documentation can be stale. Preserve existing
uncommitted work and do not assume it belongs to the migration.

The intended boundary is:

- `dev-env-lib` owns the generic CLI, protocol, resolver, lifecycle, build
  tooling, generic tests, and library release pipeline.
- `dev-env` owns personal tool and config definitions, dotfiles, the installer
  built against the library, environment tests, and its release pipeline.
- The generic CLI is installed separately, registers environment releases,
  and supports local installers and artifacts for testing.
- CI builds source artifacts; installation selects and verifies them. Keep
  backend platform support, while limiting build and test matrices to Ubuntu
  24.04 for now.
- If a prebuilt artifact is missing for a platform, fail with a clear error.

Review protocol and state compatibility, environment identity and ownership,
upgrade and uninstall behavior, failure recovery, artifact provenance and
checksums, and CI isolation. Run
the relevant unit and integration tests and report specific findings with file
and line references. Do not publish or modify files unless instructed.

At handoff, `zig version` is 0.17.0. The working tree updates the two Zig
dependency pins and `EnumSet` initialization for 0.17; `zig build test
--summary all` passed 116 tests. CI and container builders now target 0.17,
and the default release and test matrix is Ubuntu 24.04 x86_64. The container
fake-installer integration suite passed with the sibling library dependency.
The existing tree also has uncommitted documentation, CI, and dotfile changes.
The user has no host installation to migrate and requests that dev-env only be
run in containers for now. The requested
`dev-env-lib` tmux session points to `~/projects/personal/dev-env-lib`. That
directory contains an incomplete extraction prototype: its generic CLI builds
and its shared and frontend tests pass. An isolated consumer prototype in
`/tmp/dev-env-migration/app` builds the personal installer using the extracted
modules. The working `dev-env` build pins the published library and builds the
generic CLI from it. Artifact consumption is not implemented.
The generic source copies have been removed from `dev-env`; its catalog and
environment IDs remain there. The public GitHub repository
`altayatalayy/dev-env-lib` contains the initial extraction commit `b9ebf6b`.

The Lean suite, including the uncommitted proof changes, was moved to
`dev-env-lib/formal`; its clean build and axiom audit passed. The library
directory is a Git repository and its initial contents have been pushed. The
TLA+ models remain in `dev-env/formal/tla` until they are transferred.

Tool and config ID types now come from a build-supplied module. Installer apply,
verify, and uninstall receive catalog definitions explicitly. The library API
and planner receive the catalog as a supplied module. Some installer tests still
depend on personal definitions; those boundaries need further work.
