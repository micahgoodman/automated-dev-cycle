#!/bin/bash
#
# verify.sh - Shared verification utilities for Claude Code hooks
#

# Run a test command and capture results
# Usage: run_test_command "test command"
# Returns: Sets TEST_OUTPUT and TEST_EXIT_CODE global variables
run_test_command() {
  local test_cmd="${1:-}"

  TEST_OUTPUT=""
  TEST_EXIT_CODE=0

  if [ -n "$test_cmd" ] && [ "$test_cmd" != "null" ] && [ "$test_cmd" != "" ]; then
    TEST_OUTPUT=$(eval "$test_cmd" 2>&1)
    TEST_EXIT_CODE=$?
  fi
}

# Build a verification prompt for Claude
# Usage: build_review_prompt "criteria" "test_result" "test_exit_code" "transcript_content" [extra_context]
build_review_prompt() {
  local criteria="$1"
  local test_result="${2:-}"
  local test_exit="${3:-0}"
  local transcript="${4:-}"
  local extra_context="${5:-}"

  local prompt="You are a verification assistant. Review the work session against the following criteria and determine if the task is truly complete.

VERIFICATION CRITERIA: $criteria

Take your time to evaluate the code from multiple perspectives, checking for different failure modes (race conditions, etc.). We’re not writing code just for the sake of writing code - the whole point of this is the build something that works perfectly for real-world users, and we achieve that by making sure we’re writing the code so that each part fits together perfectly. Hold yourself to a high standard. I know you can reach it, it’s just a matter of taking your time and using the talent for constructing high-quality code that I know you have."

  # Add extra context if provided (e.g., for parent tasks)
  if [ -n "$extra_context" ]; then
    prompt="$prompt

$extra_context"
  fi

  # Add test results if available
  if [ -n "$test_result" ]; then
    prompt="$prompt

TEST COMMAND OUTPUT (exit code $test_exit):
$test_result"
  fi

  # Add transcript if available
  if [ -n "$transcript" ]; then
    prompt="$prompt

SESSION TRANSCRIPT (recent activity):
$transcript"
  else
    prompt="$prompt

NOTE: Could not read session transcript. Base your judgment on the test output if available, or assume the task needs verification."
  fi

  prompt="$prompt

Based on the information above, determine if the task is truly complete and all criteria are met.

IMPORTANT: Respond ONLY with valid JSON in this exact format (no other text before or after):
{\"pass\": true_or_false, \"issues\": [\"issue1\", \"issue2\"], \"summary\": \"brief summary of status\"}"

  echo "$prompt"
}

# Run verification review using claude -p
# Usage: run_verification "prompt"
# Returns: JSON result with pass, issues, summary
run_verification() {
  local prompt="$1"

  # Run review using claude -p (print mode, non-interactive)
  local review_raw=$(claude -p "$prompt" 2>/dev/null || echo '{"pass": false, "issues": ["Review command failed"], "summary": "Could not complete review"}')

  # Extract JSON from response
  local review=$(echo "$review_raw" | grep -o '{[^}]*"pass"[^}]*}' | head -1)

  # If simple extraction failed, try to find any valid JSON object
  if [ -z "$review" ] || ! echo "$review" | jq . >/dev/null 2>&1; then
    review=$(echo "$review_raw" | sed -n 's/.*\({.*}\).*/\1/p' | tail -1)
  fi

  # Validate we got valid JSON with required fields
  if ! echo "$review" | jq -e '.pass' >/dev/null 2>&1; then
    review='{"pass": false, "issues": ["Could not parse review response"], "summary": "Review parsing failed"}'
  fi

  echo "$review"
}

# Parse review result
# Usage: parse_review_result "$review_json"
# Sets: REVIEW_PASS, REVIEW_ISSUES, REVIEW_SUMMARY
parse_review_result() {
  local review="$1"

  REVIEW_PASS=$(echo "$review" | jq -r '.pass // false')
  REVIEW_ISSUES=$(echo "$review" | jq -c '.issues // []')
  REVIEW_SUMMARY=$(echo "$review" | jq -r '.summary // "No summary"')
}

# Format issues for display
# Usage: format_issues "$issues_json"
format_issues() {
  local issues="$1"

  local issues_text=$(echo "$issues" | jq -r '.[]' 2>/dev/null | sed 's/^/- /' | tr '\n' ' ')
  if [ -z "$issues_text" ]; then
    issues_text="No specific issues listed"
  fi

  echo "$issues_text"
}

# DEPRECATED: This function was used by the old claude -p subprocess approach.
# The recursive-dev review phase now uses Task tool subagents instead.
# Kept for reference — contains useful prompt patterns for fresh-eyes reviews.
#
# Build a review phase prompt for the fresh-eyes recursive review
# Usage: build_review_phase_prompt "plan_file_path" "task_id" "task_desc" "task_criteria" "is_parent" "children_json" "modified_files_json" "tree_json" ["project_dir"]
# Note: Does NOT include dev transcript — the whole point is fresh eyes
build_review_phase_prompt() {
  local plan_file="$1"
  local task_id="$2"
  local task_desc="$3"
  local task_criteria="$4"
  local is_parent="$5"
  local children_json="$6"
  local modified_files_json="$7"
  local tree_json="$8"
  local project_dir="${9:-}"

  # Read plan file content
  local plan_content=""
  if [ -n "$plan_file" ] && [ -f "$plan_file" ]; then
    plan_content=$(cat "$plan_file" 2>/dev/null)
  fi

  local prompt=""

  if [ -n "$plan_content" ]; then
    prompt="PROJECT GOALS AND CONTEXT:
$plan_content

"
  fi

  # Include project directory so the reviewer knows where files live
  if [ -n "$project_dir" ]; then
    prompt="${prompt}PROJECT DIRECTORY: $project_dir
All project files are under this directory. Use absolute paths for all file operations.

"
  fi

  # Task type
  local task_type="Leaf implementation"
  if [ "$is_parent" = "true" ]; then
    task_type="Parent integration"
  fi

  prompt="${prompt}TASK BEING REVIEWED:
- ID: $task_id
- Description: $task_desc
- Criteria: $task_criteria
- Type: $task_type"

  # For parent tasks: include children descriptions and their files
  if [ "$is_parent" = "true" ] && [ -n "$children_json" ] && [ "$children_json" != "[]" ]; then
    local children_details=""
    for child_id in $(echo "$children_json" | jq -r '.[]' 2>/dev/null); do
      local child_desc=$(echo "$tree_json" | jq -r --arg id "$child_id" '.tasks[$id].description // "No description"')
      children_details="${children_details}
  - $child_id: $child_desc"
    done
    prompt="${prompt}
- Children:${children_details}"
  fi

  # Modified files
  local files_list=""
  if [ -n "$modified_files_json" ] && [ "$modified_files_json" != "[]" ] && [ "$modified_files_json" != "null" ]; then
    files_list=$(echo "$modified_files_json" | jq -r '.[]' 2>/dev/null | sed 's/^/  - /')
  fi

  if [ -n "$files_list" ]; then
    prompt="${prompt}

FILES MODIFIED DURING THIS TASK:
$files_list"
  else
    prompt="${prompt}

FILES MODIFIED DURING THIS TASK:
  No specific files tracked — review based on task description and criteria."
  fi

  prompt="${prompt}

REVIEW INSTRUCTIONS:
Review the code for this task with fresh eyes, as if it were written by someone else. Check for gaps, bugs, cleanup needed, or other improvements to arrive at simple and robust code that works well for real-world users. There may be many changes needed (completely ok), or none (also completely ok).

If you identify issues, double check your evaluation, then proceed with fixes directly. Fix anything you find — leave the code better than you found it. Said another way, anything that cleans up the code even slightly is worth it, even if it’s extra work (as long as it doesn’t add unnecessary complexity).

Evaluate from multiple perspectives: edge cases, race conditions, error handling, correctness. Hold yourself to a high standard.

Watch out for cases where you find a surface-level problem and identify an immediate surface-level fix that you know would add friction and tradeoffs in other places. That's almost always a sign that there's a deeper, root-cause issue, that can be mutually-reinforcing to the code if it's found and addressed.

IMPORTANT — when you are done reviewing and fixing, output a summary line in EXACTLY this format as your very last line:
REVIEW_RESULT: {\"issues\": N, \"fixes\": N, \"summary\": \"one sentence\"}
where N is a number. This line must be the last line of your response."

  echo "$prompt"
}

# DEPRECATED: This function was used by the old claude -p subprocess approach.
# The recursive-dev review phase now uses Task tool subagents instead.
# Kept for reference — contains retry logic and output parsing patterns.
#
# Run a review phase review using claude -p with full tool access
# Usage: run_review "prompt" ["cwd"]
# Returns: JSON result with reviewed, issuesFound, fixesApplied, summary
#
# Design: The review's VALUE is the model reading code and fixing bugs (via tool use).
# The structured output is just reporting. If claude -p runs and produces output,
# the review succeeded — even if we can't parse a summary line.
run_review() {
  local prompt="$1"
  local cwd="${2:-}"
  local debug_log="/tmp/recursive-dev-review-debug.log"

  # Run review using claude -p with prompt piped via printf.
  # - Here-strings (<<<) do NOT work with claude -p (it silently rejects them)
  # - Positional args conflict with --allowedTools variadic parser
  # - Pipe via printf is the reliable delivery method
  # - --allowedTools grants Edit/Write/Read/Bash/Grep/Glob so the reviewer can fix code
  # - cd to project directory so file operations resolve correctly
  #
  # Retry strategy for 0-byte responses (API queuing / cold start):
  #   Attempt 1: 150s timeout
  #   Attempt 2: 80s timeout (after 5s pause)
  #   Total worst case: 150 + 5 + 80 = 235s, leaving 65s of 300s hook budget
  local review_raw=""
  local exit_code=0
  local attempt=0
  local max_attempts=2
  local timeouts=(150 80)

  while [ $attempt -lt $max_attempts ]; do
    local t=${timeouts[$attempt]}

    if [ -n "$cwd" ] && [ -d "$cwd" ]; then
      review_raw=$(cd "$cwd" && printf '%s' "$prompt" | timeout "$t" claude --allowedTools "Edit,Write,Read,Bash,Grep,Glob" -p 2>>"$debug_log")
    else
      review_raw=$(printf '%s' "$prompt" | timeout "$t" claude --allowedTools "Edit,Write,Read,Bash,Grep,Glob" -p 2>>"$debug_log")
    fi
    exit_code=$?

    # Log each attempt
    {
      echo "=== run_review() $(date -u '+%Y-%m-%dT%H:%M:%SZ') attempt=$((attempt+1))/$max_attempts ==="
      echo "exit_code: $exit_code"
      echo "timeout: ${t}s"
      echo "raw_output_length: ${#review_raw}"
      echo "raw_output_last_500:"
      echo "${review_raw: -500}"
      echo "=== end ==="
    } >> "$debug_log" 2>/dev/null

    # If we got any output, use it (even partial from timeout)
    if [ -n "$review_raw" ]; then
      break
    fi

    attempt=$((attempt + 1))
    if [ $attempt -lt $max_attempts ]; then
      { echo "--- retrying after 0-byte response (pause 5s) ---"; } >> "$debug_log" 2>/dev/null
      sleep 5
    fi
  done

  # Handle total failure (no output after all attempts)
  if [ -z "$review_raw" ]; then
    jq -n \
      --arg summary "Review command failed after $max_attempts attempts (last exit $exit_code, no output) — see $debug_log" \
      '{reviewed: false, issuesFound: 0, fixesApplied: 0, summary: $summary}'
    return 0
  fi

  # Try to extract the REVIEW_RESULT summary line.
  local result_line
  result_line=$(echo "$review_raw" | grep 'REVIEW_RESULT:' | tail -1)

  local num_issues=0
  local num_fixes=0
  local summary=""
  local reviewed=true

  if [ -n "$result_line" ]; then
    # Found REVIEW_RESULT — parse the JSON after the marker
    local result_json="${result_line#*REVIEW_RESULT:}"
    result_json=$(echo "$result_json" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') # trim whitespace

    num_issues=$(echo "$result_json" | jq -r '.issues // 0' 2>/dev/null || echo 0)
    num_fixes=$(echo "$result_json" | jq -r '.fixes // 0' 2>/dev/null || echo 0)
    summary=$(echo "$result_json" | jq -r '.summary // ""' 2>/dev/null || echo "")
  else
    # No REVIEW_RESULT line found. Distinguish "review ran but couldn't parse"
    # from "review failed entirely" (usage limit, bad args, etc.).
    #
    # Heuristic:
    #   exit 0           → review ran, just no summary line (reviewed: true)
    #   exit 124 + >200B → timeout but review ran (model produced substantial output)
    #   exit 124 + <200B → timeout with minimal output (review didn't really run)
    #   exit 1 (or other)→ error: usage limit, bad args, etc. (reviewed: false)
    if [ $exit_code -eq 0 ]; then
      reviewed=true
    elif [ $exit_code -eq 124 ] && [ ${#review_raw} -ge 200 ]; then
      reviewed=true
    else
      reviewed=false
    fi
  fi

  # Build summary from raw output if we don't have one yet
  if [ -z "$summary" ]; then
    summary=$(echo "$review_raw" | grep -v '^$' | tail -1 | head -c 200)
    [ -z "$summary" ] && summary="Review completed (could not parse summary line)"
  fi

  jq -n \
    --argjson reviewed "$reviewed" \
    --argjson issues "$num_issues" \
    --argjson fixes "$num_fixes" \
    --arg summary "$summary" \
    '{reviewed: $reviewed, issuesFound: $issues, fixesApplied: $fixes, summary: $summary}'
}

# Escape text for JSON
# Usage: json_escape "text"
json_escape() {
  local text="$1"
  echo "$text" | jq -Rs . | sed 's/^"//;s/"$//'
}

# Build hook response JSON using documented Stop hook format
# Usage: hook_response block|allow ["reason"]
#   block = prevent stop, inject reason as model context, model gets another turn
#   allow = permit stop (reason shown to user but session ends)
# Legacy: "false" maps to "block", "true" maps to "allow" for backward compat
hook_response() {
  local action="$1"
  local reason="${2:-}"

  # Map legacy true/false to block/allow
  local should_block=false
  case "$action" in
    block|false) should_block=true ;;
    allow|true|*) should_block=false ;;
  esac

  if [ "$should_block" = "true" ]; then
    if [ -n "$reason" ]; then
      local escaped=$(json_escape "$reason")
      echo "{\"decision\": \"block\", \"reason\": \"$escaped\"}"
    else
      echo "{\"decision\": \"block\"}"
    fi
  else
    # Allow stop — omit decision field
    if [ -n "$reason" ]; then
      local escaped=$(json_escape "$reason")
      echo "{\"reason\": \"$escaped\"}"
    else
      echo "{}"
    fi
  fi
}
