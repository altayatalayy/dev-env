# Tests

`zig build test` runs the catalog and library tests. The default container
suite builds the binaries and exercises the CLI lifecycle with a fake installer
on Ubuntu 24.04 x86_64:

```sh
test/scripts/test-container.sh
```

The release suite exercises real tool installers and downloads:

```sh
test/scripts/test-container.sh /opt/dev-env-test/e2e/release/run.sh
```

Release tests require network access and may install packages in the test
container. Lean proofs and their coverage documentation are maintained in
[dev-env-lib](https://github.com/altayatalayy/dev-env-lib).
