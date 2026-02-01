#!/bin/bash
#
# review-loop-stop.sh - Stop hook for self-reviewing Claude Code tasks
#
# This hook intercepts Claude's stop event and runs verification.
# It's a no-op when no review loop is active.
#

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/transcript.sh"
source "$SCRIPT_DIR/lib/verify.sh"

REVIEW_DIR="$HOME/.claude/review-loop"
CONFIG_FILE="$REVIEW_DIR/task.json"
STATE_FILE="$REVIEW_DIR/state.json"

# Check if a review loop is active
if [ ! -f "$CONFIG_FILE" ]; then
  # No review loop active, allow normal stop
  echo '{}'
  exit 0
fi

# Read config
CONFIG=$(cat "$CONFIG_FILE" 2>/dev/null)
if [ -z "$CONFIG" ]; then
  echo '{}'
  exit 0
fi

# Read state
STATE=$(cat "$STATE_FILE" 2>/dev/null)
if [ -z "$STATE" ]; then
  STATE='{"iteration": 0, "history": []}'
fi

ITERATION=$(echo "$STATE" | jq -r '.iteration // 0')
MAX=$(echo "$CONFIG" | jq -r '.maxIterations // 5')
AUTONOMOUS=$(echo "$CONFIG" | jq -r '.autonomous // false')
CHECKPOINT=$(echo "$CONFIG" | jq -r '.checkpointEachCycle // false')

# Run test command if configured
TEST_CMD=$(echo "$CONFIG" | jq -r '.testCommand // empty')
run_test_command "$TEST_CMD"

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Get transcript content using shared utility
TRANSCRIPT_CONTENT=$(read_transcript_auto "$HOOK_INPUT" 500)

# Extract criteria
CRITERIA=$(echo "$CONFIG" | jq -r '.criteria // ""')

# Build and run verification using shared utilities
REVIEW_PROMPT=$(build_review_prompt "$CRITERIA" "$TEST_OUTPUT" "$TEST_EXIT_CODE" "$TRANSCRIPT_CONTENT")
REVIEW=$(run_verification "$REVIEW_PROMPT")
parse_review_result "$REVIEW"

# Update state
NEW_ITERATION=$((ITERATION + 1))

# Build new history entry
HISTORY_ENTRY=$(jq -n \
  --argjson iteration "$NEW_ITERATION" \
  --argjson pass "$REVIEW_PASS" \
  --argjson issues "$REVIEW_ISSUES" \
  --arg summary "$REVIEW_SUMMARY" \
  '{iteration: $iteration, pass: $pass, issues: $issues, summary: $summary}')

# Update state file
echo "$STATE" | jq \
  --argjson iter "$NEW_ITERATION" \
  --argjson entry "$HISTORY_ENTRY" \
  '.iteration = $iter | .history += [$entry]' > "$STATE_FILE"

# Decision logic
if [ "$REVIEW_PASS" = "true" ]; then
  # Verification passed - allow stop, clean up
  rm -f "$CONFIG_FILE" "$STATE_FILE" 2>/dev/null || true
  echo '{}'
  exit 0
fi

# Build readable issues list for feedback
ISSUES_TEXT=$(format_issues "$REVIEW_ISSUES")
if [ -z "$ISSUES_TEXT" ]; then
  ISSUES_TEXT="$REVIEW_SUMMARY"
fi

if [ "$CHECKPOINT" = "true" ]; then
  # Checkpoint mode - block and ask user after each review
  FEEDBACK="[REVIEW LOOP] Cycle $NEW_ITERATION complete. Status: NEEDS WORK. Issues: $ISSUES_TEXT. Say 'done' to finish anyway, or provide guidance to continue."
  echo "$(hook_response false "$FEEDBACK")"
  exit 0
fi

if [ "$NEW_ITERATION" -ge "$MAX" ]; then
  if [ "$AUTONOMOUS" = "true" ]; then
    # Autonomous mode - stop with report
    REPORT="[REVIEW LOOP COMPLETE] Max iterations ($MAX) reached. Final status: INCOMPLETE. Remaining issues: $ISSUES_TEXT"
    rm -f "$CONFIG_FILE" "$STATE_FILE" 2>/dev/null || true
    echo '{}'
    exit 0
  else
    # Default - pause for user input
    FEEDBACK="[REVIEW LOOP] Attempted $NEW_ITERATION cycles but issues remain: $ISSUES_TEXT. Please provide guidance on how to proceed, or say 'done' to finish anyway."
    echo "$(hook_response false "$FEEDBACK")"
    exit 0
  fi
fi

# Not at max yet - block and continue with feedback
FEEDBACK="[REVIEW LOOP] Cycle $NEW_ITERATION of $MAX: Issues found - $ISSUES_TEXT. Please address these issues and continue working."
echo "$(hook_response false "$FEEDBACK")"
exit 0
