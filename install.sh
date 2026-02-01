#!/bin/bash
#
# Install automated-dev-cycle tools for Claude Code
#
# This script symlinks skills, agents, and hooks into ~/.claude/

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

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
  ln -sf "$f" "$CLAUDE_DIR/agents/$name"
  echo "  - $name"
done

# Install skills (directories containing SKILL.md)
echo "Installing skills..."
for d in "$REPO_DIR"/skills/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  # Remove existing directory or symlink
  rm -rf "$CLAUDE_DIR/skills/$name"
  ln -sf "$d" "$CLAUDE_DIR/skills/$name"
  echo "  - $name"
done

# Install hooks (shell scripts)
echo "Installing hooks..."
for f in "$REPO_DIR"/hooks/*.sh; do
  [ -e "$f" ] || continue
  name=$(basename "$f")
  ln -sf "$f" "$CLAUDE_DIR/hooks/$name"
  echo "  - $name"
done

# Install hooks/lib (directory)
if [ -d "$REPO_DIR/hooks/lib" ]; then
  rm -rf "$CLAUDE_DIR/hooks/lib"
  ln -sf "$REPO_DIR/hooks/lib" "$CLAUDE_DIR/hooks/lib"
  echo "  - lib/"
fi

echo
echo "Done! Installed:"
echo "  Agents: $(ls "$REPO_DIR"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')"
echo "  Skills: $(ls -d "$REPO_DIR"/skills/*/ 2>/dev/null | wc -l | tr -d ' ')"
echo "  Hooks:  $(ls "$REPO_DIR"/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ') scripts + lib/"
echo
echo "IMPORTANT: You must configure hooks in ~/.claude/settings.json"
echo "See settings.json.example in this repo for the required configuration."
