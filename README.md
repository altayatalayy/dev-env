# dev-env

Install on a target machine from a release server:

```sh
curl --fail --location --show-error http://server/releases/install.sh | bash -s -- --release-root-url http://server/releases
```

Build all release artifacts:

```sh
release/build.sh
```

Run the normal test matrix. This builds the Zig unit/component tests once, builds the native x86_64 Linux binaries, then runs the fast fake-installer e2e suite against the supported amd64 Linux targets: Ubuntu 24.04, Ubuntu 26.04, and Fedora 44.

```sh
test/scripts/test-container.sh
```

Run only selected targets or the heavier e2e suite:

```sh
TEST_TARGETS="ubuntu-24.04-x86_64 fedora-44-x86_64" test/scripts/test-container.sh
test/scripts/test-container.sh /opt/dev-env-test/e2e/release/run.sh
```
