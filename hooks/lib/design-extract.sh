#!/bin/bash
#
# design-extract.sh - Extract @design annotations from source code into DESIGN.md
#
# Scans source files for structured @design annotations and generates
# a DESIGN.md document with three views: summary table, by task, and by file.
#
# Usage:
#   design-extract.sh <project_dir> [--output <path>] [--task-filter T1.2] [--format md|json]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECURSIVE_DIR="$HOME/.claude/recursive-dev"

# ─── ARGUMENT PARSING ──────────────────────────────────────────────────────────

PROJECT_DIR=""
OUTPUT_PATH=""
TASK_FILTER=""
FORMAT="md"

while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --task-filter)
      TASK_FILTER="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$PROJECT_DIR" ]; then
  echo "Usage: design-extract.sh <project_dir> [--output <path>] [--task-filter T1.2] [--format md|json]" >&2
  exit 1
fi

# Resolve to absolute path
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || {
  echo "Error: Directory not found: $PROJECT_DIR" >&2
  exit 1
}

if [ -z "$OUTPUT_PATH" ]; then
  OUTPUT_PATH="$PROJECT_DIR/DESIGN.md"
fi

# ─── FILE DISCOVERY ────────────────────────────────────────────────────────────

get_source_files() {
  local dir="$1"
  cd "$dir"

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Use git ls-files for git repos (respects .gitignore)
    git ls-files --cached --others --exclude-standard 2>/dev/null
  else
    # Fallback: find with common exclusions
    find . -type f \
      -not -path '*/node_modules/*' \
      -not -path '*/.git/*' \
      -not -path '*/__pycache__/*' \
      -not -path '*/target/*' \
      -not -path '*/dist/*' \
      -not -path '*/build/*' \
      -not -path '*/.next/*' \
      -not -path '*/vendor/*' \
      -not -path '*/.venv/*' \
      -not -path '*/venv/*' \
      -not -name '*.min.js' \
      -not -name '*.min.css' \
      -not -name 'package-lock.json' \
      -not -name 'yarn.lock' \
      -not -name 'DESIGN.md' \
      2>/dev/null | sed 's|^\./||'
  fi
}

# ─── ANNOTATION PARSING ───────────────────────────────────────────────────────

# Parse @design annotations from a single file
# Outputs JSON array of annotations
parse_file() {
  local file="$1"
  local filepath="$2"  # relative path for display

  # Quick check: does this file contain @design at all?
  if ! grep -q '@design' "$file" 2>/dev/null; then
    return
  fi

  awk -v filepath="$filepath" '
  BEGIN {
    in_annotation = 0
    title = ""
    current_field = ""
    current_value = ""
    line_num = 0
    design_val = ""
    context_val = ""
    tradeoffs_val = ""
    alternatives_val = ""
    task_val = ""
    count = 0
    printf "["
  }

  function strip_comment_prefix(line) {
    # Strip common comment prefixes and return the content
    # Handles: # // -- % * (with optional leading whitespace)
    gsub(/^[[:space:]]*/, "", line)
    if (match(line, /^#[[:space:]]?/)) {
      return substr(line, RSTART + RLENGTH)
    } else if (match(line, /^\/\/[[:space:]]?/)) {
      return substr(line, RSTART + RLENGTH)
    } else if (match(line, /^--[[:space:]]?/)) {
      return substr(line, RSTART + RLENGTH)
    } else if (match(line, /^%[[:space:]]?/)) {
      return substr(line, RSTART + RLENGTH)
    } else if (match(line, /^\*[[:space:]]?/)) {
      return substr(line, RSTART + RLENGTH)
    }
    return ""
  }

  function is_comment(line) {
    gsub(/^[[:space:]]*/, "", line)
    return (line ~ /^#/ || line ~ /^\/\// || line ~ /^--/ || line ~ /^%/ || line ~ /^\*/)
  }

  function save_field() {
    if (current_field == "design") design_val = current_value
    else if (current_field == "context") context_val = current_value
    else if (current_field == "tradeoffs") tradeoffs_val = current_value
    else if (current_field == "alternatives") alternatives_val = current_value
    else if (current_field == "task") task_val = current_value
    current_field = ""
    current_value = ""
  }

  function json_escape(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/\t/, "\\t", s)
    gsub(/\n/, "\\n", s)
    # Remove trailing whitespace
    gsub(/[[:space:]]+$/, "", s)
    return s
  }

  function emit_annotation() {
    if (title == "") return
    save_field()

    if (count > 0) printf ","
    printf "{\"title\":\"%s\"", json_escape(title)
    printf ",\"file\":\"%s\"", json_escape(filepath)
    printf ",\"line\":%d", line_num
    if (design_val != "") printf ",\"design\":\"%s\"", json_escape(design_val)
    if (context_val != "") printf ",\"context\":\"%s\"", json_escape(context_val)
    if (tradeoffs_val != "") printf ",\"tradeoffs\":\"%s\"", json_escape(tradeoffs_val)
    if (alternatives_val != "") printf ",\"alternatives\":\"%s\"", json_escape(alternatives_val)
    if (task_val != "") printf ",\"task\":\"%s\"", json_escape(task_val)
    printf "}"
    count++

    # Reset
    title = ""
    design_val = ""
    context_val = ""
    tradeoffs_val = ""
    alternatives_val = ""
    task_val = ""
    current_field = ""
    current_value = ""
  }

  {
    line = $0

    if (in_annotation) {
      if (!is_comment(line)) {
        # Non-comment line ends annotation
        emit_annotation()
        in_annotation = 0
      } else {
        content = strip_comment_prefix(line)

        # Check if this is an indented sub-field line (2+ spaces)
        if (content ~ /^[[:space:]][[:space:]]/) {
          gsub(/^[[:space:]]+/, "", content)

          # Check for field key
          if (match(content, /^design:[[:space:]]*/)) {
            save_field()
            current_field = "design"
            current_value = substr(content, RSTART + RLENGTH)
          } else if (match(content, /^context:[[:space:]]*/)) {
            save_field()
            current_field = "context"
            current_value = substr(content, RSTART + RLENGTH)
          } else if (match(content, /^tradeoffs:[[:space:]]*/)) {
            save_field()
            current_field = "tradeoffs"
            current_value = substr(content, RSTART + RLENGTH)
          } else if (match(content, /^alternatives:[[:space:]]*/)) {
            save_field()
            current_field = "alternatives"
            current_value = substr(content, RSTART + RLENGTH)
          } else if (match(content, /^task:[[:space:]]*/)) {
            save_field()
            current_field = "task"
            current_value = substr(content, RSTART + RLENGTH)
          } else {
            # Continuation of current field value
            if (current_field != "") {
              current_value = current_value " " content
            }
          }
        } else {
          # Non-indented comment line — could be a new @design or end of annotation
          if (content ~ /^@design/) {
            emit_annotation()
            in_annotation = 0
            # Start new annotation on this line (fall through to below)
          } else {
            # Non-indented, non-@design comment line ends annotation
            emit_annotation()
            in_annotation = 0
          }
        }
      }
    }

    # Check for new @design annotation start (both when not in_annotation and when we just found a new one)
    if (!in_annotation) {
      content = strip_comment_prefix(line)
      if (content ~ /^@design[[:space:]]/) {
        in_annotation = 1
        line_num = NR
        # Extract title (everything after @design and whitespace)
        match(content, /^@design[[:space:]]+/)
        title = substr(content, RSTART + RLENGTH)
        gsub(/[[:space:]]+$/, "", title)
      }
    }
  }

  END {
    if (in_annotation) emit_annotation()
    printf "]"
  }
  ' "$file"
}

# ─── TREE.JSON LOOKUP ──────────────────────────────────────────────────────────

# Find task descriptions from tree.json if a recursive-dev session exists
get_task_descriptions() {
  local project_dir="$1"

  for session_dir in "$RECURSIVE_DIR"/*/; do
    [ -d "$session_dir" ] || continue
    local tree_file="$session_dir/tree.json"
    [ -f "$tree_file" ] || continue

    local session_project
    session_project=$(jq -r '.projectDir // empty' "$tree_file" 2>/dev/null)

    if [ "$session_project" = "$project_dir" ]; then
      # Found matching session — extract task descriptions
      jq -r '.tasks // {} | to_entries | map({key: .key, value: .value.description}) | from_entries' "$tree_file" 2>/dev/null
      return
    fi
  done

  echo '{}'
}

# ─── MAIN ──────────────────────────────────────────────────────────────────────

# Collect all annotations
ALL_ANNOTATIONS="[]"

while IFS= read -r file; do
  [ -n "$file" ] || continue
  full_path="$PROJECT_DIR/$file"
  [ -f "$full_path" ] || continue

  file_annotations=$(parse_file "$full_path" "$file")

  if [ -n "$file_annotations" ] && [ "$file_annotations" != "[]" ]; then
    ALL_ANNOTATIONS=$(echo "$ALL_ANNOTATIONS" "$file_annotations" | jq -s '.[0] + .[1]')
  fi
done < <(get_source_files "$PROJECT_DIR")

# Apply task filter if specified
if [ -n "$TASK_FILTER" ]; then
  ALL_ANNOTATIONS=$(echo "$ALL_ANNOTATIONS" | jq --arg task "$TASK_FILTER" '[.[] | select(.task == $task)]')
fi

ANNOTATION_COUNT=$(echo "$ALL_ANNOTATIONS" | jq 'length')

# ─── JSON OUTPUT ───────────────────────────────────────────────────────────────

if [ "$FORMAT" = "json" ]; then
  echo "$ALL_ANNOTATIONS" | jq '.'
  exit 0
fi

# ─── MARKDOWN OUTPUT ───────────────────────────────────────────────────────────

TASK_DESCRIPTIONS=$(get_task_descriptions "$PROJECT_DIR")

{
  cat <<'HEADER'
# Design Decisions

> Auto-generated from `@design` annotations in source code.
> Canonical source: inline code comments. Regenerate with: `~/.claude/hooks/lib/design-extract.sh .`

HEADER

  if [ "$ANNOTATION_COUNT" -eq 0 ]; then
    echo "No \`@design\` annotations found."
    echo ""
  else
    # ─── Summary Table ─────────────────────────────────────────────────────────
    echo "## Summary"
    echo ""
    echo "| # | Decision | File | Task |"
    echo "|---|----------|------|------|"

    echo "$ALL_ANNOTATIONS" | jq -r '
      to_entries | .[] |
      "| \(.key + 1) | \(.value.title) | `\(.value.file):\(.value.line)` | \(.value.task // "-") |"
    '

    echo ""
    echo "---"
    echo ""

    # ─── By Task ───────────────────────────────────────────────────────────────
    echo "## Decisions by Task"
    echo ""

    # Get unique tasks (including null/empty for ungrouped)
    TASKS=$(echo "$ALL_ANNOTATIONS" | jq -r '[.[].task // ""] | unique | .[]')

    COUNTER=1
    while IFS= read -r task; do
      [ -z "$task" ] && continue

      # Get task description from tree.json if available
      task_desc=$(echo "$TASK_DESCRIPTIONS" | jq -r --arg id "$task" '.[$id] // empty' 2>/dev/null)
      if [ -n "$task_desc" ] && [ "$task_desc" != "null" ]; then
        echo "### $task: $task_desc"
      else
        echo "### $task"
      fi
      echo ""

      echo "$ALL_ANNOTATIONS" | jq -r --arg task "$task" --argjson counter "$COUNTER" '
        [.[] | select(.task == $task)] | to_entries | .[] |
        "#### \(.key + $counter). \(.value.title)\n**File:** `\(.value.file):\(.value.line)`\n\n**Design:** \(.value.design // "Not specified")\n\n**Context:** \(.value.context // "Not specified")\n" +
        (if .value.tradeoffs then "**Trade-offs:** \(.value.tradeoffs)\n\n" else "" end) +
        (if .value.alternatives then "**Alternatives considered:** \(.value.alternatives)\n\n" else "" end) +
        "---\n"
      '

      TASK_COUNT=$(echo "$ALL_ANNOTATIONS" | jq --arg task "$task" '[.[] | select(.task == $task)] | length')
      COUNTER=$((COUNTER + TASK_COUNT))
    done <<< "$TASKS"

    # Ungrouped annotations (no task field)
    UNGROUPED=$(echo "$ALL_ANNOTATIONS" | jq '[.[] | select(.task == null or .task == "")]')
    UNGROUPED_COUNT=$(echo "$UNGROUPED" | jq 'length')

    if [ "$UNGROUPED_COUNT" -gt 0 ]; then
      echo "### Ungrouped"
      echo ""

      echo "$UNGROUPED" | jq -r --argjson counter "$COUNTER" '
        to_entries | .[] |
        "#### \(.key + $counter). \(.value.title)\n**File:** `\(.value.file):\(.value.line)`\n\n**Design:** \(.value.design // "Not specified")\n\n**Context:** \(.value.context // "Not specified")\n" +
        (if .value.tradeoffs then "**Trade-offs:** \(.value.tradeoffs)\n\n" else "" end) +
        (if .value.alternatives then "**Alternatives considered:** \(.value.alternatives)\n\n" else "" end) +
        "---\n"
      '
    fi

    echo ""

    # ─── By File ───────────────────────────────────────────────────────────────
    echo "## Decisions by File"
    echo ""

    FILES=$(echo "$ALL_ANNOTATIONS" | jq -r '[.[].file] | unique | .[]')

    while IFS= read -r file; do
      [ -z "$file" ] && continue
      echo "### $file"
      echo ""

      echo "$ALL_ANNOTATIONS" | jq -r --arg file "$file" '
        [.[] | select(.file == $file)] | .[] |
        "- **Line \(.line) — \(.title)** \(if .task then "(\(.task))" else "" end): \(.design // "Not specified")"
      '

      echo ""
    done <<< "$FILES"
  fi
} > "$OUTPUT_PATH"

echo "Generated $OUTPUT_PATH with $ANNOTATION_COUNT annotation(s)"
