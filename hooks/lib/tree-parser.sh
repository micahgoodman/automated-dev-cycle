#!/bin/bash
#
# tree-parser.sh - Utilities for parsing tree-planner markdown to JSON
#
# Parses the markdown tree format into structured JSON for recursive-dev
#

# Parse entire tree from markdown file
# Usage: parse_tree_file /path/to/plan.md
parse_tree_file() {
  local file="$1"

  if [ ! -f "$file" ]; then
    echo '{"error": "File not found"}'
    return 1
  fi

  # Use a temp file for intermediate processing
  local temp_tasks=$(mktemp)
  trap "rm -f $temp_tasks" EXIT

  # Extract project name from header
  local project_name=$(grep -m1 '^# Project Tree:' "$file" | sed 's/^# Project Tree:[[:space:]]*//')

  # Find the Task Hierarchy section and extract task lines
  local in_hierarchy=false

  while IFS= read -r line || [ -n "$line" ]; do
    # Check for section markers
    if [[ "$line" =~ ^"## Task Hierarchy" ]]; then
      in_hierarchy=true
      continue
    fi

    if [ "$in_hierarchy" = true ] && [[ "$line" =~ ^"---" ]]; then
      break
    fi

    # Parse task lines (lines starting with - T after optional whitespace)
    if [ "$in_hierarchy" = true ] && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*T ]]; then
      # Count leading spaces for indent
      local stripped="${line#"${line%%[![:space:]]*}"}"
      local spaces=$((${#line} - ${#stripped}))
      local indent=$((spaces / 2))

      # Remove leading whitespace and dash
      local content=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')

      # Extract task ID (first word)
      local id=$(echo "$content" | awk '{print $1}')

      # Extract status
      local status=""
      if [[ "$content" =~ \[PENDING\] ]]; then
        status="PENDING"
      elif [[ "$content" =~ \[IN\ PROGRESS\] ]]; then
        status="IN PROGRESS"
      elif [[ "$content" =~ \[DONE\] ]]; then
        status="DONE"
      fi

      # Extract description and criteria
      local after_status=$(echo "$content" | sed 's/^[^]]*\][[:space:]]*//')
      local description=""
      local criteria=""

      if [[ "$after_status" =~ \|.*verify: ]]; then
        description=$(echo "$after_status" | sed 's/[[:space:]]*|.*//')
        criteria=$(echo "$after_status" | sed 's/.*|[[:space:]]*verify:[[:space:]]*//')
      else
        description="$after_status"
        criteria="Task completes successfully"
      fi

      # Write to temp file: indent|id|status|description|criteria
      printf '%d|%s|%s|%s|%s\n' "$indent" "$id" "$status" "$description" "$criteria" >> "$temp_tasks"
    fi
  done < "$file"

  # Build JSON structure
  local tasks_json='{}'
  local prev_at_indent='{}'

  while IFS='|' read -r indent id status description criteria; do
    [ -z "$id" ] && continue

    # Determine parent based on indent
    local parent="null"
    if [ "$indent" -gt 0 ]; then
      local parent_indent=$((indent - 1))
      parent=$(echo "$prev_at_indent" | jq -r --arg i "$parent_indent" '.[$i] // "null"')
      [ "$parent" = "null" ] && parent="null"
    fi

    # Update prev_at_indent tracker
    prev_at_indent=$(echo "$prev_at_indent" | jq --arg i "$indent" --arg id "$id" '.[$i] = $id')

    # Add task to tasks object
    tasks_json=$(echo "$tasks_json" | jq \
      --arg id "$id" \
      --arg desc "$description" \
      --arg criteria "$criteria" \
      --arg status "$status" \
      --arg parent "$parent" \
      '.[$id] = {id: $id, description: $desc, criteria: $criteria, status: $status, parent: (if $parent == "null" then null else $parent end), children: []}')

  done < "$temp_tasks"

  # Build children arrays
  for id in $(echo "$tasks_json" | jq -r 'keys[]'); do
    local parent=$(echo "$tasks_json" | jq -r --arg id "$id" '.[$id].parent // empty')
    if [ -n "$parent" ] && [ "$parent" != "null" ]; then
      tasks_json=$(echo "$tasks_json" | jq --arg id "$id" --arg parent "$parent" '.[$parent].children += [$id]')
    fi
  done

  # Calculate execution order (depth-first, branch-complete)
  local order='[]'

  # Get top-level tasks
  local top_level=$(echo "$tasks_json" | jq -r '[to_entries[] | select(.value.parent == null) | .key] | sort | .[]')

  # Recursive function via subshell
  get_order() {
    local task_id="$1"
    local tasks="$2"
    local result='[]'

    # Get children
    local children=$(echo "$tasks" | jq -r --arg id "$task_id" '.[$id].children[]' 2>/dev/null)

    # Process children first (depth-first)
    for child in $children; do
      local child_order=$(get_order "$child" "$tasks")
      result=$(echo "$result" | jq --argjson co "$child_order" '. + $co')
    done

    # Add this task after its children
    result=$(echo "$result" | jq --arg id "$task_id" '. + [$id]')

    echo "$result"
  }

  for task_id in $top_level; do
    local task_order=$(get_order "$task_id" "$tasks_json")
    order=$(echo "$order" | jq --argjson to "$task_order" '. + $to')
  done

  # Build final output
  # Include projectDir (current working directory) for session matching
  local project_dir=$(pwd)

  jq -n \
    --arg root "$project_name" \
    --arg planFile "$file" \
    --arg projectDir "$project_dir" \
    --argjson tasks "$tasks_json" \
    --argjson order "$order" \
    '{root: $root, planFile: $planFile, projectDir: $projectDir, tasks: $tasks, order: $order}'
}

# Export tree to JSON file
# Usage: export_tree_json /path/to/plan.md [/path/to/output.json]
export_tree_json() {
  local input_file="$1"
  local output_file="${2:-$HOME/.claude/recursive-dev/tree-export.json}"

  # Ensure output directory exists
  mkdir -p "$(dirname "$output_file")"

  # Parse and write
  parse_tree_file "$input_file" > "$output_file"

  echo "$output_file"
}
