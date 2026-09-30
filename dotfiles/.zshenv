# shellcheck shell=bash
# dev-env managed zsh environment (the syntax below is shared with Bash)

export EDITOR="${EDITOR:-nvim}"
export VISUAL="${VISUAL:-$EDITOR}"
export PATH="$HOME/.local/bin:$PATH"

# `dev-env exports` emits validated NAME=value lines. Read them as data so
# values never become shell code.
if command -v dev-env >/dev/null 2>&1; then
    while IFS='=' read -r name value; do
        export "$name=$value"
    done < <(dev-env exports 2>/dev/null)
fi
