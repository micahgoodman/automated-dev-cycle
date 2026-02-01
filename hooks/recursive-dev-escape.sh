#!/bin/bash
#
# recursive-dev-escape.sh - UserPromptSubmit hook for recursive-dev escape commands
#
# Detects escape commands and cleans up the recursive-dev session.
#

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/transcript.sh"

RECURSIVE_DIR="$HOME/.claude/recursive-dev"

# Read the user's input from stdin
USER_INPUT=$(cat)

# Try to find session via transcript-based detection (same as stop hook)
SESSION_ID=$(get_recursive_dev_session "$USER_INPUT" "$RECURSIVE_DIR")

# Fallback to env var for backwards compatibility
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="${CLAUDE_RECURSIVE_DEV_SESSION:-}"
fi
PROMPT=$(echo "$USER_INPUT" | jq -r '.prompt // ""' 2>/dev/null)

# Normalize for comparison (lowercase, trim whitespace)
NORMALIZED=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]' | xargs)

# Check for escape commands
case "$NORMALIZED" in
  "recursive-dev done"|"recursive-dev stop"|"recursive-dev finish"|"recursive-dev exit"|"recursive-dev quit")
    # User wants to exit
    if [ -n "$SESSION_ID" ] && [ -d "$RECURSIVE_DIR/$SESSION_ID" ]; then
      # Read final state for summary
      STATE_FILE="$RECURSIVE_DIR/$SESSION_ID/state.json"
      if [ -f "$STATE_FILE" ]; then
        STATE=$(cat "$STATE_FILE")
        COMPLETED=$(echo "$STATE" | jq '[.taskStatuses | to_entries[] | select(.value == "completed")] | length')
        TOTAL=$(echo "$STATE" | jq '[.taskStatuses | to_entries[]] | length')

        # Keep state files for potential resume (don't delete)
        # Mark session as stopped by clearing currentTask and currentReviewTask
        # This ensures the stop hook won't continue the session
        NEW_STATE=$(echo "$STATE" | jq '.currentTask = null | .currentReviewTask = null | .stopped = true' 2>/dev/null)

        # Only write if we got valid JSON back (safeguard against wiping the file)
        if [ -n "$NEW_STATE" ] && echo "$NEW_STATE" | jq -e . >/dev/null 2>&1; then
          echo "$NEW_STATE" > "$STATE_FILE"
        fi

        echo "{\"continue\": true, \"outputToUser\": \"[RECURSIVE-DEV] Session ended. Completed $COMPLETED of $TOTAL tasks. State preserved in ~/.claude/recursive-dev/$SESSION_ID/\"}"
      else
        echo '{"continue": true, "outputToUser": "[RECURSIVE-DEV] Session ended."}'
      fi
    else
      echo '{"continue": true}'
    fi
    exit 0
    ;;
  *)
    # Not an escape command, continue normally
    echo '{"continue": true}'
    exit 0
    ;;
esac
