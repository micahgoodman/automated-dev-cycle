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
# SIMPLIFIED: Just scan for any active session matching this project directory.
# No longer requires transcript detection (which fails after compaction).
# Usage: get_recursive_dev_session [hook_input_json] [recursive_dir]
# Returns: Session ID if found and active, empty string if not
get_recursive_dev_session() {
  local hook_input="${1:-}"
  local recursive_dir="${2:-$HOME/.claude/recursive-dev}"
  local current_dir=$(pwd)
  local debug_log="/tmp/recursive-dev-session-debug.log"

  {
    echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') get_recursive_dev_session ==="
    echo "current_dir: $current_dir"
    echo "recursive_dir: $recursive_dir"
  } >> "$debug_log" 2>/dev/null

  # Scan all sessions for one that matches this project and is active
  for session_dir in "$recursive_dir"/*/; do
    [ -d "$session_dir" ] || continue
    local tree_file="$session_dir/tree.json"
    local state_file="$session_dir/state.json"

    echo "  Checking: $(basename "$session_dir")" >> "$debug_log" 2>/dev/null

    if [ ! -f "$tree_file" ] || [ ! -f "$state_file" ]; then
      echo "    Missing tree.json or state.json" >> "$debug_log" 2>/dev/null
      continue
    fi

    # Check project directory matches (flexible: prefix match either way)
    local project_dir=$(jq -r '.projectDir // empty' "$tree_file" 2>/dev/null)
    echo "    projectDir: $project_dir" >> "$debug_log" 2>/dev/null

    if [ -z "$project_dir" ]; then
      echo "    Empty projectDir, skip" >> "$debug_log" 2>/dev/null
      continue
    fi

    # Match if current_dir starts with project_dir OR project_dir starts with current_dir
    if [[ "$current_dir" != "$project_dir"* ]] && [[ "$project_dir" != "$current_dir"* ]]; then
      echo "    Path mismatch, skip" >> "$debug_log" 2>/dev/null
      continue
    fi
    echo "    Path matches!" >> "$debug_log" 2>/dev/null

    # Check session is active via explicit flag OR has currentTask/currentReviewTask/currentDesignTask
    local is_active=$(jq -r '.active // empty' "$state_file" 2>/dev/null)
    local current_task=$(jq -r '.currentTask // empty' "$state_file" 2>/dev/null)
    local current_review=$(jq -r '.currentReviewTask // empty' "$state_file" 2>/dev/null)
    local current_design=$(jq -r '.currentDesignTask // empty' "$state_file" 2>/dev/null)
    local phase=$(jq -r '.phase // "dev"' "$state_file" 2>/dev/null)

    {
      echo "    is_active: '$is_active'"
      echo "    current_task: '$current_task'"
      echo "    current_review: '$current_review'"
      echo "    current_design: '$current_design'"
      echo "    phase: '$phase'"
    } >> "$debug_log" 2>/dev/null

    # Skip completed sessions — phase="complete" means all reviews finished
    if [ "$phase" = "complete" ]; then
      echo "    Phase complete, not active" >> "$debug_log" 2>/dev/null
      continue
    fi

    # Session is active if:
    # 1. Explicit active flag is true, OR
    # 2. Has a currentTask (in dev phase), OR
    # 3. Has a currentReviewTask (in review phase), OR
    # 4. Has a currentDesignTask (in design-documentation phase)
    # Note: phase="review" alone is NOT sufficient — old/abandoned review sessions
    # without a currentReviewTask would loop forever requesting holistic reviews.
    if [ "$is_active" = "true" ] || \
       { [ -n "$current_task" ] && [ "$current_task" != "null" ]; } || \
       { [ -n "$current_review" ] && [ "$current_review" != "null" ]; } || \
       { [ -n "$current_design" ] && [ "$current_design" != "null" ]; }; then
      echo "    ACTIVE - returning $(basename "$session_dir")" >> "$debug_log" 2>/dev/null
      echo "$(basename "$session_dir")"
      return 0
    else
      echo "    Not active" >> "$debug_log" 2>/dev/null
    fi
  done

  echo "  No active session found" >> "$debug_log" 2>/dev/null
  echo ""
}
