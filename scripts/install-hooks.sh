#!/usr/bin/env bash
# Installs the git hooks from scripts/hooks/ into .git/hooks/ (symlinks, so
# edits to the scripts take effect immediately). Run once per clone:
#
#   bash scripts/install-hooks.sh      (or: pnpm hooks:install)
#
# Hooks are local config and are not cloned; without them a push runs no
# checks and stages no iOS build. See docs/ci-cd.md.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS_SRC="$REPO_ROOT/scripts/hooks"
HOOKS_DEST="$(git rev-parse --git-path hooks)"
case "$HOOKS_DEST" in /*) ;; *) HOOKS_DEST="$REPO_ROOT/$HOOKS_DEST" ;; esac
HOOKS="pre-commit pre-push prepare-commit-msg commit-msg"

if [ -t 1 ]; then GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'; else GREEN=""; YELLOW=""; NC=""; fi

# A custom core.hooksPath would make git ignore .git/hooks entirely.
if hooks_path="$(git config --get core.hooksPath)"; then
  echo "${YELLOW}!${NC} core.hooksPath is set to '$hooks_path'; unsetting it so .git/hooks is used."
  git config --unset core.hooksPath
fi

mkdir -p "$HOOKS_DEST"
for name in $HOOKS; do
  src="$HOOKS_SRC/$name"
  dest="$HOOKS_DEST/$name"
  [ -f "$src" ] || { echo "missing $src" >&2; exit 1; }
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    echo "  Backing up existing $name -> $name.bak"
    mv "$dest" "$dest.bak"
  fi
  chmod +x "$src"
  ln -sf "$src" "$dest"
  echo "${GREEN}ok${NC} $name"
done
chmod +x "$REPO_ROOT"/scripts/ci/*.sh 2>/dev/null || true

cat <<'EOF'

Git hooks installed.
  pre-commit          staged files only: secrets guard, append-only migrations,
                      eslint / deno lint / ruff / shellcheck / actionlint
  pre-push            CI mirror for the changed areas (lint, test, build,
                      pgTAP if the local stack runs, swift test); on a push to
                      main that changes the iOS app, stages the TestFlight build
  prepare-commit-msg  enforce the commit author identity
  commit-msg          enforce the author, reject Co-Authored-By trailers

Escape hatches: SKIP_PRE_PUSH=1 git push · SKIP_RELEASE=1 git push · --no-verify
Run by hand:    pnpm check · pnpm check:all · pnpm check:plan
EOF

echo
echo "Toolchain (missing tools make their checks skip or warn, CI still runs them):"
for tool in pnpm deno supabase docker uv swift actionlint shellcheck jq gh; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  %sok%s %s\n' "$GREEN" "$NC" "$tool"
  else
    printf '  %s--%s %s\n' "$YELLOW" "$NC" "$tool"
  fi
done
