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

# Get session ID by scanning for any active session matching this project directory.
# The get_recursive_dev_session function handles:
# - Flexible path matching (prefix match)
# - Multiple "active" indicators (explicit flag, currentTask, currentReviewTask)
SESSION_ID=$(get_recursive_dev_session "$HOOK_INPUT" "$RECURSIVE_DIR")
echo "SESSION_ID from get_recursive_dev_session: '$SESSION_ID'" >> "$DEBUG_LOG" 2>/dev/null

# Fallback to env var if set (for manual override)
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="${CLAUDE_RECURSIVE_DEV_SESSION:-}"
  echo "Env var SESSION_ID: '$SESSION_ID'" >> "$DEBUG_LOG" 2>/dev/null
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
  echo "currentDesignTask: $(echo "$STATE" | jq -r '.currentDesignTask // "null"')"
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

      # Mark session as complete so automated-dev-cycle can detect it
      STATE=$(echo "$STATE" | jq '.phase = "complete" | .active = false | .currentReviewTask = null')
      echo "$STATE" > "$STATE_FILE"

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

      # ─── AUTO-ADVANCE PHASE (for /automated-dev-cycle) ─────────────────────────
      # If project-phases state exists, automatically advance to next phase
      PROJECT_DIR=$(echo "$TREE" | jq -r '.projectDir // empty')
      [ -z "$PROJECT_DIR" ] || [ "$PROJECT_DIR" = "null" ] && PROJECT_DIR=$(pwd)

      PHASE_RESULT=""
      if [ -f "$SCRIPT_DIR/lib/project-phases.sh" ]; then
        source "$SCRIPT_DIR/lib/project-phases.sh"
        PHASE_STATE_FILE=$(get_state_file_with_fallback "$PROJECT_DIR" 2>/dev/null)
        if [ -n "$PHASE_STATE_FILE" ] && [ -f "$PHASE_STATE_FILE" ]; then
          # Advance to next phase
          PHASE_RESULT=$(advance_phase "$PROJECT_DIR" "$SESSION_ID" 2>/dev/null)
          echo "Phase advance result: $PHASE_RESULT" >> "$DEBUG_LOG" 2>/dev/null
        fi
      fi

      # Check if there's a next phase to start
      NEXT_PHASE=""
      NEXT_TITLE=""
      ALL_PHASES_COMPLETE="false"
      if [ -n "$PHASE_RESULT" ]; then
        ALL_PHASES_COMPLETE=$(echo "$PHASE_RESULT" | jq -r '.allComplete // false' 2>/dev/null)
        NEXT_PHASE=$(echo "$PHASE_RESULT" | jq -r '.nextPhase // empty' 2>/dev/null)
        NEXT_TITLE=$(echo "$PHASE_RESULT" | jq -r '.nextTitle // empty' 2>/dev/null)
      fi

      if [ "$ALL_PHASES_COMPLETE" = "true" ]; then
        FEEDBACK="$FEEDBACK

[AUTOMATED-DEV-CYCLE] All project phases are complete! Generate a final project summary."
      elif [ -n "$NEXT_PHASE" ] && [ "$NEXT_PHASE" != "null" ]; then
        FEEDBACK="$FEEDBACK

[AUTOMATED-DEV-CYCLE] Phase advanced! Now starting Phase $NEXT_PHASE: $NEXT_TITLE

Automatically proceed to the next phase:
1. Run tree-planner in auto mode: Skill(skill: \"tree-planner\", args: \"auto\")
2. After tree is generated, start recursive-dev: Skill(skill: \"recursive-dev\", args: \"start\")

Do NOT wait for user input — proceed immediately."
        # Don't allow stop — force continuation to next phase
        echo "$(hook_response false "$FEEDBACK")"
        exit 0
      fi
      # ─── END AUTO-ADVANCE ──────────────────────────────────────────────────────

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
    # Skip if this looks like the template/example (contains <number> or $CURRENT)
    if echo "$REVIEW_RESULT_LINE" | grep -qE '<number>|\$CURRENT|\\"<'; then
      echo "Skipping template/example match" >> "$DEBUG_LOG" 2>/dev/null
      REVIEW_RESULT_LINE=""
    fi
  fi

  if [ -n "$REVIEW_RESULT_LINE" ]; then
    # Extract everything after "REVIEW_RESULT:" and parse as JSON
    RESULT_JSON=$(echo "$REVIEW_RESULT_LINE" | sed 's/.*REVIEW_RESULT: *//')
    echo "RESULT_JSON: $RESULT_JSON" >> "$DEBUG_LOG" 2>/dev/null

    # Validate JSON parses correctly first
    if ! echo "$RESULT_JSON" | jq -e '.' >/dev/null 2>&1; then
      echo "Invalid JSON, skipping" >> "$DEBUG_LOG" 2>/dev/null
    else
      # Parse fields
      RESULT_TASK=$(echo "$RESULT_JSON" | jq -r '.task // ""' 2>/dev/null)
      NUM_ISSUES=$(echo "$RESULT_JSON" | jq -r '.issues // ""' 2>/dev/null)
      NUM_FIXES=$(echo "$RESULT_JSON" | jq -r '.fixes // ""' 2>/dev/null)
      REVIEW_RESULT_SUMMARY=$(echo "$RESULT_JSON" | jq -r '.summary // "Review completed"' 2>/dev/null)

      echo "RESULT_TASK: $RESULT_TASK, NUM_ISSUES: $NUM_ISSUES, NUM_FIXES: $NUM_FIXES" >> "$DEBUG_LOG" 2>/dev/null

      # Validate that issues and fixes are actual numbers
      if ! [[ "$NUM_ISSUES" =~ ^[0-9]+$ ]] || ! [[ "$NUM_FIXES" =~ ^[0-9]+$ ]]; then
        echo "Issues/fixes not valid numbers, skipping" >> "$DEBUG_LOG" 2>/dev/null
      # Validate task is not empty and matches current (or is a known special task)
      elif [ -z "$RESULT_TASK" ]; then
        echo "Empty task field, skipping" >> "$DEBUG_LOG" 2>/dev/null
      elif [ "$RESULT_TASK" != "$CURRENT_REVIEW_TASK" ]; then
        echo "Task mismatch: expected $CURRENT_REVIEW_TASK, got $RESULT_TASK" >> "$DEBUG_LOG" 2>/dev/null
      else
        echo "Valid result, recording" >> "$DEBUG_LOG" 2>/dev/null
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
      fi
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
      # Per-task reviews done — proceed to holistic review
      # (The holistic/validation check at the top of review phase will handle it on next invocation)
      FEEDBACK="$CURRENT_STATUS

Per-task reviews complete! Proceeding to holistic review..."

      echo "$(hook_response false "$FEEDBACK")"
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

DESIGN CONTEXT: If you see @design annotations in the modified files, these describe the as-built design specification. Use them to understand the intended architecture and check whether the implementation is consistent with the stated design.

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

# ─── DESIGN-DOCUMENTATION PHASE ───────────────────────────────────────────────
# After dev completes, before review begins. Documents the as-built design
# via inline @design annotations in source code.
#
# Same subagent approach as review phase:
# - Hook checks for DESIGN_RESULT in transcript
# - If found: parse, record, advance to next task
# - Hook injects instruction for model to document next task via Task tool
# - Model spawns design-docs subagent (fresh context), outputs DESIGN_RESULT
# - After all tasks: run design-extract.sh, transition to review phase
if [ "$PHASE" = "design-documentation" ]; then
  echo "In DESIGN-DOCUMENTATION phase block" >> "$DEBUG_LOG" 2>/dev/null
  CURRENT_DESIGN_TASK=$(echo "$STATE" | jq -r '.currentDesignTask // empty')
  echo "CURRENT_DESIGN_TASK='$CURRENT_DESIGN_TASK'" >> "$DEBUG_LOG" 2>/dev/null

  # ─── CHECK FOR DESIGN_RESULT FROM MODEL'S PREVIOUS TURN ───────────────────
  # Format: DESIGN_RESULT: {"task": "T1.1", "annotations": N, "summary": "..."}
  DESIGN_DEBUG_LOG="/tmp/recursive-dev-design-debug.log"
  TRANSCRIPT_PATH=$(get_transcript_path "$HOOK_INPUT")
  DESIGN_RESULT_LINE=""

  {
    echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') DESIGN_RESULT check ==="
    echo "CURRENT_DESIGN_TASK: $CURRENT_DESIGN_TASK"
    echo "TRANSCRIPT_PATH: $TRANSCRIPT_PATH"
  } >> "$DESIGN_DEBUG_LOG" 2>/dev/null

  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    DESIGN_RESULT_LINE=$(tail -50 "$TRANSCRIPT_PATH" 2>/dev/null | \
      jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null | \
      grep 'DESIGN_RESULT:' | tail -1)

    if [ -z "$DESIGN_RESULT_LINE" ]; then
      DESIGN_RESULT_LINE=$(tail -100 "$TRANSCRIPT_PATH" 2>/dev/null | grep -o 'DESIGN_RESULT: *{[^}]*}' | tail -1)
      echo "Used fallback grep for DESIGN_RESULT" >> "$DESIGN_DEBUG_LOG" 2>/dev/null
    fi
  fi

  echo "DESIGN_RESULT_LINE: $DESIGN_RESULT_LINE" >> "$DESIGN_DEBUG_LOG" 2>/dev/null

  DESIGN_ANNOTATIONS=0
  DESIGN_RESULT_SUMMARY=""
  DESIGN_RECORDED=false

  if [ -n "$DESIGN_RESULT_LINE" ]; then
    # Skip template/example matches
    if echo "$DESIGN_RESULT_LINE" | grep -qE '<number>|<count>|\$CURRENT|\\"<'; then
      echo "Skipping template/example match" >> "$DESIGN_DEBUG_LOG" 2>/dev/null
      DESIGN_RESULT_LINE=""
    fi
  fi

  if [ -n "$DESIGN_RESULT_LINE" ]; then
    RESULT_JSON=$(echo "$DESIGN_RESULT_LINE" | sed 's/.*DESIGN_RESULT: *//')
    echo "RESULT_JSON: $RESULT_JSON" >> "$DESIGN_DEBUG_LOG" 2>/dev/null

    if ! echo "$RESULT_JSON" | jq -e '.' >/dev/null 2>&1; then
      echo "Invalid JSON, skipping" >> "$DESIGN_DEBUG_LOG" 2>/dev/null
    else
      RESULT_TASK=$(echo "$RESULT_JSON" | jq -r '.task // ""' 2>/dev/null)
      DESIGN_ANNOTATIONS=$(echo "$RESULT_JSON" | jq -r '.annotations // 0' 2>/dev/null)
      DESIGN_RESULT_SUMMARY=$(echo "$RESULT_JSON" | jq -r '.summary // "Design documented"' 2>/dev/null)

      echo "RESULT_TASK: $RESULT_TASK, ANNOTATIONS: $DESIGN_ANNOTATIONS" >> "$DESIGN_DEBUG_LOG" 2>/dev/null

      # Validate annotations is a number
      if ! [[ "$DESIGN_ANNOTATIONS" =~ ^[0-9]+$ ]]; then
        echo "Annotations not a valid number, skipping" >> "$DESIGN_DEBUG_LOG" 2>/dev/null
      elif [ -z "$RESULT_TASK" ]; then
        echo "Empty task field, skipping" >> "$DESIGN_DEBUG_LOG" 2>/dev/null
      elif [ "$RESULT_TASK" != "$CURRENT_DESIGN_TASK" ]; then
        echo "Task mismatch: expected $CURRENT_DESIGN_TASK, got $RESULT_TASK" >> "$DESIGN_DEBUG_LOG" 2>/dev/null
      else
        echo "Valid DESIGN_RESULT, recording" >> "$DESIGN_DEBUG_LOG" 2>/dev/null

        # Get modified files for this task to record in history
        TASK_MOD_FILES=$(echo "$STATE" | jq -r --arg id "$CURRENT_DESIGN_TASK" \
          '.modifiedFiles[$id] // [] | if length == 0 then [] else . end')

        DESIGN_HISTORY_ENTRY=$(jq -n \
          --arg task "$CURRENT_DESIGN_TASK" \
          --argjson annotations "$DESIGN_ANNOTATIONS" \
          --argjson files "$TASK_MOD_FILES" \
          --arg summary "$DESIGN_RESULT_SUMMARY" \
          '{task: $task, annotations: $annotations, files: $files, summary: $summary}')

        STATE=$(echo "$STATE" | jq \
          --arg task "$CURRENT_DESIGN_TASK" \
          --argjson entry "$DESIGN_HISTORY_ENTRY" \
          '.designStatuses[$task] = "documented" | .designHistory += [$entry]')

        DESIGN_RECORDED=true
      fi
    fi
  else
    echo "No DESIGN_RESULT_LINE found" >> "$DESIGN_DEBUG_LOG" 2>/dev/null
  fi

  echo "DESIGN_RECORDED: $DESIGN_RECORDED" >> "$DESIGN_DEBUG_LOG" 2>/dev/null

  # ─── ADVANCE TO NEXT TASK (if design was recorded) ──────────────────────────
  if [ "$DESIGN_RECORDED" = "true" ]; then
    # Find next pending_design task
    ORDER=$(echo "$TREE" | jq -r '.order // []')
    NEXT_DESIGN_TASK=""
    FOUND_CURRENT=false

    for task_id in $(echo "$ORDER" | jq -r '.[]'); do
      if [ "$FOUND_CURRENT" = "true" ]; then
        status=$(echo "$STATE" | jq -r --arg id "$task_id" '.designStatuses[$id] // "pending_design"')
        if [ "$status" = "pending_design" ]; then
          NEXT_DESIGN_TASK="$task_id"
          break
        fi
      fi
      [ "$task_id" = "$CURRENT_DESIGN_TASK" ] && FOUND_CURRENT=true
    done

    # Update state with next task (or null if done)
    STATE=$(echo "$STATE" | jq --arg task "$NEXT_DESIGN_TASK" \
      '.currentDesignTask = (if $task == "" then null else $task end)')
    echo "$STATE" > "$STATE_FILE"

    CURRENT_STATUS="[RECURSIVE-DEV DESIGN] Design documentation for $CURRENT_DESIGN_TASK recorded: $DESIGN_ANNOTATIONS annotation(s).
Summary: $DESIGN_RESULT_SUMMARY"

    if [ -z "$NEXT_DESIGN_TASK" ]; then
      # All design tasks done — run extraction script and transition to review phase
      PROJECT_DIR=$(echo "$TREE" | jq -r '.projectDir // empty')
      [ -z "$PROJECT_DIR" ] || [ "$PROJECT_DIR" = "null" ] && PROJECT_DIR=$(pwd)

      # Generate DESIGN.md
      EXTRACT_SCRIPT="$SCRIPT_DIR/lib/design-extract.sh"
      if [ -x "$EXTRACT_SCRIPT" ]; then
        EXTRACT_OUTPUT=$("$EXTRACT_SCRIPT" "$PROJECT_DIR" 2>&1 || echo "Extraction failed")
        echo "design-extract.sh output: $EXTRACT_OUTPUT" >> "$DESIGN_DEBUG_LOG" 2>/dev/null
      fi

      # Transition to review phase
      FIRST_REVIEW_TASK=$(echo "$TREE" | jq -r '.order[0] // empty')
      REVIEW_STATUSES=$(echo "$TREE" | jq '.order | map({key: ., value: "pending_review"}) | from_entries')

      STATE=$(echo "$STATE" | jq \
        --arg firstTask "$FIRST_REVIEW_TASK" \
        --argjson reviewStatuses "$REVIEW_STATUSES" \
        '.phase = "review" |
         .currentDesignTask = null |
         .currentReviewTask = $firstTask |
         .reviewStatuses = $reviewStatuses |
         .reviewHistory = []')
      echo "$STATE" > "$STATE_FILE"

      # Summarize design documentation phase
      DESIGN_SUMMARY=$(echo "$STATE" | jq -r '
        .designHistory // [] |
        map("- \(.task): \(.annotations) annotation(s). \(.summary // "")") |
        join("\n")
      ')
      TOTAL_ANNOTATIONS=$(echo "$STATE" | jq '[.designHistory // [] | .[].annotations] | add // 0')

      FEEDBACK="$CURRENT_STATUS

[RECURSIVE-DEV] Design documentation complete! $TOTAL_ANNOTATIONS total annotation(s) added. DESIGN.md generated.

Design Summary:
$DESIGN_SUMMARY

Starting recursive review phase with fresh eyes. The stop hook will guide you through reviewing each task using the Task tool to spawn fresh-context subagents. Just acknowledge this message to begin."

      echo "$(hook_response false "$FEEDBACK")"
      exit 0
    fi

    # More tasks to document — update CURRENT_DESIGN_TASK for the instruction below
    CURRENT_DESIGN_TASK="$NEXT_DESIGN_TASK"
    INJECT_PREFIX="$CURRENT_STATUS

"
  else
    INJECT_PREFIX=""
  fi

  # ─── BUILD DESIGN INSTRUCTION FOR CURRENT TASK ──────────────────────────────
  TASK_INFO=$(echo "$TREE" | jq -r --arg id "$CURRENT_DESIGN_TASK" '.tasks[$id] // empty')

  if [ -z "$TASK_INFO" ] || [ "$TASK_INFO" = "null" ]; then
    # Task not found — mark as documented (skip) and advance
    STATE=$(echo "$STATE" | jq --arg task "$CURRENT_DESIGN_TASK" '.designStatuses[$task] = "documented"')
    ORDER=$(echo "$TREE" | jq -r '.order // []')
    NEXT=""
    FOUND=false
    for tid in $(echo "$ORDER" | jq -r '.[]'); do
      if [ "$FOUND" = "true" ]; then
        st=$(echo "$STATE" | jq -r --arg id "$tid" '.designStatuses[$id] // "pending_design"')
        [ "$st" = "pending_design" ] && NEXT="$tid" && break
      fi
      [ "$tid" = "$CURRENT_DESIGN_TASK" ] && FOUND=true
    done
    STATE=$(echo "$STATE" | jq --arg task "$NEXT" '.currentDesignTask = (if $task == "" then null else $task end)')
    echo "$STATE" > "$STATE_FILE"

    FEEDBACK="${INJECT_PREFIX}[RECURSIVE-DEV DESIGN] Task $CURRENT_DESIGN_TASK not found in tree, skipping."
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
  TASK_FILES=$(echo "$STATE" | jq -r --arg id "$CURRENT_DESIGN_TASK" '
    .modifiedFiles[$id] // [] | if length == 0 then "No specific files recorded" else join(", ") end
  ')

  # Mark as in_progress
  STATE=$(echo "$STATE" | jq --arg task "$CURRENT_DESIGN_TASK" '.designStatuses[$task] = "in_progress"')
  echo "$STATE" > "$STATE_FILE"

  # Build the instruction for the model
  FEEDBACK="${INJECT_PREFIX}[RECURSIVE-DEV DESIGN] Please document design decisions for task $CURRENT_DESIGN_TASK.

Use the Task tool to spawn a design-documentation subagent with fresh context:

Task(
  subagent_type: \"general-purpose\",
  description: \"Document design decisions for task $CURRENT_DESIGN_TASK\",
  prompt: \"You are examining code that was just implemented to document its as-built design. Your job is to look at the code as it is and add structured @design annotations that describe the architecture, patterns, and key structural choices that emerged.

TASK: $CURRENT_DESIGN_TASK
DESCRIPTION: $TASK_DESC
ACCEPTANCE CRITERIA: $TASK_CRITERIA
PROJECT DIRECTORY: $PROJECT_DIR
FILES MODIFIED: $TASK_FILES

ANNOTATION FORMAT:

Add @design annotations using the file's native comment syntax. Each annotation has a title on the @design line, followed by indented key-value sub-fields:

  # @design Short Title (2-5 words)
  #   design: What the design is and how it works (required)
  #   context: What shaped this design — reasoning, constraints, requirements (required)
  #   tradeoffs: Properties or costs accepted with this design (optional)
  #   alternatives: Other approaches that exist (optional)
  #   task: $CURRENT_DESIGN_TASK

For // comment languages (JS/TS/Go/Rust/etc), use // instead of #.

ANALYSIS PROCESS:

1. READ the modified files — understand the implementation as it exists
2. IDENTIFY key design decisions:
   - Architecture patterns (how components are organized and communicate)
   - Data structures (key models, schemas, state shape)
   - Control flow (how data and execution flow through the system)
   - Error handling (recovery strategies, failure modes)
   - API contracts (interfaces, endpoints, message formats)
   - Concurrency approaches (threading, async, synchronization)
   - State management (where state lives, how it's updated)
3. ADD @design annotations above the class/function/block that embodies each decision
4. SKIP things that are self-evident from reading the code (standard idioms, trivial wiring)
5. Target 3-8 annotations per task. Zero is fine for mechanical tasks.

Place annotations at the file/class/function level, not on individual lines. Aim for 3-6 lines per annotation.

After documenting, run the extraction script to update DESIGN.md:
  ~/.claude/hooks/lib/design-extract.sh $PROJECT_DIR

Then summarize what you documented.\"
)

After the Task completes, output EXACTLY this line (with your results filled in):
DESIGN_RESULT: {\"task\": \"$CURRENT_DESIGN_TASK\", \"annotations\": <count>, \"summary\": \"<brief description of what was documented>\"}

Then stop and wait for the next design documentation instruction."

  echo "Returning BLOCK response for design task $CURRENT_DESIGN_TASK" >> "$DESIGN_DEBUG_LOG" 2>/dev/null
  RESPONSE=$(hook_response false "$FEEDBACK")
  echo "Response: $RESPONSE" >> "$DESIGN_DEBUG_LOG" 2>/dev/null
  echo "$RESPONSE"
  exit 0
fi
# ─── END DESIGN-DOCUMENTATION PHASE ───────────────────────────────────────────

# Extract current task info
CURRENT_TASK=$(echo "$STATE" | jq -r '.currentTask // empty')

if [ -z "$CURRENT_TASK" ] || [ "$CURRENT_TASK" = "null" ]; then
  # No current task — check if we should transition to review phase
  # This handles the case where currentTask was set to null (manually or after last task)
  # but the review phase wasn't initialized yet

  ALL_TASKS_DONE=true
  ORDER=$(echo "$TREE" | jq -r '.order // []')
  for task_id in $(echo "$ORDER" | jq -r '.[]'); do
    task_status=$(echo "$STATE" | jq -r --arg id "$task_id" '.taskStatuses[$id] // "pending"')
    if [ "$task_status" != "completed" ]; then
      ALL_TASKS_DONE=false
      break
    fi
  done

  echo "currentTask is null, ALL_TASKS_DONE=$ALL_TASKS_DONE, PHASE=$PHASE" >> "$DEBUG_LOG" 2>/dev/null

  if [ "$ALL_TASKS_DONE" = "true" ] && [ "$PHASE" = "dev" ]; then
    # All dev tasks done but still in dev phase — transition to design-documentation
    FIRST_DESIGN_TASK=$(echo "$TREE" | jq -r '.order[0] // empty')

    # Initialize design statuses for all tasks as pending_design
    DESIGN_STATUSES=$(echo "$TREE" | jq '.order | map({key: ., value: "pending_design"}) | from_entries')

    STATE=$(echo "$STATE" | jq \
      --arg firstTask "$FIRST_DESIGN_TASK" \
      --argjson designStatuses "$DESIGN_STATUSES" \
      '.currentTask = null |
       .phase = "design-documentation" |
       .currentDesignTask = $firstTask |
       .designStatuses = $designStatuses |
       .designHistory = []')
    echo "$STATE" > "$STATE_FILE"

    DEV_SUMMARY=$(echo "$STATE" | jq -r '
      .history // [] | group_by(.task) |
      map({task: .[0].task, iterations: length, finalResult: .[-1].pass}) |
      .[] | "- \(.task): \(.iterations) iteration(s), passed: \(.finalResult)"
    ')

    FEEDBACK="[RECURSIVE-DEV] Development complete! All tasks verified. Starting design documentation phase...

Dev Summary:
$DEV_SUMMARY

The stop hook will guide you through documenting design decisions for each task using the Task tool to spawn fresh-context subagents. Just acknowledge this message to begin."

    echo "$(hook_response false "$FEEDBACK")"
    exit 0
  fi

  # Not ready for review transition, allow normal stop
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
    # No more dev tasks — transition to design-documentation phase
    FIRST_DESIGN_TASK=$(echo "$TREE" | jq -r '.order[0] // empty')

    # Initialize design statuses for all tasks as pending_design
    DESIGN_STATUSES=$(echo "$TREE" | jq '.order | map({key: ., value: "pending_design"}) | from_entries')

    STATE=$(echo "$STATE" | jq \
      --arg firstTask "$FIRST_DESIGN_TASK" \
      --argjson designStatuses "$DESIGN_STATUSES" \
      '.currentTask = null |
       .phase = "design-documentation" |
       .currentDesignTask = $firstTask |
       .designStatuses = $designStatuses |
       .designHistory = []')
    echo "$STATE" > "$STATE_FILE"

    DEV_SUMMARY=$(echo "$STATE" | jq -r '
      .history // [] | group_by(.task) |
      map({task: .[0].task, iterations: length, finalResult: .[-1].pass}) |
      .[] | "- \(.task): \(.iterations) iteration(s), passed: \(.finalResult)"
    ')

    FEEDBACK="[RECURSIVE-DEV] Development complete! All tasks verified. Starting design documentation phase...

Dev Summary:
$DEV_SUMMARY

The stop hook will guide you through documenting design decisions for each task using the Task tool to spawn fresh-context subagents. Just acknowledge this message to begin."

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
