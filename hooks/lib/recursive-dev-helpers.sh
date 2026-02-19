#!/bin/bash
#
# recursive-dev-helpers.sh - Helper functions for recursive-dev skill
#
# These functions provide deterministic operations that Claude can call
# instead of constructing JSON manually.
#

RECURSIVE_DIR="$HOME/.claude/recursive-dev"

# Safely write state file with validation and backup
# Usage: safe_write_state "state_file_path" "json_content"
safe_write_state() {
  local state_file="$1"
  local content="$2"

  # Validate JSON before writing
  if ! echo "$content" | jq -e . >/dev/null 2>&1; then
    echo "ERROR: Invalid JSON, refusing to write" >&2
    return 1
  fi

  # Check content has required fields
  if ! echo "$content" | jq -e '.phase and .sessionId' >/dev/null 2>&1; then
    echo "ERROR: State missing required fields, refusing to write" >&2
    return 1
  fi

  # Create backup of existing state
  if [ -f "$state_file" ] && [ -s "$state_file" ]; then
    cp "$state_file" "${state_file}.backup" 2>/dev/null
  fi

  # Write new state
  echo "$content" > "$state_file"

  # Verify write succeeded
  if [ ! -s "$state_file" ]; then
    echo "ERROR: Write failed, restoring backup" >&2
    if [ -f "${state_file}.backup" ]; then
      cp "${state_file}.backup" "$state_file"
    fi
    return 1
  fi

  return 0
}

# Try to recover state from backup if corrupted
# Usage: recover_state "session_id"
# Returns: JSON with success status
recover_state() {
  local session_id="$1"
  local session_dir="$RECURSIVE_DIR/$session_id"
  local state_file="$session_dir/state.json"
  local backup_file="${state_file}.backup"

  # Check if state is corrupted (empty or invalid JSON)
  local state_ok=false
  if [ -f "$state_file" ] && [ -s "$state_file" ]; then
    if cat "$state_file" | jq -e '.phase and .sessionId' >/dev/null 2>&1; then
      state_ok=true
    fi
  fi

  if [ "$state_ok" = "true" ]; then
    echo '{"recovered": false, "reason": "State file is valid, no recovery needed"}'
    return 0
  fi

  # State is corrupted, try backup
  if [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
    if cat "$backup_file" | jq -e '.phase and .sessionId' >/dev/null 2>&1; then
      cp "$backup_file" "$state_file"
      echo '{"recovered": true, "source": "backup"}'
      return 0
    fi
  fi

  echo '{"recovered": false, "reason": "No valid backup available"}'
  return 1
}

# Find active session for a project directory
# Usage: find_session_for_project "/path/to/project"
# Returns: Session ID if found, empty if not
find_session_for_project() {
  local project_dir="$1"

  for session_dir in "$RECURSIVE_DIR"/*/; do
    [ -d "$session_dir" ] || continue
    local tree_file="$session_dir/tree.json"
    local state_file="$session_dir/state.json"
    [ -f "$tree_file" ] || continue

    local session_project=$(jq -r '.projectDir // empty' "$tree_file" 2>/dev/null)
    if [ "$session_project" = "$project_dir" ]; then
      basename "$session_dir"
      return 0
    fi
  done

  echo ""
}

# Initialize review phase for a session
# Usage: init_review_phase "session_id"
# Returns: JSON with result status
init_review_phase() {
  local session_id="$1"
  local session_dir="$RECURSIVE_DIR/$session_id"
  local tree_file="$session_dir/tree.json"
  local state_file="$session_dir/state.json"

  # Validate session exists
  if [ ! -d "$session_dir" ]; then
    echo '{"success": false, "error": "Session directory not found"}'
    return 1
  fi

  if [ ! -f "$tree_file" ]; then
    echo '{"success": false, "error": "tree.json not found"}'
    return 1
  fi

  # Read tree to get task order
  local tree=$(cat "$tree_file" 2>/dev/null)
  if [ -z "$tree" ]; then
    echo '{"success": false, "error": "Could not read tree.json"}'
    return 1
  fi

  local order=$(echo "$tree" | jq -r '.order // []')
  if [ "$order" = "[]" ] || [ -z "$order" ]; then
    echo '{"success": false, "error": "No tasks in tree order"}'
    return 1
  fi

  local first_task=$(echo "$order" | jq -r '.[0]')
  local task_count=$(echo "$order" | jq 'length')

  # Build task statuses (all completed)
  local task_statuses=$(echo "$order" | jq 'map({key: ., value: "completed"}) | from_entries')

  # Build review statuses (all pending_review)
  local review_statuses=$(echo "$order" | jq 'map({key: ., value: "pending_review"}) | from_entries')

  # Read existing state to preserve modifiedFiles if present
  local modified_files='{}'
  if [ -f "$state_file" ]; then
    local existing_state=$(cat "$state_file" 2>/dev/null)
    if [ -n "$existing_state" ]; then
      modified_files=$(echo "$existing_state" | jq '.modifiedFiles // {}' 2>/dev/null || echo '{}')
    fi
  fi

  # Build new state with explicit active flag for reliable detection
  local new_state=$(jq -n \
    --arg sessionId "$session_id" \
    --arg firstTask "$first_task" \
    --argjson taskStatuses "$task_statuses" \
    --argjson reviewStatuses "$review_statuses" \
    --argjson modifiedFiles "$modified_files" \
    '{
      sessionId: $sessionId,
      currentTask: null,
      phase: "review",
      active: true,
      taskStatuses: $taskStatuses,
      iterations: {},
      maxIterations: 5,
      history: [],
      modifiedFiles: $modifiedFiles,
      currentReviewTask: $firstTask,
      reviewStatuses: $reviewStatuses,
      reviewHistory: []
    }')

  # Write using safe function with validation and backup
  if ! safe_write_state "$state_file" "$new_state"; then
    echo '{"success": false, "error": "Failed to write state.json safely"}'
    return 1
  fi

  # Get first task info for immediate review instruction
  local first_task_info=$(echo "$tree" | jq -r --arg id "$first_task" '.tasks[$id] // empty')
  local first_task_desc=""
  local first_task_criteria=""
  local project_dir=""

  if [ -n "$first_task_info" ] && [ "$first_task_info" != "null" ]; then
    first_task_desc=$(echo "$first_task_info" | jq -r '.description // "No description"')
    first_task_criteria=$(echo "$first_task_info" | jq -r '.criteria // "Task completes successfully"')
  fi

  project_dir=$(echo "$tree" | jq -r '.projectDir // empty')

  # Get modified files for first task
  local task_files="No specific files recorded"
  if [ -n "$modified_files" ] && [ "$modified_files" != "{}" ]; then
    task_files=$(echo "$modified_files" | jq -r --arg id "$first_task" '.[$id] // [] | if length == 0 then "No specific files recorded" else join(", ") end' 2>/dev/null)
    [ -z "$task_files" ] && task_files="No specific files recorded"
  fi

  # Return success with review instruction included
  jq -n \
    --arg sessionId "$session_id" \
    --arg firstTask "$first_task" \
    --argjson taskCount "$task_count" \
    --arg taskDesc "$first_task_desc" \
    --arg taskCriteria "$first_task_criteria" \
    --arg projectDir "$project_dir" \
    --arg taskFiles "$task_files" \
    '{
      success: true,
      sessionId: $sessionId,
      firstTask: $firstTask,
      taskCount: $taskCount,
      reviewInstruction: {
        task: $firstTask,
        description: $taskDesc,
        criteria: $taskCriteria,
        projectDir: $projectDir,
        modifiedFiles: $taskFiles
      }
    }'
}

# Get session status
# Usage: get_session_status "session_id"
# Returns: JSON with session status
get_session_status() {
  local session_id="$1"
  local session_dir="$RECURSIVE_DIR/$session_id"
  local state_file="$session_dir/state.json"
  local tree_file="$session_dir/tree.json"

  if [ ! -f "$state_file" ] || [ ! -f "$tree_file" ]; then
    echo '{"found": false}'
    return 1
  fi

  local state=$(cat "$state_file" 2>/dev/null)
  local tree=$(cat "$tree_file" 2>/dev/null)

  if [ -z "$state" ] || [ -z "$tree" ]; then
    echo '{"found": false, "error": "Could not read state or tree"}'
    return 1
  fi

  local phase=$(echo "$state" | jq -r '.phase // "dev"')
  local current_task=$(echo "$state" | jq -r '.currentTask // "null"')
  local current_review=$(echo "$state" | jq -r '.currentReviewTask // "null"')
  local project_dir=$(echo "$tree" | jq -r '.projectDir // "unknown"')

  jq -n \
    --arg sessionId "$session_id" \
    --arg phase "$phase" \
    --arg currentTask "$current_task" \
    --arg currentReview "$current_review" \
    --arg projectDir "$project_dir" \
    '{
      found: true,
      sessionId: $sessionId,
      phase: $phase,
      currentTask: (if $currentTask == "null" then null else $currentTask end),
      currentReviewTask: (if $currentReview == "null" then null else $currentReview end),
      projectDir: $projectDir
    }'
}

# Determine the next review step needed
# Usage: next_review_step "session_id"
# Returns: JSON with nextStep and action to take
next_review_step() {
  local session_id="$1"
  local session_dir="$RECURSIVE_DIR/$session_id"
  local state_file="$session_dir/state.json"
  local tree_file="$session_dir/tree.json"

  if [ ! -f "$state_file" ] || [ ! -f "$tree_file" ]; then
    echo '{"error": "Session files not found"}'
    return 1
  fi

  local state=$(cat "$state_file" 2>/dev/null)
  local tree=$(cat "$tree_file" 2>/dev/null)

  if [ -z "$state" ] || [ -z "$tree" ]; then
    echo '{"error": "Could not read session files"}'
    return 1
  fi

  local phase=$(echo "$state" | jq -r '.phase // "dev"')

  if [ "$phase" = "complete" ]; then
    echo '{"nextStep": "complete", "reason": "All reviews already complete"}'
    return 0
  fi

  if [ "$phase" = "dev" ]; then
    echo '{"nextStep": "init_review", "reason": "Still in dev phase, need to initialize review"}'
    return 0
  fi

  if [ "$phase" != "review" ]; then
    echo "{\"nextStep\": \"unknown\", \"phase\": \"$phase\", \"reason\": \"Unexpected phase\"}"
    return 0
  fi

  local current_review=$(echo "$state" | jq -r '.currentReviewTask // "null"')
  local holistic_done=$(echo "$state" | jq -r '.holisticReviewDone // false')
  local validation_done=$(echo "$state" | jq -r '.validationReviewDone // false')

  # Check if all per-task reviews are complete
  local order=$(echo "$tree" | jq -r '.order // []')
  local pending_reviews=$(echo "$state" | jq -r '
    .reviewStatuses // {} | to_entries |
    map(select(.value == "pending_review" or .value == "in_review")) |
    map(.key) | .[]
  ')

  # If there's a current non-null task that's not HOLISTIC/VALIDATION, continue it
  if [ -n "$current_review" ] && [ "$current_review" != "null" ] && \
     [ "$current_review" != "HOLISTIC" ] && [ "$current_review" != "VALIDATION" ]; then
    echo "{\"nextStep\": \"continue_per_task\", \"currentTask\": \"$current_review\", \"reason\": \"Per-task review in progress\"}"
    return 0
  fi

  # If there are pending per-task reviews, find the next one
  if [ -n "$pending_reviews" ]; then
    local next_task=$(echo "$pending_reviews" | head -1)
    echo "{\"nextStep\": \"per_task_review\", \"nextTask\": \"$next_task\", \"reason\": \"Pending per-task reviews remain\"}"
    return 0
  fi

  # All per-task reviews done - check holistic/validation
  if [ "$holistic_done" != "true" ]; then
    echo '{"nextStep": "holistic_review", "reason": "All per-task reviews complete, holistic review needed"}'
    return 0
  fi

  if [ "$validation_done" != "true" ]; then
    echo '{"nextStep": "validation_review", "reason": "Holistic review complete, validation review needed"}'
    return 0
  fi

  # Everything done
  echo '{"nextStep": "complete", "reason": "All reviews complete"}'
}

# Initialize design-documentation phase for a session
# Usage: init_design_phase "session_id"
# Returns: JSON with result status
init_design_phase() {
  local session_id="$1"
  local session_dir="$RECURSIVE_DIR/$session_id"
  local tree_file="$session_dir/tree.json"
  local state_file="$session_dir/state.json"

  # Validate session exists
  if [ ! -d "$session_dir" ]; then
    echo '{"success": false, "error": "Session directory not found"}'
    return 1
  fi

  if [ ! -f "$tree_file" ]; then
    echo '{"success": false, "error": "tree.json not found"}'
    return 1
  fi

  # Read tree to get task order
  local tree=$(cat "$tree_file" 2>/dev/null)
  if [ -z "$tree" ]; then
    echo '{"success": false, "error": "Could not read tree.json"}'
    return 1
  fi

  local order=$(echo "$tree" | jq -r '.order // []')
  if [ "$order" = "[]" ] || [ -z "$order" ]; then
    echo '{"success": false, "error": "No tasks in tree order"}'
    return 1
  fi

  local first_task=$(echo "$order" | jq -r '.[0]')
  local task_count=$(echo "$order" | jq 'length')

  # Build task statuses (all completed from dev phase)
  local task_statuses=$(echo "$order" | jq 'map({key: ., value: "completed"}) | from_entries')

  # Build design statuses (all pending_design)
  local design_statuses=$(echo "$order" | jq 'map({key: ., value: "pending_design"}) | from_entries')

  # Read existing state to preserve modifiedFiles and history
  local modified_files='{}'
  local history='[]'
  if [ -f "$state_file" ]; then
    local existing_state=$(cat "$state_file" 2>/dev/null)
    if [ -n "$existing_state" ]; then
      modified_files=$(echo "$existing_state" | jq '.modifiedFiles // {}' 2>/dev/null || echo '{}')
      history=$(echo "$existing_state" | jq '.history // []' 2>/dev/null || echo '[]')
    fi
  fi

  # Build new state
  local new_state=$(jq -n \
    --arg sessionId "$session_id" \
    --arg firstTask "$first_task" \
    --argjson taskStatuses "$task_statuses" \
    --argjson designStatuses "$design_statuses" \
    --argjson modifiedFiles "$modified_files" \
    --argjson history "$history" \
    '{
      sessionId: $sessionId,
      currentTask: null,
      phase: "design-documentation",
      active: true,
      taskStatuses: $taskStatuses,
      iterations: {},
      maxIterations: 5,
      history: $history,
      modifiedFiles: $modifiedFiles,
      currentDesignTask: $firstTask,
      designStatuses: $designStatuses,
      designHistory: []
    }')

  # Write using safe function with validation and backup
  if ! safe_write_state "$state_file" "$new_state"; then
    echo '{"success": false, "error": "Failed to write state.json safely"}'
    return 1
  fi

  # Get first task info
  local first_task_info=$(echo "$tree" | jq -r --arg id "$first_task" '.tasks[$id] // empty')
  local first_task_desc=""

  if [ -n "$first_task_info" ] && [ "$first_task_info" != "null" ]; then
    first_task_desc=$(echo "$first_task_info" | jq -r '.description // "No description"')
  fi

  local project_dir=$(echo "$tree" | jq -r '.projectDir // empty')

  # Get modified files for first task
  local task_files="No specific files recorded"
  if [ -n "$modified_files" ] && [ "$modified_files" != "{}" ]; then
    task_files=$(echo "$modified_files" | jq -r --arg id "$first_task" '.[$id] // [] | if length == 0 then "No specific files recorded" else join(", ") end' 2>/dev/null)
    [ -z "$task_files" ] && task_files="No specific files recorded"
  fi

  jq -n \
    --arg sessionId "$session_id" \
    --arg firstTask "$first_task" \
    --argjson taskCount "$task_count" \
    --arg taskDesc "$first_task_desc" \
    --arg projectDir "$project_dir" \
    --arg taskFiles "$task_files" \
    '{
      success: true,
      sessionId: $sessionId,
      firstTask: $firstTask,
      taskCount: $taskCount,
      designInstruction: {
        task: $firstTask,
        description: $taskDesc,
        projectDir: $projectDir,
        modifiedFiles: $taskFiles
      }
    }'
}

# Determine the next design-documentation step needed
# Usage: next_design_step "session_id"
# Returns: JSON with nextStep and action to take
next_design_step() {
  local session_id="$1"
  local session_dir="$RECURSIVE_DIR/$session_id"
  local state_file="$session_dir/state.json"
  local tree_file="$session_dir/tree.json"

  if [ ! -f "$state_file" ] || [ ! -f "$tree_file" ]; then
    echo '{"error": "Session files not found"}'
    return 1
  fi

  local state=$(cat "$state_file" 2>/dev/null)
  local tree=$(cat "$tree_file" 2>/dev/null)

  if [ -z "$state" ] || [ -z "$tree" ]; then
    echo '{"error": "Could not read session files"}'
    return 1
  fi

  local phase=$(echo "$state" | jq -r '.phase // "dev"')

  if [ "$phase" != "design-documentation" ]; then
    echo "{\"nextStep\": \"not_in_design_phase\", \"phase\": \"$phase\"}"
    return 0
  fi

  local current_design=$(echo "$state" | jq -r '.currentDesignTask // "null"')

  # If there's a current non-null task, continue it
  if [ -n "$current_design" ] && [ "$current_design" != "null" ]; then
    echo "{\"nextStep\": \"continue_design\", \"currentTask\": \"$current_design\"}"
    return 0
  fi

  # Find next pending_design task
  local order=$(echo "$tree" | jq -r '.order // []')
  local next_task=""

  for task_id in $(echo "$order" | jq -r '.[]'); do
    local status=$(echo "$state" | jq -r --arg id "$task_id" '.designStatuses[$id] // "pending_design"')
    if [ "$status" = "pending_design" ]; then
      next_task="$task_id"
      break
    fi
  done

  if [ -n "$next_task" ]; then
    echo "{\"nextStep\": \"design_task\", \"nextTask\": \"$next_task\"}"
  else
    echo '{"nextStep": "design_complete", "reason": "All tasks documented"}'
  fi
}

# Complete a session (set phase to complete, active to false)
# Validates that both holistic and validation reviews are done first.
# Usage: complete_session "session_id"
complete_session() {
  local session_id="$1"
  local session_dir="$RECURSIVE_DIR/$session_id"
  local state_file="$session_dir/state.json"

  if [ ! -f "$state_file" ]; then
    echo '{"success": false, "error": "Session state not found"}'
    return 1
  fi

  local state
  state=$(cat "$state_file" 2>/dev/null)

  local phase
  phase=$(echo "$state" | jq -r '.phase // "dev"')

  # Already complete — idempotent
  if [ "$phase" = "complete" ]; then
    echo '{"success": true, "phase": "complete", "alreadyComplete": true}'
    return 0
  fi

  local holistic_done
  holistic_done=$(echo "$state" | jq -r '.holisticReviewDone // false')
  local validation_done
  validation_done=$(echo "$state" | jq -r '.validationReviewDone // false')

  if [ "$holistic_done" != "true" ] || [ "$validation_done" != "true" ]; then
    echo "{\"success\": false, \"error\": \"Reviews not complete (holistic: $holistic_done, validation: $validation_done)\"}"
    return 1
  fi

  state=$(echo "$state" | jq '.phase = "complete" | .active = false | .currentReviewTask = null')
  echo "$state" > "$state_file"
  echo '{"success": true, "phase": "complete"}'
}

# Set the next review task in state
# Usage: set_review_task "session_id" "task_id_or_HOLISTIC_or_VALIDATION"
set_review_task() {
  local session_id="$1"
  local task="$2"
  local session_dir="$RECURSIVE_DIR/$session_id"
  local state_file="$session_dir/state.json"

  if [ ! -f "$state_file" ]; then
    echo '{"success": false, "error": "State file not found"}'
    return 1
  fi

  local state=$(cat "$state_file" 2>/dev/null)
  if [ -z "$state" ]; then
    echo '{"success": false, "error": "Could not read state file"}'
    return 1
  fi

  # Update currentReviewTask
  local new_state=$(echo "$state" | jq --arg task "$task" '.currentReviewTask = $task')

  # If it's a regular task, mark it as in_review
  if [ "$task" != "HOLISTIC" ] && [ "$task" != "VALIDATION" ]; then
    new_state=$(echo "$new_state" | jq --arg task "$task" '.reviewStatuses[$task] = "in_review"')
  fi

  # Write using safe function
  if ! safe_write_state "$state_file" "$new_state"; then
    echo '{"success": false, "error": "Failed to write state safely"}'
    return 1
  fi

  echo "{\"success\": true, \"currentReviewTask\": \"$task\"}"
}

# Main entry point - parse command and arguments
case "${1:-}" in
  find-session)
    find_session_for_project "${2:-$(pwd)}"
    ;;
  init-review)
    init_review_phase "$2"
    ;;
  init-design)
    init_design_phase "$2"
    ;;
  next-design-step)
    next_design_step "$2"
    ;;
  status)
    get_session_status "$2"
    ;;
  next-step)
    next_review_step "$2"
    ;;
  set-task)
    set_review_task "$2" "$3"
    ;;
  complete-session)
    complete_session "$2"
    ;;
  recover)
    recover_state "$2"
    ;;
  *)
    echo "Usage: $0 {find-session|init-review|init-design|status|next-step|next-design-step|set-task|complete-session|recover} [args]"
    echo ""
    echo "Commands:"
    echo "  find-session [project_dir]    - Find session for project directory"
    echo "  init-review <session_id>      - Initialize review phase"
    echo "  init-design <session_id>      - Initialize design-documentation phase"
    echo "  next-design-step <session_id> - Determine next design-documentation step"
    echo "  status <session_id>           - Get session status"
    echo "  next-step <session_id>        - Determine next review step needed"
    echo "  set-task <session_id> <task>   - Set current review task"
    echo "  complete-session <session_id>  - Mark session complete (validates reviews done)"
    echo "  recover <session_id>          - Try to recover corrupted state from backup"
    exit 1
    ;;
esac
