# dev-env

A self-contained installer for a personal development environment: language
toolchains, terminal tools, and their dotfiles, installed into a managed,
versioned layout under `~/.local`.

## Install

From GitHub Releases (resolves the latest release automatically):

```sh
curl --fail --location --show-error \
    https://raw.githubusercontent.com/altayatalayy/dev-env/main/install.sh \
    | bash -s -- --github altayatalayy/dev-env
```

From a self-hosted release server instead of GitHub:

```sh
curl --fail --location --show-error http://server/releases/install.sh \
    | bash -s -- --release-root-url http://server/releases
```

Uninstall the launcher and managed state (prompts for confirmation; pass
`--yes` to skip the prompt in non-interactive use):

```sh
install.sh --github altayatalayy/dev-env --uninstall
```

After install, `~/.local/bin/dev-env` is the entry point:

```sh
dev-env plan --tools tmux,neovim   # preview changes
dev-env apply                      # install/configure
dev-env doctor                     # verify installed state
dev-env upgrade                    # move to the newest installed release
dev-env uninstall                  # remove tools and configs
```

The managed Bash and Zsh startup files load `dev-env exports` when the shell
config is selected. The default all-tools plan and a plan including Git or
Neovim select it. Existing shell files are subject to the normal config
conflict policy; use `--config-conflict=backup` if you want dev-env to back
them up before stowing its versions.

## Build and test

The build uses a pinned `dev-env-lib` dependency from GitHub. The library
provides the generic CLI and installer engine and pins `zig-cli` and
`zig-graph`.
This repository keeps its tool and configuration definitions in
`src/installer/`, along with its dotfiles and environment tests.

Build and run unit tests (requires Zig 0.17):

```sh
zig build
zig build test --summary all
```

Run the fast fake-installer e2e suite on Ubuntu 24.04 amd64 by default. This
builds the Zig tests and native binaries once, then exercises the lifecycle
against a protocol-compatible fake installer:

```sh
test/scripts/test-container.sh
```

Run the heavier e2e suite that builds real tools:

```sh
test/scripts/test-container.sh /opt/dev-env-test/e2e/release/run.sh
```

## Release

Build all release artifacts locally (writes `build/releases/`):

```sh
release/build.sh
```

## CI/CD

- `.github/workflows/ci.yml` formats, tests, builds, and lints shell scripts on
  every push and pull request.
- `.github/workflows/release.yml` builds release artifacts and publishes them to
  GitHub Releases on a `v*` tag or manual dispatch.

## Documentation

The generic architecture, protocol, resolution, state model, and Lean proofs
are documented in [dev-env-lib](https://github.com/altayatalayy/dev-env-lib/tree/main/docs).
The supported platform is Ubuntu 24.04.
