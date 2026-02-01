#!/bin/bash
#
# recursive-dev-stop.sh - Stop hook for recursive development system
#
# Enforces depth-first, branch-complete execution with verification at every level.
# Integrates code-path-diagrammer for planning and diagnosis.
#

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/transcript.sh"
source "$SCRIPT_DIR/lib/verify.sh"

# Configuration
RECURSIVE_DIR="$HOME/.claude/recursive-dev"
AGENT_FILE="$HOME/.claude/agents/code-path-diagrammer.md"

# Read hook input from stdin FIRST (needed for transcript-based session detection)
HOOK_INPUT=$(cat)

# Debug logging
DEBUG_LOG="/tmp/recursive-dev-stop-debug.log"
{
  echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') Hook invoked ==="
  echo "PWD: $(pwd)"
  echo "RECURSIVE_DIR: $RECURSIVE_DIR"
} >> "$DEBUG_LOG" 2>/dev/null

# Get session ID by checking if user invoked /recursive-dev in this conversation.
# Only checks USER messages (not assistant output or system messages).
# Then verifies there's an active session for the current project directory.
SESSION_ID=$(get_recursive_dev_session "$HOOK_INPUT" "$RECURSIVE_DIR")
echo "Transcript-based SESSION_ID: '$SESSION_ID'" >> "$DEBUG_LOG" 2>/dev/null

# Fallback to env var if set (for backwards compatibility / manual override)
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="${CLAUDE_RECURSIVE_DEV_SESSION:-}"
  echo "Env var SESSION_ID: '$SESSION_ID'" >> "$DEBUG_LOG" 2>/dev/null
fi

# Fallback: If transcript detection failed (e.g., conversation compacted),
# look for any active session matching current project directory.
# This is less strict but necessary for resumed conversations.
if [ -z "$SESSION_ID" ]; then
  CURRENT_DIR=$(pwd)
  echo "Fallback: scanning for sessions matching CURRENT_DIR='$CURRENT_DIR'" >> "$DEBUG_LOG" 2>/dev/null
  for session_dir in "$RECURSIVE_DIR"/*/; do
    [ -d "$session_dir" ] || continue
    tree_file="$session_dir/tree.json"
    state_file="$session_dir/state.json"

    echo "  Checking session_dir: $session_dir" >> "$DEBUG_LOG" 2>/dev/null

    if [ ! -f "$tree_file" ] || [ ! -f "$state_file" ]; then
      echo "    Missing tree.json or state.json, skipping" >> "$DEBUG_LOG" 2>/dev/null
      continue
    fi

    # Check project directory matches
    project_dir=$(jq -r '.projectDir // empty' "$tree_file" 2>/dev/null)
    echo "    projectDir from tree.json: '$project_dir'" >> "$DEBUG_LOG" 2>/dev/null

    if [ "$project_dir" != "$CURRENT_DIR" ]; then
      echo "    projectDir mismatch, skipping" >> "$DEBUG_LOG" 2>/dev/null
      continue
    fi

    # Check session is active (has currentTask or currentReviewTask)
    current_task=$(jq -r '.currentTask // empty' "$state_file" 2>/dev/null)
    current_review=$(jq -r '.currentReviewTask // empty' "$state_file" 2>/dev/null)
    phase=$(jq -r '.phase // empty' "$state_file" 2>/dev/null)
    echo "    phase: '$phase', currentTask: '$current_task', currentReviewTask: '$current_review'" >> "$DEBUG_LOG" 2>/dev/null

    # Try to recover from backup if state seems corrupted
    if [ -z "$phase" ] || [ -z "$current_task$current_review" ]; then
      backup_file="${state_file}.backup"
      if [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
        echo "    State appears corrupted, trying backup..." >> "$DEBUG_LOG" 2>/dev/null
        backup_phase=$(jq -r '.phase // empty' "$backup_file" 2>/dev/null)
        if [ -n "$backup_phase" ]; then
          echo "    Recovering from backup (phase=$backup_phase)" >> "$DEBUG_LOG" 2>/dev/null
          cp "$backup_file" "$state_file"
          current_task=$(jq -r '.currentTask // empty' "$state_file" 2>/dev/null)
          current_review=$(jq -r '.currentReviewTask // empty' "$state_file" 2>/dev/null)
          phase=$(jq -r '.phase // empty' "$state_file" 2>/dev/null)
        fi
      fi
    fi

    if { [ -n "$current_task" ] && [ "$current_task" != "null" ]; } || \
       { [ -n "$current_review" ] && [ "$current_review" != "null" ]; }; then
      SESSION_ID=$(basename "$session_dir")
      echo "    MATCH! SESSION_ID='$SESSION_ID'" >> "$DEBUG_LOG" 2>/dev/null
      break
    else
      echo "    No active task, skipping" >> "$DEBUG_LOG" 2>/dev/null
    fi
  done
fi

echo "Final SESSION_ID: '$SESSION_ID'" >> "$DEBUG_LOG" 2>/dev/null

# Check if recursive-dev session is active
if [ -z "$SESSION_ID" ]; then
  # No active session found for this project, allow normal stop
  echo "No session found, allowing stop" >> "$DEBUG_LOG" 2>/dev/null
  echo '{}'
  exit 0
fi

echo "Session found, continuing with hook logic" >> "$DEBUG_LOG" 2>/dev/null

SESSION_DIR="$RECURSIVE_DIR/$SESSION_ID"
TREE_FILE="$SESSION_DIR/tree.json"
STATE_FILE="$SESSION_DIR/state.json"

# Verify session files exist
if [ ! -f "$TREE_FILE" ] || [ ! -f "$STATE_FILE" ]; then
  # Session files missing, allow normal stop
  echo '{}'
  exit 0
fi

# Read tree and state
TREE=$(cat "$TREE_FILE" 2>/dev/null)
STATE=$(cat "$STATE_FILE" 2>/dev/null)

if [ -z "$TREE" ] || [ -z "$STATE" ]; then
  echo "TREE or STATE empty, allowing stop" >> "$DEBUG_LOG" 2>/dev/null
  echo '{}'
  exit 0
fi

# Debug: Log phase and current task info
{
  echo "TREE_FILE: $TREE_FILE"
  echo "STATE_FILE: $STATE_FILE"
  echo "PHASE: $(echo "$STATE" | jq -r '.phase // "dev"')"
  echo "currentTask: $(echo "$STATE" | jq -r '.currentTask // "null"')"
  echo "currentReviewTask: $(echo "$STATE" | jq -r '.currentReviewTask // "null"')"
} >> "$DEBUG_LOG" 2>/dev/null

# ─── REVIEW PHASE ───────────────────────────────────────────────────────────
# Check phase BEFORE any dev-phase logic. When dev completes, phase is set to
# "review" and currentTask becomes null.
#
# SUBAGENT APPROACH: The hook orchestrates, the model does the review work.
# - Hook checks for REVIEW_RESULT in transcript (from model's previous turn)
# - If found: parse, record, advance to next task
# - Hook injects instruction for model to review next task via Task tool
# - Model spawns review subagent (fresh context), outputs REVIEW_RESULT
# - Cycle repeats until all tasks reviewed
#
# This avoids claude -p subprocess issues (timeouts, rate limits) by using
# Claude Code's native Task tool infrastructure.
PHASE=$(echo "$STATE" | jq -r '.phase // "dev"')
echo "Entering phase check: PHASE='$PHASE'" >> "$DEBUG_LOG" 2>/dev/null

if [ "$PHASE" = "review" ]; then
  echo "In REVIEW phase block" >> "$DEBUG_LOG" 2>/dev/null
  CURRENT_REVIEW_TASK=$(echo "$STATE" | jq -r '.currentReviewTask // empty')
  echo "CURRENT_REVIEW_TASK='$CURRENT_REVIEW_TASK'" >> "$DEBUG_LOG" 2>/dev/null

  # ─── FINAL SUMMARY OR SPECIAL REVIEWS ───────────────────────────────────────
  if [ -z "$CURRENT_REVIEW_TASK" ] || [ "$CURRENT_REVIEW_TASK" = "null" ]; then
    HOLISTIC_DONE=$(echo "$STATE" | jq -r '.holisticReviewDone // false')
    VALIDATION_DONE=$(echo "$STATE" | jq -r '.validationReviewDone // false')

    if [ "$HOLISTIC_DONE" = "true" ] && [ "$VALIDATION_DONE" = "true" ]; then
      # All done including holistic and validation reviews — output final summary
      REVIEW_SUMMARY_TEXT=$(echo "$STATE" | jq -r '
        .reviewHistory // [] |
        group_by(.task) | map(last) |
        map("- \(.task): \(.issuesFound // 0) issue(s), \(.fixesApplied // 0) fix(es). \(.summary // "")") |
        join("\n")
      ')
      TOTAL_ISSUES=$(echo "$STATE" | jq '[.reviewHistory // [] | group_by(.task) | map(last) | .[].issuesFound // 0] | add // 0')
      TOTAL_FIXES=$(echo "$STATE" | jq '[.reviewHistory // [] | group_by(.task) | map(last) | .[].fixesApplied // 0] | add // 0')

      FEEDBACK="[RECURSIVE-DEV REVIEW] All reviews complete!

Summary: $TOTAL_ISSUES issue(s) found, $TOTAL_FIXES fix(es) applied.

Per-task results:
$REVIEW_SUMMARY_TEXT"

      echo "$(hook_response true "$FEEDBACK")"
      exit 0
    fi

    if [ "$HOLISTIC_DONE" != "true" ]; then
      # Per-task reviews done, but holistic review not done yet
      STATE=$(echo "$STATE" | jq '.currentReviewTask = "HOLISTIC"')
      echo "$STATE" > "$STATE_FILE"
      CURRENT_REVIEW_TASK="HOLISTIC"
    elif [ "$VALIDATION_DONE" != "true" ]; then
      # Holistic review done, but validation review not done yet
      STATE=$(echo "$STATE" | jq '.currentReviewTask = "VALIDATION"')
      echo "$STATE" > "$STATE_FILE"
      CURRENT_REVIEW_TASK="VALIDATION"
    fi
  fi

  # ─── HOLISTIC REVIEW (after all per-task reviews) ────────────────────────────
  if [ "$CURRENT_REVIEW_TASK" = "HOLISTIC" ]; then
    # Get project info for the holistic review
    PROJECT_DIR=$(echo "$TREE" | jq -r '.projectDir // empty')
    [ -z "$PROJECT_DIR" ] || [ "$PROJECT_DIR" = "null" ] && PROJECT_DIR=$(pwd)
    PLAN_FILE=$(echo "$TREE" | jq -r '.planFile // empty')

    # Get all modified files across all tasks
    ALL_FILES=$(echo "$STATE" | jq -r '
      .modifiedFiles // {} | to_entries | map(.value) | flatten | unique | join(", ")
    ')
    [ -z "$ALL_FILES" ] && ALL_FILES="No specific files recorded"

    # Get per-task review summary
    PER_TASK_SUMMARY=$(echo "$STATE" | jq -r '
      .reviewHistory // [] |
      group_by(.task) | map(last) |
      map("- \(.task): \(.issuesFound // 0) issue(s), \(.fixesApplied // 0) fix(es)") |
      join("\n")
    ')

    FEEDBACK="[RECURSIVE-DEV REVIEW] Per-task reviews complete. Now running final holistic review.

Use the Task tool to spawn a review subagent with fresh context:

Task(
  subagent_type: \"general-purpose\",
  description: \"Holistic review of all changes\",
  prompt: \"You are doing a final holistic review of all changes made during this development phase. Review with fresh eyes — you have no context about how anything was implemented.

PROJECT DIRECTORY: $PROJECT_DIR
ALL FILES MODIFIED: $ALL_FILES

PER-TASK REVIEW SUMMARY:
$PER_TASK_SUMMARY

HOLISTIC REVIEW INSTRUCTIONS:

Review all the changes for this phase with fresh eyes, as if they were written by someone else, keeping in mind the goals and principles for this task, to make sure everything is solid — check for any gaps, any bugs, any cleanup needed, or any other key improvements to arrive at simple and robust code that works well for real-world users.

There may be many changes needed and that's completely ok, or there may be none needed and that's also completely ok (or anywhere in between). If you find anything wrong from before this phase, fix that too since it's important to leave the code better than we found it.

Focus on:
1. How all the pieces fit together as a whole
2. Consistency across the codebase
3. Patterns that should be unified
4. Integration issues between components
5. Anything the per-task reviews might have missed

After reviewing, summarize what you found and any fixes you made.\"
)

After the Task completes, output EXACTLY this line (with your results filled in):
REVIEW_RESULT: {\"task\": \"HOLISTIC\", \"issues\": <number>, \"fixes\": <number>, \"summary\": \"<brief summary>\"}

Then stop and wait for the final summary."

    echo "$(hook_response false "$FEEDBACK")"
    exit 0
  fi

  # ─── VALIDATION REVIEW (after holistic review) ───────────────────────────────
  if [ "$CURRENT_REVIEW_TASK" = "VALIDATION" ]; then
    # Get project info for the validation review
    PROJECT_DIR=$(echo "$TREE" | jq -r '.projectDir // empty')
    [ -z "$PROJECT_DIR" ] || [ "$PROJECT_DIR" = "null" ] && PROJECT_DIR=$(pwd)

    # Get all modified files across all tasks
    ALL_FILES=$(echo "$STATE" | jq -r '
      .modifiedFiles // {} | to_entries | map(.value) | flatten | unique | join(", ")
    ')
    [ -z "$ALL_FILES" ] && ALL_FILES="No specific files recorded"

    # Get review summary so far
    REVIEW_SUMMARY=$(echo "$STATE" | jq -r '
      .reviewHistory // [] |
      group_by(.task) | map(last) |
      map("- \(.task): \(.issuesFound // 0) issue(s), \(.fixesApplied // 0) fix(es)") |
      join("\n")
    ')

    FEEDBACK="[RECURSIVE-DEV REVIEW] Holistic review complete. Now running validation review.

Use the Task tool to spawn a review subagent with fresh context:

Task(
  subagent_type: \"general-purpose\",
  description: \"Validation review of all changes\",
  prompt: \"You are doing a validation review to confirm the work is solid before moving to the next phase. Review with fresh eyes — you have no context about how anything was implemented.

PROJECT DIRECTORY: $PROJECT_DIR
ALL FILES MODIFIED: $ALL_FILES

REVIEW SUMMARY SO FAR:
$REVIEW_SUMMARY

VALIDATION REVIEW INSTRUCTIONS:

Since this project is a big undertaking, we should find a way to confirm as much as possible that the work in each phase is solid before moving onto the next phase, to avoid only testing at the end and having many more changes and variables to account for.

Given this phase of work, is there a way to check the work so far, to make it more likely that we catch something now instead of only after putting all the pieces together?

Focus on:
1. **Test coverage** — Not only checking that tests pass, but also that we have all the tests we need to evaluate the code (and they're all written to achieve that)
2. **Edge cases** — Are there scenarios that aren't covered?
3. **Error handling** — What happens when things go wrong?
4. **Integration points** — Will this work correctly when connected to other parts?
5. **Assumptions** — What assumptions is this code making that should be validated?

If you identify gaps, either fix them directly or note what additional work would be needed.

After reviewing, summarize what you found and any fixes you made.\"
)

After the Task completes, output EXACTLY this line (with your results filled in):
REVIEW_RESULT: {\"task\": \"VALIDATION\", \"issues\": <number>, \"fixes\": <number>, \"summary\": \"<brief summary>\"}

Then stop and wait for the final summary."

    echo "$(hook_response false "$FEEDBACK")"
    exit 0
  fi

  # ─── CHECK FOR REVIEW_RESULT FROM MODEL'S PREVIOUS TURN ─────────────────────
  # Format: REVIEW_RESULT: {"task": "T1.1", "issues": N, "fixes": N, "summary": "..."}
  # The REVIEW_RESULT is in the transcript file (JSONL format).
  # Extract text content from recent assistant messages and search for REVIEW_RESULT.
  DEBUG_LOG="/tmp/recursive-dev-review-debug.log"
  TRANSCRIPT_PATH=$(get_transcript_path "$HOOK_INPUT")
  REVIEW_RESULT_LINE=""

  {
    echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') REVIEW_RESULT check ==="
    echo "CURRENT_REVIEW_TASK: $CURRENT_REVIEW_TASK"
    echo "TRANSCRIPT_PATH: $TRANSCRIPT_PATH"
  } >> "$DEBUG_LOG" 2>/dev/null

  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Extract text from recent assistant messages and search for REVIEW_RESULT.
    # The transcript is JSONL, so we need to parse it properly.
    REVIEW_RESULT_LINE=$(tail -50 "$TRANSCRIPT_PATH" 2>/dev/null | \
      jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null | \
      grep 'REVIEW_RESULT:' | tail -1)

    # Fallback: try raw grep if jq parsing fails (in case format differs)
    if [ -z "$REVIEW_RESULT_LINE" ]; then
      REVIEW_RESULT_LINE=$(tail -100 "$TRANSCRIPT_PATH" 2>/dev/null | grep -o 'REVIEW_RESULT: *{[^}]*}' | tail -1)
      echo "Used fallback grep" >> "$DEBUG_LOG" 2>/dev/null
    fi
  fi

  echo "REVIEW_RESULT_LINE: $REVIEW_RESULT_LINE" >> "$DEBUG_LOG" 2>/dev/null

  NUM_ISSUES=0
  NUM_FIXES=0
  REVIEW_RESULT_SUMMARY=""
  REVIEW_RECORDED=false

  if [ -n "$REVIEW_RESULT_LINE" ]; then
    # Extract everything after "REVIEW_RESULT:" and parse as JSON
    RESULT_JSON=$(echo "$REVIEW_RESULT_LINE" | sed 's/.*REVIEW_RESULT: *//')
    echo "RESULT_JSON: $RESULT_JSON" >> "$DEBUG_LOG" 2>/dev/null

    # Parse fields
    RESULT_TASK=$(echo "$RESULT_JSON" | jq -r '.task // ""' 2>/dev/null)
    NUM_ISSUES=$(echo "$RESULT_JSON" | jq -r '.issues // 0' 2>/dev/null)
    NUM_FIXES=$(echo "$RESULT_JSON" | jq -r '.fixes // 0' 2>/dev/null)
    REVIEW_RESULT_SUMMARY=$(echo "$RESULT_JSON" | jq -r '.summary // "Review completed"' 2>/dev/null)

    echo "RESULT_TASK: $RESULT_TASK, NUM_ISSUES: $NUM_ISSUES, NUM_FIXES: $NUM_FIXES" >> "$DEBUG_LOG" 2>/dev/null

    # Verify it matches current task (or accept if task field missing for backwards compat)
    if [ -z "$RESULT_TASK" ] || [ "$RESULT_TASK" = "$CURRENT_REVIEW_TASK" ]; then
      echo "Task matches, recording result" >> "$DEBUG_LOG" 2>/dev/null
      # Record the review result
      REVIEW_HISTORY_ENTRY=$(jq -n \
        --arg task "$CURRENT_REVIEW_TASK" \
        --argjson issues "$NUM_ISSUES" \
        --argjson fixes "$NUM_FIXES" \
        --arg summary "$REVIEW_RESULT_SUMMARY" \
        '{task: $task, issuesFound: $issues, fixesApplied: $fixes, testsPassAfter: true, summary: $summary}')

      STATE=$(echo "$STATE" | jq \
        --arg task "$CURRENT_REVIEW_TASK" \
        --argjson entry "$REVIEW_HISTORY_ENTRY" \
        '.reviewStatuses[$task] = "reviewed" | .reviewHistory += [$entry]')

      REVIEW_RECORDED=true
    else
      echo "Task mismatch: expected $CURRENT_REVIEW_TASK, got $RESULT_TASK" >> "$DEBUG_LOG" 2>/dev/null
    fi
  else
    echo "No REVIEW_RESULT_LINE found" >> "$DEBUG_LOG" 2>/dev/null
  fi

  echo "REVIEW_RECORDED: $REVIEW_RECORDED" >> "$DEBUG_LOG" 2>/dev/null

  # ─── ADVANCE TO NEXT TASK (if review was recorded) ──────────────────────────
  if [ "$REVIEW_RECORDED" = "true" ]; then
    # Special case: HOLISTIC review completed
    if [ "$CURRENT_REVIEW_TASK" = "HOLISTIC" ]; then
      STATE=$(echo "$STATE" | jq '.holisticReviewDone = true | .currentReviewTask = null')
      echo "$STATE" > "$STATE_FILE"

      FEEDBACK="[RECURSIVE-DEV REVIEW] Holistic review complete: $NUM_ISSUES issue(s), $NUM_FIXES fix(es).
Summary: $REVIEW_RESULT_SUMMARY

Proceeding to validation review..."

      echo "$(hook_response false "$FEEDBACK")"
      exit 0
    fi

    # Special case: VALIDATION review completed
    if [ "$CURRENT_REVIEW_TASK" = "VALIDATION" ]; then
      STATE=$(echo "$STATE" | jq '.validationReviewDone = true | .currentReviewTask = null')
      echo "$STATE" > "$STATE_FILE"

      FEEDBACK="[RECURSIVE-DEV REVIEW] Validation review complete: $NUM_ISSUES issue(s), $NUM_FIXES fix(es).
Summary: $REVIEW_RESULT_SUMMARY

All reviews finished!"

      echo "$(hook_response false "$FEEDBACK")"
      exit 0
    fi

    # Normal case: advance to next per-task review
    ORDER=$(echo "$TREE" | jq -r '.order // []')
    NEXT_REVIEW_TASK=""
    FOUND_CURRENT=false

    for task_id in $(echo "$ORDER" | jq -r '.[]'); do
      if [ "$FOUND_CURRENT" = "true" ]; then
        status=$(echo "$STATE" | jq -r --arg id "$task_id" '.reviewStatuses[$id] // "pending_review"')
        if [ "$status" = "pending_review" ]; then
          NEXT_REVIEW_TASK="$task_id"
          break
        fi
      fi
      [ "$task_id" = "$CURRENT_REVIEW_TASK" ] && FOUND_CURRENT=true
    done

    # Update state with next task (or null if done)
    STATE=$(echo "$STATE" | jq --arg task "$NEXT_REVIEW_TASK" \
      '.currentReviewTask = (if $task == "" then null else $task end)')
    echo "$STATE" > "$STATE_FILE"

    # Build completion message for current task
    CURRENT_STATUS="[RECURSIVE-DEV REVIEW] Review of $CURRENT_REVIEW_TASK recorded: $NUM_ISSUES issue(s), $NUM_FIXES fix(es).
Summary: $REVIEW_RESULT_SUMMARY"

    if [ -z "$NEXT_REVIEW_TASK" ]; then
      # All done — final summary
      REVIEW_SUMMARY_TEXT=$(echo "$STATE" | jq -r '
        .reviewHistory // [] |
        group_by(.task) | map(last) |
        map("- \(.task): \(.issuesFound // 0) issue(s), \(.fixesApplied // 0) fix(es). \(.summary // "")") |
        join("\n")
      ')
      TOTAL_ISSUES=$(echo "$STATE" | jq '[.reviewHistory // [] | group_by(.task) | map(last) | .[].issuesFound // 0] | add // 0')
      TOTAL_FIXES=$(echo "$STATE" | jq '[.reviewHistory // [] | group_by(.task) | map(last) | .[].fixesApplied // 0] | add // 0')

      FEEDBACK="$CURRENT_STATUS

ALL REVIEWS COMPLETE! Review phase finished.

Total: $TOTAL_ISSUES issue(s) found, $TOTAL_FIXES fix(es) applied.

Per-task results:
$REVIEW_SUMMARY_TEXT"

      echo "$(hook_response true "$FEEDBACK")"
      exit 0
    fi

    # More tasks to review — update CURRENT_REVIEW_TASK for the instruction below
    CURRENT_REVIEW_TASK="$NEXT_REVIEW_TASK"
    INJECT_PREFIX="$CURRENT_STATUS

"
  else
    INJECT_PREFIX=""
  fi

  # ─── BUILD REVIEW INSTRUCTION FOR CURRENT TASK ──────────────────────────────
  # Get task info
  TASK_INFO=$(echo "$TREE" | jq -r --arg id "$CURRENT_REVIEW_TASK" '.tasks[$id] // empty')

  if [ -z "$TASK_INFO" ] || [ "$TASK_INFO" = "null" ]; then
    # Task not found — mark as reviewed and advance
    STATE=$(echo "$STATE" | jq --arg task "$CURRENT_REVIEW_TASK" '.reviewStatuses[$task] = "reviewed"')
    ORDER=$(echo "$TREE" | jq -r '.order // []')
    NEXT=""
    FOUND=false
    for tid in $(echo "$ORDER" | jq -r '.[]'); do
      if [ "$FOUND" = "true" ]; then
        st=$(echo "$STATE" | jq -r --arg id "$tid" '.reviewStatuses[$id] // "pending_review"')
        [ "$st" = "pending_review" ] && NEXT="$tid" && break
      fi
      [ "$tid" = "$CURRENT_REVIEW_TASK" ] && FOUND=true
    done
    STATE=$(echo "$STATE" | jq --arg task "$NEXT" '.currentReviewTask = (if $task == "" then null else $task end)')
    echo "$STATE" > "$STATE_FILE"

    FEEDBACK="${INJECT_PREFIX}[RECURSIVE-DEV REVIEW] Task $CURRENT_REVIEW_TASK not found in tree, skipping."
    if [ -n "$NEXT" ]; then
      echo "$(hook_response false "$FEEDBACK")"
    else
      echo "$(hook_response true "$FEEDBACK")"
    fi
    exit 0
  fi

  TASK_DESC=$(echo "$TASK_INFO" | jq -r '.description // "No description"')
  TASK_CRITERIA=$(echo "$TASK_INFO" | jq -r '.criteria // "Task completes successfully"')

  # Get project directory
  PROJECT_DIR=$(echo "$TREE" | jq -r '.projectDir // empty')
  [ -z "$PROJECT_DIR" ] || [ "$PROJECT_DIR" = "null" ] && PROJECT_DIR=$(pwd)

  # Get modified files for this task
  TASK_FILES=$(echo "$STATE" | jq -r --arg id "$CURRENT_REVIEW_TASK" '
    .modifiedFiles[$id] // [] | if length == 0 then "No specific files recorded" else join(", ") end
  ')

  # Mark as in_review
  STATE=$(echo "$STATE" | jq --arg task "$CURRENT_REVIEW_TASK" '.reviewStatuses[$task] = "in_review"')
  echo "$STATE" > "$STATE_FILE"

  # Build the instruction for the model
  FEEDBACK="${INJECT_PREFIX}[RECURSIVE-DEV REVIEW] Please review task $CURRENT_REVIEW_TASK.

Use the Task tool to spawn a review subagent with fresh context:

Task(
  subagent_type: \"general-purpose\",
  description: \"Review task $CURRENT_REVIEW_TASK\",
  prompt: \"You are reviewing code for a development task. Review with fresh eyes — you have no context about how it was implemented. Your goal is not just to verify the files work in isolation, but to ensure they integrate correctly with the broader codebase.

TASK: $CURRENT_REVIEW_TASK
DESCRIPTION: $TASK_DESC
ACCEPTANCE CRITERIA: $TASK_CRITERIA
PROJECT DIRECTORY: $PROJECT_DIR
FILES MODIFIED: $TASK_FILES

REVIEW APPROACH:

1. READ the modified files — understand what changed and what the code assumes:
   - What fields does it access on entities/objects? (e.g., entity.name, item.status)
   - What types, interfaces, or schemas does it expect?
   - What patterns or conventions does it follow?

2. TRACE OUTWARD — understand how these files connect to the system:
   - Read the imports: What contracts do dependencies define? (schemas, types, APIs)
   - Search for related patterns: If this code uses entity.name, search for where else that's used
   - Check consumers: What other code depends on these files?

3. VERIFY CONSISTENCY — look for mismatches:
   - Do field accesses match actual entity schemas/types?
   - Are patterns used consistently across similar files?
   - Do assumptions in this code match assumptions elsewhere?

4. FIX ISSUES — in modified files AND related files:
   - If you find a systemic issue (e.g., hardcoded field name that doesn't match schema), fix it everywhere
   - Don't limit fixes to just the modified files
   - Run tests after fixes to verify nothing broke

5. VERIFY ACCEPTANCE CRITERIA:
   - After checking consistency, verify the implementation meets the stated criteria
   - Look for bugs, incomplete implementations, or deviations from criteria

Be thorough. Search for patterns. Trace dependencies. The goal is to catch issues that only become visible when you see how the code fits into the larger system.

After reviewing, summarize what you found and any fixes you made.\"
)

After the Task completes, output EXACTLY this line (with your results filled in):
REVIEW_RESULT: {\"task\": \"$CURRENT_REVIEW_TASK\", \"issues\": <number>, \"fixes\": <number>, \"summary\": \"<brief summary>\"}

Then stop and wait for the next review instruction."

  echo "Returning BLOCK response for review task $CURRENT_REVIEW_TASK" >> "$DEBUG_LOG" 2>/dev/null
  RESPONSE=$(hook_response false "$FEEDBACK")
  echo "Response: $RESPONSE" >> "$DEBUG_LOG" 2>/dev/null
  echo "$RESPONSE"
  exit 0
fi
# ─── END REVIEW PHASE ───────────────────────────────────────────────────────

# Extract current task info
CURRENT_TASK=$(echo "$STATE" | jq -r '.currentTask // empty')

if [ -z "$CURRENT_TASK" ] || [ "$CURRENT_TASK" = "null" ]; then
  # No current task, session may be complete
  echo '{}'
  exit 0
fi

# Get task details from tree
TASK_INFO=$(echo "$TREE" | jq -r --arg id "$CURRENT_TASK" '.tasks[$id] // empty')

if [ -z "$TASK_INFO" ] || [ "$TASK_INFO" = "null" ]; then
  echo '{}'
  exit 0
fi

TASK_DESC=$(echo "$TASK_INFO" | jq -r '.description // "No description"')
TASK_CRITERIA=$(echo "$TASK_INFO" | jq -r '.criteria // "Task completes successfully"')
TASK_CHILDREN=$(echo "$TASK_INFO" | jq -r '.children // []')
HAS_CHILDREN=$(echo "$TASK_CHILDREN" | jq 'length > 0')

# Get iteration count
ITERATION=$(echo "$STATE" | jq -r --arg id "$CURRENT_TASK" '.iterations[$id] // 0')
MAX_ITERATIONS=$(echo "$STATE" | jq -r '.maxIterations // 5')

# Get transcript content
TRANSCRIPT_CONTENT=$(read_transcript_auto "$HOOK_INPUT" 500)

# Build context for parent tasks
EXTRA_CONTEXT=""
if [ "$HAS_CHILDREN" = "true" ]; then
  # This is a parent task - add context about children
  CHILDREN_LIST=$(echo "$TASK_CHILDREN" | jq -r '.[]' | while read child_id; do
    child_info=$(echo "$TREE" | jq -r --arg id "$child_id" '.tasks[$id] // empty')
    if [ -n "$child_info" ]; then
      child_desc=$(echo "$child_info" | jq -r '.description // ""')
      echo "- $child_id: $child_desc (completed - treat as atomic)"
    fi
  done)

  EXTRA_CONTEXT="TASK TYPE: Parent/Integration task

COMPLETED CHILDREN (treat as atomic building blocks):
$CHILDREN_LIST

This task is about integrating the children above. They have each passed their own verification and should be treated as working units. Focus verification on whether they work together correctly according to the parent criteria. Take your time to evaluate the code from multiple perspectives, checking for different failure modes (race conditions, etc.). We’re not writing code just for the sake of writing code - the whole point of this is the build something that works perfectly for real-world users, and we achieve that by making sure we’re writing the code so that each part fits together perfectly. Hold yourself to a high standard. I know you can reach it, it’s just a matter of taking your time and using the talent for constructing high-quality code that I know you have."
fi

# Run test command if configured
TEST_CMD=$(echo "$STATE" | jq -r '.testCommand // empty')
run_test_command "$TEST_CMD"

# Build and run verification
REVIEW_PROMPT=$(build_review_prompt "$TASK_CRITERIA" "$TEST_OUTPUT" "$TEST_EXIT_CODE" "$TRANSCRIPT_CONTENT" "$EXTRA_CONTEXT")
REVIEW=$(run_verification "$REVIEW_PROMPT")
parse_review_result "$REVIEW"

# Update iteration count
NEW_ITERATION=$((ITERATION + 1))

# Build history entry
HISTORY_ENTRY=$(jq -n \
  --arg task "$CURRENT_TASK" \
  --argjson iteration "$NEW_ITERATION" \
  --argjson pass "$REVIEW_PASS" \
  --argjson issues "$REVIEW_ISSUES" \
  --arg summary "$REVIEW_SUMMARY" \
  '{task: $task, iteration: $iteration, pass: $pass, issues: $issues, summary: $summary}')

# Update state with new iteration and history
STATE=$(echo "$STATE" | jq \
  --arg task "$CURRENT_TASK" \
  --argjson iter "$NEW_ITERATION" \
  --argjson entry "$HISTORY_ENTRY" \
  '.iterations[$task] = $iter | .history += [$entry]')

# Decision logic
if [ "$REVIEW_PASS" = "true" ]; then
  # Task passed - mark as completed and advance
  STATE=$(echo "$STATE" | jq --arg task "$CURRENT_TASK" '.taskStatuses[$task] = "completed"')

  # Track modified files for this task (used by review phase later)
  MODIFIED_FILES=$(extract_modified_files "$HOOK_INPUT" 500)
  STATE=$(echo "$STATE" | jq \
    --arg task "$CURRENT_TASK" \
    --argjson files "$MODIFIED_FILES" \
    '.modifiedFiles //= {} | .modifiedFiles[$task] = $files')

  # Find next task in order
  ORDER=$(echo "$TREE" | jq -r '.order // []')
  NEXT_TASK=""
  FOUND_CURRENT=false

  for task_id in $(echo "$ORDER" | jq -r '.[]'); do
    if [ "$FOUND_CURRENT" = "true" ]; then
      # Check if this task is ready (all children completed)
      task_children=$(echo "$TREE" | jq -r --arg id "$task_id" '.tasks[$id].children // []')
      all_children_done=true

      for child_id in $(echo "$task_children" | jq -r '.[]'); do
        child_status=$(echo "$STATE" | jq -r --arg id "$child_id" '.taskStatuses[$id] // "pending"')
        if [ "$child_status" != "completed" ]; then
          all_children_done=false
          break
        fi
      done

      task_status=$(echo "$STATE" | jq -r --arg id "$task_id" '.taskStatuses[$id] // "pending"')

      if [ "$task_status" != "completed" ] && [ "$all_children_done" = "true" ]; then
        NEXT_TASK="$task_id"
        break
      fi
    fi

    if [ "$task_id" = "$CURRENT_TASK" ]; then
      FOUND_CURRENT=true
    fi
  done

  if [ -n "$NEXT_TASK" ]; then
    # Advance to next task
    STATE=$(echo "$STATE" | jq --arg task "$NEXT_TASK" '.currentTask = $task | .taskStatuses[$task] = "in_progress"')
    echo "$STATE" > "$STATE_FILE"

    # Get next task info for code-path-diagrammer
    NEXT_INFO=$(echo "$TREE" | jq -r --arg id "$NEXT_TASK" '.tasks[$id] // empty')
    NEXT_DESC=$(echo "$NEXT_INFO" | jq -r '.description // ""')
    NEXT_CRITERIA=$(echo "$NEXT_INFO" | jq -r '.criteria // ""')
    NEXT_CHILDREN=$(echo "$NEXT_INFO" | jq -r '.children // []')
    NEXT_HAS_CHILDREN=$(echo "$NEXT_CHILDREN" | jq 'length > 0')

    # Build code-path-diagrammer prompt
    TASK_TYPE="Leaf implementation"
    if [ "$NEXT_HAS_CHILDREN" = "true" ]; then
      TASK_TYPE="Integration (children are atomic)"
    fi

    DIAGRAM_PROMPT=""
    if [ -f "$AGENT_FILE" ]; then
      DIAGRAM_PROMPT=$(cat "$AGENT_FILE")
      DIAGRAM_PROMPT="$DIAGRAM_PROMPT

---

Task: $NEXT_DESC
Criteria: $NEXT_CRITERIA
Task Type: $TASK_TYPE

Create implementation plan with before/after diagrams. Identify files to modify."
    fi

    # Run code-path-diagrammer in background (don't block)
    DIAGRAM_OUTPUT=""
    if [ -n "$DIAGRAM_PROMPT" ]; then
      DIAGRAM_OUTPUT=$(timeout 60 claude -p "$DIAGRAM_PROMPT" 2>/dev/null || echo "")
    fi

    # Build feedback with diagram output
    FEEDBACK="[RECURSIVE-DEV] Task $CURRENT_TASK PASSED. Now advancing to $NEXT_TASK: $NEXT_DESC

Criteria: $NEXT_CRITERIA"

    if [ -n "$DIAGRAM_OUTPUT" ]; then
      FEEDBACK="$FEEDBACK

--- Implementation Plan ---
$DIAGRAM_OUTPUT"
    fi

    echo "$(hook_response false "$FEEDBACK")"
    exit 0
  else
    # No more dev tasks — transition to review phase
    FIRST_REVIEW_TASK=$(echo "$TREE" | jq -r '.order[0] // empty')

    # Initialize review statuses for all tasks as pending_review
    REVIEW_STATUSES=$(echo "$TREE" | jq '.order | map({key: ., value: "pending_review"}) | from_entries')

    STATE=$(echo "$STATE" | jq \
      --arg firstTask "$FIRST_REVIEW_TASK" \
      --argjson reviewStatuses "$REVIEW_STATUSES" \
      '.currentTask = null |
       .phase = "review" |
       .currentReviewTask = $firstTask |
       .reviewStatuses = $reviewStatuses |
       .reviewHistory = []')
    echo "$STATE" > "$STATE_FILE"

    DEV_SUMMARY=$(echo "$STATE" | jq -r '
      .history | group_by(.task) |
      map({task: .[0].task, iterations: length, finalResult: .[-1].pass}) |
      .[] | "- \(.task): \(.iterations) iteration(s), passed: \(.finalResult)"
    ')

    FEEDBACK="[RECURSIVE-DEV] Development complete! All tasks verified. Starting recursive review phase with fresh eyes...

Dev Summary:
$DEV_SUMMARY

The stop hook will guide you through reviewing each task using the Task tool to spawn fresh-context subagents. Just acknowledge this message to begin."

    echo "$(hook_response false "$FEEDBACK")"
    exit 0
  fi
fi

# Task failed - check iteration limit
ISSUES_TEXT=$(format_issues "$REVIEW_ISSUES")

if [ "$NEW_ITERATION" -ge "$MAX_ITERATIONS" ]; then
  # Max iterations reached - mark as failed and stop session
  STATE=$(echo "$STATE" | jq --arg task "$CURRENT_TASK" '.taskStatuses[$task] = "failed"')
  echo "$STATE" > "$STATE_FILE"

  FEEDBACK="[RECURSIVE-DEV] Task $CURRENT_TASK FAILED after $NEW_ITERATION iterations. Session stopped.

Remaining issues: $ISSUES_TEXT

Options:
1. Fix the issues and run '/recursive-dev start' to retry
2. Run '/recursive-dev skip' to skip this task (may cause parent to fail)
3. Run '/recursive-dev stop' to end the session"

  echo "$(hook_response false "$FEEDBACK")"
  exit 0
fi

# Not at max yet - run code-path-diagrammer for diagnosis and continue
DIAGNOSIS_PROMPT=""
if [ -f "$AGENT_FILE" ]; then
  DIAGNOSIS_PROMPT=$(cat "$AGENT_FILE")
  DIAGNOSIS_PROMPT="$DIAGNOSIS_PROMPT

---

DEBUGGING MODE

Task: $TASK_DESC
Criteria: $TASK_CRITERIA
Issues Found: $ISSUES_TEXT
Summary: $REVIEW_SUMMARY

The task verification failed. Analyze what went wrong and create a diagnostic diagram showing:
1. What was expected vs what happened
2. Where the failure occurred in the code flow
3. Suggested fix approach"
fi

DIAGNOSIS_OUTPUT=""
if [ -n "$DIAGNOSIS_PROMPT" ]; then
  DIAGNOSIS_OUTPUT=$(timeout 60 claude -p "$DIAGNOSIS_PROMPT" 2>/dev/null || echo "")
fi

# Save state
echo "$STATE" > "$STATE_FILE"

# Build feedback with diagnosis
FEEDBACK="[RECURSIVE-DEV] Task $CURRENT_TASK iteration $NEW_ITERATION of $MAX_ITERATIONS: NEEDS WORK

Issues: $ISSUES_TEXT"

if [ -n "$DIAGNOSIS_OUTPUT" ]; then
  FEEDBACK="$FEEDBACK

--- Diagnosis ---
$DIAGNOSIS_OUTPUT"
fi

FEEDBACK="$FEEDBACK

Please address these issues and continue working on the task."

echo "$(hook_response false "$FEEDBACK")"
exit 0
