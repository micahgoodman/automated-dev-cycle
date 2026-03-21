#!/bin/bash
#
# Install automated-dev-cycle tools for Claude Code
#
# This script symlinks skills, agents, and hooks into ~/.claude/

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

# Check required dependencies
missing_deps=()
if ! command -v jq &>/dev/null; then
  missing_deps+=("jq")
fi
if [ ${#missing_deps[@]} -gt 0 ]; then
  echo "ERROR: Missing required dependencies: ${missing_deps[*]}"
  echo
  echo "Install them first:"
  echo "  macOS:  brew install ${missing_deps[*]}"
  echo "  Ubuntu: sudo apt-get install ${missing_deps[*]}"
  echo "  Fedora: sudo dnf install ${missing_deps[*]}"
  exit 1
fi

echo "Installing automated-dev-cycle tools..."
echo "Source: $REPO_DIR"
echo "Target: $CLAUDE_DIR"
echo

# Create directories if needed
mkdir -p "$CLAUDE_DIR/agents" "$CLAUDE_DIR/skills" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/recursive-dev" "$CLAUDE_DIR/review-loop"

# Install agents (single .md files)
echo "Installing agents..."
for f in "$REPO_DIR"/agents/*.md; do
  [ -e "$f" ] || continue
  name=$(basename "$f")
  target="$CLAUDE_DIR/agents/$name"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "  - $name (overwriting existing file)"
  else
    echo "  - $name"
  fi
  ln -sf "$f" "$target"
done

# Install skills (directories containing SKILL.md)
echo "Installing skills..."
for d in "$REPO_DIR"/skills/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  target="$CLAUDE_DIR/skills/$name"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "  - $name (overwriting existing directory)"
  else
    echo "  - $name"
  fi
  rm -rf "$target"
  ln -sf "$d" "$target"
done

# Install hooks (shell scripts)
echo "Installing hooks..."
for f in "$REPO_DIR"/hooks/*.sh; do
  [ -e "$f" ] || continue
  name=$(basename "$f")
  target="$CLAUDE_DIR/hooks/$name"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "  - $name (overwriting existing file)"
  else
    echo "  - $name"
  fi
  ln -sf "$f" "$target"
done

# Install hooks/lib (directory)
if [ -d "$REPO_DIR/hooks/lib" ]; then
  target="$CLAUDE_DIR/hooks/lib"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "  - lib/ (overwriting existing directory)"
  else
    echo "  - lib/"
  fi
  rm -rf "$target"
  ln -sf "$REPO_DIR/hooks/lib" "$target"
fi

echo
echo "Done! Installed:"
echo "  Agents: $(ls "$REPO_DIR"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')"
echo "  Skills: $(ls -d "$REPO_DIR"/skills/*/ 2>/dev/null | wc -l | tr -d ' ')"
echo "  Hooks:  $(ls "$REPO_DIR"/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ') scripts + lib/"

# Verify installation
echo
errors=0
for f in "$REPO_DIR"/agents/*.md; do
  [ -e "$f" ] || continue
  name=$(basename "$f")
  if [ ! -L "$CLAUDE_DIR/agents/$name" ]; then
    echo "WARNING: Agent symlink missing: $CLAUDE_DIR/agents/$name"
    errors=$((errors + 1))
  fi
done
for d in "$REPO_DIR"/skills/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  if [ ! -L "$CLAUDE_DIR/skills/$name" ]; then
    echo "WARNING: Skill symlink missing: $CLAUDE_DIR/skills/$name"
    errors=$((errors + 1))
  fi
done
for f in "$REPO_DIR"/hooks/*.sh; do
  [ -e "$f" ] || continue
  name=$(basename "$f")
  if [ ! -L "$CLAUDE_DIR/hooks/$name" ]; then
    echo "WARNING: Hook symlink missing: $CLAUDE_DIR/hooks/$name"
    errors=$((errors + 1))
  fi
done
if [ ! -L "$CLAUDE_DIR/hooks/lib" ]; then
  echo "WARNING: Hook lib symlink missing: $CLAUDE_DIR/hooks/lib"
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo
  echo "Installation completed with $errors warning(s). Check the messages above."
else
  echo "All symlinks verified."
fi

# Check for settings.json configuration
echo
if [ ! -f "$CLAUDE_DIR/settings.json" ]; then
  echo "NEXT STEP: Configure hooks in ~/.claude/settings.json"
  echo "  cp settings.json.example ~/.claude/settings.json"
elif ! jq -e '.hooks.Stop' "$CLAUDE_DIR/settings.json" &>/dev/null || \
     ! jq -e '.hooks.UserPromptSubmit' "$CLAUDE_DIR/settings.json" &>/dev/null; then
  echo "NEXT STEP: Your ~/.claude/settings.json is missing required hook entries."
  echo "  See settings.json.example for the Stop and UserPromptSubmit hooks to add."
else
  echo "Hook configuration detected in ~/.claude/settings.json."
fi
