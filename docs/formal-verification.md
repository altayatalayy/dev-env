# Formal verification

The Lean models, proofs, runner, and detailed coverage documentation are
maintained in the sibling `dev-env-lib` repository. From that repository, run:

```sh
formal/run.sh
```

See `dev-env-lib/docs/formal-verification.md` for assumptions, proof coverage,
and the relationship to the Zig implementation. The proofs model generic
algorithms and an abstract lifecycle; they do not mechanically verify the Zig
code. In particular, a proof of a proposed checkpoint policy does not mean
that policy is implemented.

## Remaining obligations and priorities

The library documentation records the current verification limits and remaining
implementation obligations. Changes in this repository that affect generic
behavior should be reviewed against those models and their tests.
