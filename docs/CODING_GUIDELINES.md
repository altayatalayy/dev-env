# Coding Guidelines

## General

- Prefer simple, direct code over clever abstractions.
- Fail early and make errors explicit. Do not hide important failures.
- Remove dead code, unused helpers and files, repeated logic, and forwarding
  functions that only call another function.
- Keep modules focused and public APIs small.
- Prefer explicit control flow over hidden behavior.
- Introduce abstractions only when current requirements justify them.
- Use concise names that clearly describe purpose.
- Keep comments minimal. Explain only non-obvious intent, constraints, or
  tradeoffs, and remove outdated or redundant comments.
- Prefer long CLI options in scripts and documentation when supported.
- Make logs and error messages specific, useful, and actionable.
- Keep documentation and examples aligned with actual project behavior.

## Zig

- Target Zig 0.16 style and format code with `zig fmt`.
- Prefer tagged unions when alternatives carry different data or behavior. Use
  enums for plain closed sets.
- Use explicit error unions for expected failures.
- Prefer small, focused structs and functions.
- Use `std.log` for logging.
- Use `std.testing.allocator` when tests need allocation.
- Write deterministic tests with explicit setup and cleanup.
- Avoid global mutable state and unnecessary heap allocation.
- Make ownership and lifetimes clear at API boundaries.
- Validate inputs near boundaries.
- Prefer clear result and error shapes over implicit status flags.
- Do not comment obvious Zig syntax.

## Bash

- Do not use `set -euo pipefail` as a blanket policy.
- Check failures explicitly:

  ```bash
  if ! command --long-option; then
      echo "error: command failed" >&2
      exit 1
  fi
  ```

- For compact checks, use
  `tool --long-option || { echo "error: tool failed" >&2; exit 1; }`.
- Print errors to stderr and check required tools with `command -v`.
- Prefer long options when available.
- Quote variables unless unquoted expansion is deliberate.
- Use local variables in functions where appropriate.
- Keep scripts linear and readable, with minimal useful comments.
- Avoid hidden global side effects, unnecessary subshells, and unnecessary
  pipelines.
- Validate required inputs before doing work.
- Make destructive actions explicit.

## Docker

- Keep Dockerfiles minimal and purpose-specific.
- Never bake secrets, tokens, credentials, or private keys into images.
- Use `.dockerignore` to exclude unnecessary files.
- Prefer explicit base images and versions where practical.
- Set `ENV LANG=C.UTF-8` when an explicit locale is appropriate.
- For Ubuntu/Debian images, use
  `ARG DEBIAN_FRONTEND=noninteractive`.
- Install only required packages. Keep build and runtime dependencies clear.
- Combine related package-install steps when it improves clarity and image
  hygiene, and clean package-manager caches when appropriate.
- Use BuildKit bind or cache mounts for package-manager operations where
  useful, especially apt caches.
- Prefer reproducible, noninteractive builds that do not rely on host state.
- Keep entrypoints simple and use clear build-stage names.
- Separate development/test images from production/runtime images when their
  requirements differ.
- Use `COPY --chmod` and `COPY --chown` when copied files need permissions or
  ownership instead of separate `chmod` or `chown` layers.
- Use `COPY` for ordinary local files. Use `ADD` only when its behavior is
  intentional and clearer, such as archive extraction.

## Testing and CI

- Add source or unit tests for deterministic logic.
- Add integration, end-to-end, or container tests when behavior depends on
  installed binaries, OS paths, daemons, process lifecycle, host integration,
  or external tools.
- Test observable behavior and failure paths, not only happy paths.
- Avoid brittle timing assumptions.
- Prefer small fixtures and clean up test artifacts.
- Make CI failures produce useful logs and artifacts.
- Manual CI triggers are acceptable during early setup when clearly
  documented.
- Keep test documentation accurate.

## Documentation

- Use headings and short bullet lists.
- Keep explanations concise and avoid repeated guidance.
- Add short examples only when they clarify a rule.
- Write for both coding agents and human contributors.
