#!/bin/bash
#
# transcript.sh - Shared utilities for reading Claude Code session transcripts
#

# Get the most recent transcript file path
# Usage: get_transcript_path [hook_input_json]
get_transcript_path() {
  local hook_input="${1:-}"
  local transcript_path=""

  # Try to get transcript path from hook input
  if [ -n "$hook_input" ]; then
    transcript_path=$(echo "$hook_input" | jq -r '.transcript_path // empty' 2>/dev/null)
  fi

  # If no transcript path in hook input, find the most recent transcript
  if [ -z "$transcript_path" ] || [ "$transcript_path" = "null" ]; then
    transcript_path=$(find "$HOME/.claude/projects" -name "*.jsonl" -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
  fi

  echo "$transcript_path"
}

# Read transcript content (last N lines to stay within context limits)
# Usage: read_transcript [path] [lines]
read_transcript() {
  local transcript_path="${1:-}"
  local lines="${2:-500}"

  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    tail -"$lines" "$transcript_path" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Read transcript with automatic path detection
# Usage: read_transcript_auto [hook_input_json] [lines]
read_transcript_auto() {
  local hook_input="${1:-}"
  local lines="${2:-500}"

  local path=$(get_transcript_path "$hook_input")
  read_transcript "$path" "$lines"
}

# Extract modified file paths from transcript (Edit/Write tool calls)
# Scans recent transcript lines for file_path fields in Edit and Write tool uses.
# Usage: extract_modified_files [hook_input_json] [lines]
# Returns: JSON array of deduplicated file paths, e.g. ["src/foo.ts", "src/bar.ts"]
extract_modified_files() {
  local hook_input="${1:-}"
  local lines="${2:-500}"

  local transcript_path=$(get_transcript_path "$hook_input")

  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    echo '[]'
    return 0
  fi

  # Read last N lines of JSONL transcript and extract file paths from Edit/Write tool calls.
  # Transcript entries with tool_use have a "name" field (Edit or Write) and
  # an "input" object with "file_path". We look for these patterns in the JSONL.
  local files=$(tail -"$lines" "$transcript_path" 2>/dev/null | \
    jq -r '
      # Each line is a JSON object; look for tool_use content blocks
      select(.type == "assistant") |
      .message.content[]? |
      select(.type == "tool_use") |
      select(.name == "Edit" or .name == "Write") |
      .input.file_path // empty
    ' 2>/dev/null | sort -u)

  if [ -z "$files" ]; then
    echo '[]'
    return 0
  fi

  # Convert newline-separated paths to JSON array
  echo "$files" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]'
}

# Check if this conversation has an active recursive-dev session
# Looks for /recursive-dev command in USER messages only, then verifies
# there's an active session for the current project directory.
# Usage: get_recursive_dev_session [hook_input_json] [recursive_dir]
# Returns: Session ID if found and active, empty string if not
get_recursive_dev_session() {
  local hook_input="${1:-}"
  local recursive_dir="${2:-$HOME/.claude/recursive-dev}"
  local transcript_path=$(get_transcript_path "$hook_input")

  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    echo ""
    return 0
  fi

  # Check if any USER message contains /recursive-dev or /automated-dev-cycle command.
  # Only user messages count - not assistant output, system messages, or hook injections.
  # We check for both because /automated-dev-cycle invokes /recursive-dev internally.
  local has_command=$(cat "$transcript_path" 2>/dev/null | jq -r '
    select(.type == "user") |
    .message.content[]? |
    select(type == "string") |
    select(test("/recursive-dev|/automated-dev-cycle"))
  ' 2>/dev/null | head -1)

  if [ -z "$has_command" ]; then
    echo ""
    return 0
  fi

  # User invoked /recursive-dev in this conversation.
  # Find the active session for this project directory.
  local current_dir=$(pwd)

  for session_dir in "$recursive_dir"/*/; do
    [ -d "$session_dir" ] || continue
    local tree_file="$session_dir/tree.json"
    local state_file="$session_dir/state.json"
    [ -f "$tree_file" ] && [ -f "$state_file" ] || continue

    # Check project directory matches current working directory
    local project_dir=$(jq -r '.projectDir // empty' "$tree_file" 2>/dev/null)
    [ "$project_dir" = "$current_dir" ] || continue

    # Check session is active (has currentTask or currentReviewTask)
    local current_task=$(jq -r '.currentTask // empty' "$state_file" 2>/dev/null)
    local current_review=$(jq -r '.currentReviewTask // empty' "$state_file" 2>/dev/null)

    if { [ -n "$current_task" ] && [ "$current_task" != "null" ]; } || \
       { [ -n "$current_review" ] && [ "$current_review" != "null" ]; }; then
      echo "$(basename "$session_dir")"
      return 0
    fi
  done

  echo ""
}
