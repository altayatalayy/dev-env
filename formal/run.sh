#!/usr/bin/env bash
# Runs every machine-checked proof and model in this directory.
#
#   formal/run.sh          # Lean proofs, then the TLA+ models
#   formal/run.sh lean     # Lean only
#   formal/run.sh tla      # TLA+ only
#
# See docs/formal-verification.md for what each artifact establishes.

if ! SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"; then
    echo "failed to locate script directory" >&2
    exit 1
fi

TLA_TOOLS_URL="https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar"
TLA_JAR="${SCRIPT_DIR}/tla/.tools/tla2tools.jar"
WHAT="${1:-all}"
STATUS=0

run_lean() {
    echo "==> Lean"
    if [ ! -f "${HOME}/.elan/env" ]; then
        echo "error: elan not found; install Lean via https://lean-lang.org/install/" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    . "${HOME}/.elan/env"

    if ! command -v lake >/dev/null 2>&1; then
        echo "error: lake not on PATH after sourcing elan env" >&2
        return 1
    fi

    if ! (cd "${SCRIPT_DIR}/lean" && lake build); then
        echo "error: lean proofs failed to build" >&2
        return 1
    fi

    # Guard against `sorry` and against `native_decide`, which would make a
    # proof depend on the compiler rather than the kernel.
    echo "--> axiom check"
    if ! (cd "${SCRIPT_DIR}/lean" && LEAN_PATH=.lake/build/lib/lean lean Check.lean > /tmp/devenv-axioms.txt); then
        echo "error: axiom check failed" >&2
        return 1
    fi
    if grep -qE "sorryAx|ofReduceBool" /tmp/devenv-axioms.txt; then
        echo "error: a theorem depends on sorry or native_decide:" >&2
        grep -E "sorryAx|ofReduceBool" /tmp/devenv-axioms.txt >&2
        return 1
    fi
    echo "all theorems depend only on propext / Classical.choice / Quot.sound"
    return 0
}

ensure_tla_tools() {
    if [ -f "${TLA_JAR}" ]; then
        return 0
    fi
    if ! command -v java >/dev/null 2>&1; then
        echo "error: java is required to run TLC" >&2
        return 1
    fi
    echo "--> downloading tla2tools.jar"
    if ! mkdir --parents "$(dirname "${TLA_JAR}")"; then
        echo "error: failed to create ${TLA_JAR%/*}" >&2
        return 1
    fi
    if ! curl --fail --location --show-error --silent "${TLA_TOOLS_URL}" --output "${TLA_JAR}"; then
        echo "error: failed to download ${TLA_TOOLS_URL}" >&2
        return 1
    fi
}

# Runs one config and checks it against the outcome we expect.
# usage: check_model <config> pass|fail
check_model() {
    local config="$1"
    local expect="$2"
    local output

    echo "--> ${config} (expect ${expect})"
    output="$(cd "${SCRIPT_DIR}/tla" && java -XX:+UseParallelGC -cp .tools/tla2tools.jar \
        tlc2.TLC -config "${config}" -workers auto -deadlock -cleanup DevEnvApply.tla 2>&1)"

    if echo "${output}" | grep -qE "^Error: (Invariant|Temporal properties)"; then
        if [ "${expect}" = "fail" ]; then
            echo "${output}" | grep -E "^Error: (Invariant|Temporal properties)" | sed 's/^/    /'
            return 0
        fi
        echo "error: ${config} found a violation but was expected to pass" >&2
        echo "${output}" | tail -40 >&2
        return 1
    fi

    if echo "${output}" | grep -q "Model checking completed. No error has been found."; then
        if [ "${expect}" = "pass" ]; then
            echo "${output}" | grep "distinct states found" | tail -1 | sed 's/^/    /'
            return 0
        fi
        echo "error: ${config} passed but was expected to find a violation" >&2
        return 1
    fi

    echo "error: ${config} produced no usable TLC verdict" >&2
    echo "${output}" | tail -40 >&2
    return 1
}

run_tla() {
    echo "==> TLA+"
    if ! ensure_tla_tools; then
        return 1
    fi
    local rc=0
    # MC_current documents the defects: it is expected to find them.
    check_model MC_current.cfg fail || rc=1
    check_model MC_fixed.cfg pass || rc=1
    check_model MC_liveness.cfg pass || rc=1
    return "${rc}"
}

case "${WHAT}" in
    lean) run_lean || STATUS=1 ;;
    tla) run_tla || STATUS=1 ;;
    all)
        run_lean || STATUS=1
        echo
        run_tla || STATUS=1
        ;;
    *)
        echo "usage: $0 [all|lean|tla]" >&2
        exit 1
        ;;
esac

echo
if [ "${STATUS}" -eq 0 ]; then
    echo "formal checks: OK"
else
    echo "formal checks: FAILED" >&2
fi
exit "${STATUS}"
