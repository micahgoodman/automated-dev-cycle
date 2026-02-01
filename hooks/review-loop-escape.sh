#!/bin/bash
#
# review-loop-escape.sh - UserPromptSubmit hook for "done" escape hatch
#
# Allows user to say "done", "stop", "finish", etc. to exit the
# review loop even if issues remain.
#

REVIEW_DIR="$HOME/.claude/review-loop"
CONFIG_FILE="$REVIEW_DIR/task.json"
STATE_FILE="$REVIEW_DIR/state.json"

# Check if a review loop is active
if [ ! -f "$CONFIG_FILE" ]; then
  # No review loop active, allow normal prompt
  echo '{"continue": true}'
  exit 0
fi

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract the user's prompt
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.prompt // ""' 2>/dev/null)

# Check if user wants to escape the loop
# Match: done, stop, finish, exit, quit (case insensitive, with optional punctuation)
if echo "$PROMPT" | grep -qiE '^[[:space:]]*(done|stop|finish|exit|quit)[[:space:]!.]*$'; then
  # User wants to exit - clean up the review loop
  rm -f "$CONFIG_FILE" "$STATE_FILE" 2>/dev/null || true

  # Allow the prompt to continue (Claude will receive it and can respond appropriately)
  echo '{"continue": true}'
  exit 0
fi

# Not an escape command, allow normal processing
echo '{"continue": true}'
exit 0
