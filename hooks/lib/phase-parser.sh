#!/bin/bash
#
# phase-parser.sh - Parse phase markers from plan files
#
# Extracts phases from plan files that use explicit HTML comment markers:
#   <!-- PHASE:1:Architecture Setup -->
#   <!-- PHASE:2:Core Infrastructure -->
#   <!-- PHASE:END -->
#

# Parse all phases from a plan file
# Usage: parse_phases <plan_file>
# Returns: JSON array of phases (empty array if file not found or no phases)
parse_phases() {
  local plan_file="$1"

  if [ ! -f "$plan_file" ]; then
    echo '[]'
    return 1
  fi

  local content
  content=$(cat "$plan_file")

  # Find all phase markers and extract info
  # Marker format: <!-- PHASE:number:title -->
  local phases="[]"
  local line_num=0
  local prev_phase_end=0
  local current_phase=""
  local current_number=""
  local current_title=""
  local current_start=0

  while IFS= read -r line || [ -n "$line" ]; do
    ((line_num++))

    # Check for phase marker
    if [[ "$line" =~ \<!--[[:space:]]*PHASE:([0-9]+):([^>]+)[[:space:]]*--\> ]]; then
      # If we had a previous phase, close it
      if [ -n "$current_phase" ]; then
        local end_line=$((line_num - 1))
        phases=$(echo "$phases" | jq \
          --arg num "$current_number" \
          --arg title "$current_title" \
          --argjson start "$current_start" \
          --argjson end "$end_line" \
          '. + [{
            "number": ($num | tonumber),
            "title": ($title | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
            "startLine": $start,
            "endLine": $end
          }]')
      fi

      # Start new phase
      current_number="${BASH_REMATCH[1]}"
      current_title="${BASH_REMATCH[2]}"
      current_start=$line_num
      current_phase="$current_number"

    # Check for end marker
    elif [[ "$line" =~ \<!--[[:space:]]*PHASE:END[[:space:]]*--\> ]]; then
      if [ -n "$current_phase" ]; then
        local end_line=$((line_num - 1))
        phases=$(echo "$phases" | jq \
          --arg num "$current_number" \
          --arg title "$current_title" \
          --argjson start "$current_start" \
          --argjson end "$end_line" \
          '. + [{
            "number": ($num | tonumber),
            "title": ($title | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
            "startLine": $start,
            "endLine": $end
          }]')
        current_phase=""
      fi
    fi
  done < "$plan_file"

  # If file ended without PHASE:END, close the last phase
  if [ -n "$current_phase" ]; then
    phases=$(echo "$phases" | jq \
      --arg num "$current_number" \
      --arg title "$current_title" \
      --argjson start "$current_start" \
      --argjson end "$line_num" \
      '. + [{
        "number": ($num | tonumber),
        "title": ($title | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
        "startLine": $start,
        "endLine": $end
      }]')
  fi

  # Sort by phase number
  phases=$(echo "$phases" | jq 'sort_by(.number)')

  echo "$phases"
}

# Get content for a specific phase
# Usage: get_phase_content <plan_file> <phase_number>
# Returns: The content between the phase marker and the next marker (or end of file)
get_phase_content() {
  local plan_file="$1"
  local phase_number="$2"

  if [ ! -f "$plan_file" ]; then
    echo ""
    return 1
  fi

  # Get phase info
  local phases
  phases=$(parse_phases "$plan_file")

  local phase_info
  phase_info=$(echo "$phases" | jq -r --arg num "$phase_number" '.[] | select(.number == ($num | tonumber))')

  if [ -z "$phase_info" ]; then
    echo ""
    return 1
  fi

  local start_line end_line
  start_line=$(echo "$phase_info" | jq -r '.startLine')
  end_line=$(echo "$phase_info" | jq -r '.endLine')

  # Extract lines (skip the marker line itself)
  sed -n "$((start_line + 1)),${end_line}p" "$plan_file"
}

# Validate phase markers in a plan file
# Usage: validate_phase_markers <plan_file>
# Returns: JSON with validation results
validate_phase_markers() {
  local plan_file="$1"

  if [ ! -f "$plan_file" ]; then
    echo '{"valid": false, "error": "Plan file not found", "warnings": [], "phases": 0}'
    return 1
  fi

  local phases
  phases=$(parse_phases "$plan_file")

  local phase_count
  phase_count=$(echo "$phases" | jq 'length')

  if [ "$phase_count" -eq 0 ]; then
    echo '{"valid": false, "error": "No phase markers found", "warnings": [], "phases": 0}'
    return 1
  fi

  local warnings="[]"
  local valid=true

  # Check for sequential numbering
  local expected=1
  local numbers
  numbers=$(echo "$phases" | jq -r '.[].number' | sort -n)

  for num in $numbers; do
    if [ "$num" -ne "$expected" ]; then
      warnings=$(echo "$warnings" | jq --arg msg "Phase numbers not sequential: expected $expected, found $num" '. + [$msg]')
    fi
    expected=$((num + 1))
  done

  # Check for duplicate phase numbers
  local unique_count
  unique_count=$(echo "$phases" | jq '[.[].number] | unique | length')

  if [ "$unique_count" -ne "$phase_count" ]; then
    warnings=$(echo "$warnings" | jq '. + ["Duplicate phase numbers found"]')
    valid=false
  fi

  # Check for empty phases (very short content)
  while read -r phase; do
    local num title start end
    num=$(echo "$phase" | jq -r '.number')
    title=$(echo "$phase" | jq -r '.title')
    start=$(echo "$phase" | jq -r '.startLine')
    end=$(echo "$phase" | jq -r '.endLine')

    local lines=$((end - start))
    if [ "$lines" -lt 5 ]; then
      warnings=$(echo "$warnings" | jq --arg msg "Phase $num ($title) appears very short ($lines lines)" '. + [$msg]')
    fi
  done < <(echo "$phases" | jq -c '.[]')

  local warning_count
  warning_count=$(echo "$warnings" | jq 'length')

  jq -n \
    --argjson valid "$valid" \
    --argjson warnings "$warnings" \
    --argjson phases "$phase_count" \
    '{
      "valid": $valid,
      "error": null,
      "warnings": $warnings,
      "phases": $phases
    }'
}

# Get phase count
# Usage: get_phase_count <plan_file>
# Returns: Number of phases
get_phase_count() {
  local plan_file="$1"

  if [ ! -f "$plan_file" ]; then
    echo "0"
    return 1
  fi

  local phases
  phases=$(parse_phases "$plan_file")
  echo "$phases" | jq 'length'
}

# Check if plan file has phase markers
# Usage: has_phase_markers <plan_file>
# Returns: "true" or "false"
has_phase_markers() {
  local plan_file="$1"

  if [ ! -f "$plan_file" ]; then
    echo "false"
    return 1
  fi

  if grep -q '<!-- PHASE:[0-9]' "$plan_file" 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

# Main entry point - only run when executed directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    parse)
      parse_phases "$2"
      ;;
    content)
      get_phase_content "$2" "$3"
      ;;
    validate)
      validate_phase_markers "$2"
      ;;
    count)
      get_phase_count "$2"
      ;;
    has-markers)
      has_phase_markers "$2"
      ;;
    *)
      echo "Usage: $0 {parse|content|validate|count|has-markers} <plan_file> [phase_number]"
      echo ""
      echo "Commands:"
      echo "  parse <file>              - Parse all phases, return JSON array"
      echo "  content <file> <number>   - Get content for a specific phase"
      echo "  validate <file>           - Validate phase markers, return JSON"
      echo "  count <file>              - Get number of phases"
      echo "  has-markers <file>        - Check if file has phase markers"
      exit 1
      ;;
  esac
fi
