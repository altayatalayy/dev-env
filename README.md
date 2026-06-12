# dev-env

Install on a target machine from a release server:

```sh
curl --fail --location --show-error http://server/releases/install.sh | bash -s -- --release-root-url http://server/releases
```

Build release artifacts (Ubuntu or Fedora builder):

```sh
release/build.sh ubuntu
release/build.sh fedora
```

Run the tests:

```sh
zig build test                              # unit/component tests
tests/scripts/run.sh --suite integration
tests/scripts/run.sh --suite e2e --target ubuntu
tests/scripts/run.sh --suite e2e --target fedora
```
