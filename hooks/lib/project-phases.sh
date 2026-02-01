#!/bin/bash
#
# project-phases.sh - Manage multi-phase project state
#
# Tracks progress across multiple phases for /automated-dev-cycle
# State is stored in ~/.claude/recursive-dev/project-<hash>.json
#

RECURSIVE_DIR="$HOME/.claude/recursive-dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source phase parser for parse_phases function
source "$SCRIPT_DIR/phase-parser.sh" 2>/dev/null || true

# Generate a hash for a project directory
get_project_hash() {
  local project_dir="$1"
  echo -n "$project_dir" | shasum -a 256 | cut -c1-12
}

# Get the state file path for a project
get_state_file() {
  local project_dir="$1"
  local hash
  hash=$(get_project_hash "$project_dir")
  echo "$RECURSIVE_DIR/project-$hash.json"
}

# Initialize project phases from a plan file
init_project_phases() {
  local project_dir="$1"
  local plan_file="$2"

  if [ ! -f "$plan_file" ]; then
    echo '{"success": false, "error": "Plan file not found"}'
    return 1
  fi

  # Parse phases from plan file
  local phases
  phases=$(parse_phases "$plan_file")

  local phase_count
  phase_count=$(echo "$phases" | jq 'length')

  if [ "$phase_count" -eq 0 ]; then
    echo '{"success": false, "error": "No phase markers found in plan file"}'
    return 1
  fi

  # Build phase status array
  local phase_statuses="[]"
  while read -r phase; do
    local num title
    num=$(echo "$phase" | jq -r '.number')
    title=$(echo "$phase" | jq -r '.title')

    phase_statuses=$(echo "$phase_statuses" | jq \
      --argjson num "$num" \
      --arg title "$title" \
      '. + [{
        "number": $num,
        "title": $title,
        "status": "pending"
      }]')
  done < <(echo "$phases" | jq -c '.[]')

  # Create state file
  local state_file
  state_file=$(get_state_file "$project_dir")

  mkdir -p "$RECURSIVE_DIR"

  local state
  state=$(jq -n \
    --arg projectDir "$project_dir" \
    --arg planFile "$plan_file" \
    --argjson phases "$phase_statuses" \
    '{
      "projectDir": $projectDir,
      "planFile": $planFile,
      "phases": $phases,
      "currentPhase": 1,
      "completedSessions": [],
      "created": now | strftime("%Y-%m-%dT%H:%M:%SZ"),
      "lastUpdated": now | strftime("%Y-%m-%dT%H:%M:%SZ")
    }')

  echo "$state" > "$state_file"

  echo "{\"success\": true, \"stateFile\": \"$state_file\", \"phaseCount\": $phase_count}"
}

# Get current phase info
get_current_phase() {
  local project_dir="$1"
  local state_file
  state_file=$(get_state_file "$project_dir")

  if [ ! -f "$state_file" ]; then
    echo '{"found": false, "error": "No project state found"}'
    return 1
  fi

  local state
  state=$(cat "$state_file" 2>/dev/null)

  if [ -z "$state" ]; then
    echo '{"found": false, "error": "Could not read state file"}'
    return 1
  fi

  local current_num
  current_num=$(echo "$state" | jq -r '.currentPhase')

  # Handle "all phases complete" case (currentPhase is null)
  if [ "$current_num" = "null" ] || [ -z "$current_num" ]; then
    jq -n \
      --arg planFile "$(echo "$state" | jq -r '.planFile')" \
      '{
        "found": true,
        "number": null,
        "title": null,
        "status": "all_complete",
        "planFile": $planFile,
        "allComplete": true
      }'
    return 0
  fi

  local current_phase
  current_phase=$(echo "$state" | jq --argjson num "$current_num" '.phases[] | select(.number == $num)')

  if [ -z "$current_phase" ] || [ "$current_phase" = "null" ]; then
    echo '{"found": false, "error": "Current phase not found in phases list"}'
    return 1
  fi

  local title status
  title=$(echo "$current_phase" | jq -r '.title')
  status=$(echo "$current_phase" | jq -r '.status')

  jq -n \
    --argjson number "$current_num" \
    --arg title "$title" \
    --arg status "$status" \
    --arg planFile "$(echo "$state" | jq -r '.planFile')" \
    '{
      "found": true,
      "number": $number,
      "title": $title,
      "status": $status,
      "planFile": $planFile,
      "allComplete": false
    }'
}

# Advance to the next phase
advance_phase() {
  local project_dir="$1"
  local session_id="${2:-}"
  local state_file
  state_file=$(get_state_file "$project_dir")

  if [ ! -f "$state_file" ]; then
    echo '{"success": false, "error": "No project state found"}'
    return 1
  fi

  local state
  state=$(cat "$state_file" 2>/dev/null)

  local current_num
  current_num=$(echo "$state" | jq -r '.currentPhase')

  # Mark current phase as complete
  state=$(echo "$state" | jq --argjson num "$current_num" '
    .phases = [.phases[] | if .number == $num then .status = "complete" else . end]
  ')

  # Record session if provided
  if [ -n "$session_id" ]; then
    state=$(echo "$state" | jq --arg sid "$session_id" '.completedSessions += [$sid]')
  fi

  # Find next pending phase
  local next_num
  next_num=$(echo "$state" | jq '[.phases[] | select(.status == "pending")] | .[0].number // null')

  if [ "$next_num" = "null" ] || [ -z "$next_num" ]; then
    # All phases complete
    state=$(echo "$state" | jq '.currentPhase = null | .lastUpdated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))')
    echo "$state" > "$state_file"
    echo '{"success": true, "allComplete": true, "nextPhase": null}'
    return 0
  fi

  # Advance to next phase
  state=$(echo "$state" | jq --argjson num "$next_num" '
    .currentPhase = $num |
    .phases = [.phases[] | if .number == $num then .status = "in_progress" else . end] |
    .lastUpdated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
  ')

  echo "$state" > "$state_file"

  local next_title
  next_title=$(echo "$state" | jq -r --argjson num "$next_num" '.phases[] | select(.number == $num) | .title')

  jq -n \
    --argjson nextPhase "$next_num" \
    --arg nextTitle "$next_title" \
    '{
      "success": true,
      "allComplete": false,
      "nextPhase": $nextPhase,
      "nextTitle": $nextTitle
    }'
}

# Mark current phase as in_progress
start_phase() {
  local project_dir="$1"
  local state_file
  state_file=$(get_state_file "$project_dir")

  if [ ! -f "$state_file" ]; then
    echo '{"success": false, "error": "No project state found"}'
    return 1
  fi

  local state
  state=$(cat "$state_file" 2>/dev/null)

  local current_num
  current_num=$(echo "$state" | jq -r '.currentPhase')

  state=$(echo "$state" | jq --argjson num "$current_num" '
    .phases = [.phases[] | if .number == $num then .status = "in_progress" else . end] |
    .lastUpdated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
  ')

  echo "$state" > "$state_file"
  echo '{"success": true}'
}

# Get full project status
get_phase_status() {
  local project_dir="$1"
  local state_file
  state_file=$(get_state_file "$project_dir")

  if [ ! -f "$state_file" ]; then
    echo '{"found": false}'
    return 1
  fi

  local state
  state=$(cat "$state_file" 2>/dev/null)

  if [ -z "$state" ]; then
    echo '{"found": false, "error": "Could not read state file"}'
    return 1
  fi

  # Add computed fields
  local total complete pending in_progress
  total=$(echo "$state" | jq '.phases | length')
  complete=$(echo "$state" | jq '[.phases[] | select(.status == "complete")] | length')
  pending=$(echo "$state" | jq '[.phases[] | select(.status == "pending")] | length')
  in_progress=$(echo "$state" | jq '[.phases[] | select(.status == "in_progress")] | length')

  echo "$state" | jq \
    --argjson total "$total" \
    --argjson complete "$complete" \
    --argjson pending "$pending" \
    --argjson inProgress "$in_progress" \
    '. + {
      "found": true,
      "summary": {
        "total": $total,
        "complete": $complete,
        "pending": $pending,
        "inProgress": $inProgress,
        "percentComplete": (if $total > 0 then (($complete * 100) / $total | floor) else 0 end)
      }
    }'
}

# Skip current phase
skip_phase() {
  local project_dir="$1"
  local state_file
  state_file=$(get_state_file "$project_dir")

  if [ ! -f "$state_file" ]; then
    echo '{"success": false, "error": "No project state found"}'
    return 1
  fi

  local state
  state=$(cat "$state_file" 2>/dev/null)

  local current_num
  current_num=$(echo "$state" | jq -r '.currentPhase')

  # Mark current phase as skipped
  state=$(echo "$state" | jq --argjson num "$current_num" '
    .phases = [.phases[] | if .number == $num then .status = "skipped" else . end]
  ')

  echo "$state" > "$state_file"

  # Now advance to next
  advance_phase "$project_dir"
}

# Restart from a specific phase
restart_from_phase() {
  local project_dir="$1"
  local phase_num="$2"
  local state_file
  state_file=$(get_state_file "$project_dir")

  if [ ! -f "$state_file" ]; then
    echo '{"success": false, "error": "No project state found"}'
    return 1
  fi

  local state
  state=$(cat "$state_file" 2>/dev/null)

  # Check if phase exists
  local phase_exists
  phase_exists=$(echo "$state" | jq --argjson num "$phase_num" '[.phases[] | select(.number == $num)] | length')

  if [ "$phase_exists" -eq 0 ]; then
    echo "{\"success\": false, \"error\": \"Phase $phase_num not found\"}"
    return 1
  fi

  # Reset phases from phase_num onwards to pending
  state=$(echo "$state" | jq --argjson num "$phase_num" '
    .currentPhase = $num |
    .phases = [.phases[] | if .number >= $num then .status = "pending" else . end] |
    .lastUpdated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
  ')

  echo "$state" > "$state_file"

  local phase_title
  phase_title=$(echo "$state" | jq -r --argjson num "$phase_num" '.phases[] | select(.number == $num) | .title')

  jq -n \
    --argjson phase "$phase_num" \
    --arg title "$phase_title" \
    '{
      "success": true,
      "restartedFrom": $phase,
      "title": $title
    }'
}

# Check if project has existing state
has_project_state() {
  local project_dir="$1"
  local state_file
  state_file=$(get_state_file "$project_dir")

  if [ -f "$state_file" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# Delete project state
delete_project_state() {
  local project_dir="$1"
  local state_file
  state_file=$(get_state_file "$project_dir")

  if [ -f "$state_file" ]; then
    rm "$state_file"
    echo '{"success": true, "deleted": true}'
  else
    echo '{"success": true, "deleted": false, "reason": "No state file existed"}'
  fi
}

# Record phase failure
record_failure() {
  local project_dir="$1"
  local error_msg="$2"
  local state_file
  state_file=$(get_state_file "$project_dir")

  if [ ! -f "$state_file" ]; then
    echo '{"success": false, "error": "No project state found"}'
    return 1
  fi

  local state
  state=$(cat "$state_file" 2>/dev/null)

  local current_num
  current_num=$(echo "$state" | jq -r '.currentPhase')

  # Mark current phase as failed
  state=$(echo "$state" | jq \
    --argjson num "$current_num" \
    --arg error "$error_msg" \
    '
    .phases = [.phases[] | if .number == $num then .status = "failed" | .error = $error else . end] |
    .lastUpdated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
  ')

  echo "$state" > "$state_file"
  echo '{"success": true, "status": "failed"}'
}

# Main entry point - only run when executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    init)
      init_project_phases "$2" "$3"
      ;;
    current)
      get_current_phase "$2"
      ;;
    advance)
      advance_phase "$2" "$3"
      ;;
    start)
      start_phase "$2"
      ;;
    status)
      get_phase_status "$2"
      ;;
    skip)
      skip_phase "$2"
      ;;
    restart)
      restart_from_phase "$2" "$3"
      ;;
    exists)
      has_project_state "$2"
      ;;
    delete)
      delete_project_state "$2"
      ;;
    fail)
      record_failure "$2" "$3"
      ;;
    state-file)
      get_state_file "$2"
      ;;
    *)
      echo "Usage: $0 {init|current|advance|start|status|skip|restart|exists|delete|fail|state-file} [args]"
      echo ""
      echo "Commands:"
      echo "  init <project_dir> <plan_file>  - Initialize phases from plan file"
      echo "  current <project_dir>           - Get current phase info"
      echo "  advance <project_dir> [session] - Mark current complete, advance to next"
      echo "  start <project_dir>             - Mark current phase as in_progress"
      echo "  status <project_dir>            - Get full project status"
      echo "  skip <project_dir>              - Skip current phase"
      echo "  restart <project_dir> <phase>   - Restart from specific phase"
      echo "  exists <project_dir>            - Check if state exists (true/false)"
      echo "  delete <project_dir>            - Delete project state"
      echo "  fail <project_dir> <message>    - Record phase failure"
      echo "  state-file <project_dir>        - Get path to state file"
      exit 1
      ;;
  esac
fi
