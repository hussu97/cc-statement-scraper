#!/usr/bin/env bash
# Installs git hooks from scripts/hooks/ into .git/hooks/
# Run once after cloning: bash scripts/install-hooks.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS_SRC="$REPO_ROOT/scripts/hooks"
HOOKS_DEST="$REPO_ROOT/.git/hooks"

GREEN='\033[0;32m'
NC='\033[0m'

for hook in "$HOOKS_SRC"/*; do
  name="$(basename "$hook")"
  dest="$HOOKS_DEST/$name"

  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    echo "  Backing up existing $name → $name.bak"
    mv "$dest" "$dest.bak"
  fi

  ln -sf "$hook" "$dest"
  chmod +x "$hook"
  echo -e "${GREEN}✓${NC} Installed $name"
done

echo -e "\n${GREEN}Git hooks installed.${NC}"
echo "  pre-commit : fast checks (syntax, bandit, eslint)"
echo "  prepare-commit-msg : enforce commit author identity"
echo "  commit-msg : enforce commit author identity"
echo "  pre-push   : full CI mirror (tests, build)"
echo ""
echo "Skip verification checks when needed: git commit --no-verify / git push --no-verify"
echo "Author identity is still enforced by prepare-commit-msg."
