---
name: review-loop
description: Enables automatic self-review after completing work. Claude will verify its work against criteria and continue iterating until verification passes or max iterations reached.
allowed-tools: Bash, Read, Write
---

# Review Loop - Self-Verifying Task Mode

## What I do

When activated, I enable a review loop that automatically verifies your work after you believe a task is complete. After each attempt, a separate review process evaluates the work against the specified criteria. If issues are found, you'll receive feedback and continue working.

## Commands

### Start a review loop
```
/review-loop [criteria]
```

**Arguments:**
- `criteria` (optional): Specific verification criteria. If not provided, the original task will be used.

**Options (include in criteria text):**
- `--max-iterations N`: Maximum review cycles (default: 5)
- `--autonomous`: Don't pause for input at max iterations; just stop
- `--checkpoint`: Pause after every review cycle for user confirmation
- `--test-command "cmd"`: Run this command as part of verification

### Stop the review loop
```
/review-loop stop
```

### Check status
```
/review-loop status
```

## Examples

### Basic usage
```
/review-loop All tests pass and no lint errors
```
Activates review loop with default settings (5 max iterations, pauses for input if stuck).

### With test command
```
/review-loop --test-command "npm test" All tests pass
```
Runs `npm test` as part of each verification cycle. Test output is included in the review.

### Limited iterations
```
/review-loop --max-iterations 3 API endpoints return correct status codes
```
Stops after 3 review cycles if criteria aren't met.

### Autonomous mode (for CI/background tasks)
```
/review-loop --autonomous --max-iterations 10 Complete the refactor without breaking existing tests
```
Won't pause for user input at max iterations - just stops with a report.

### Checkpoint mode (review each cycle with user)
```
/review-loop --checkpoint Each component has proper error handling
```
Pauses after every review cycle for user confirmation before continuing.

### Combined options
```
/review-loop --test-command "pytest -v" --max-iterations 5 All tests pass and coverage > 80%
```

### Control commands
```
/review-loop status   # Check if a loop is active and see iteration count
/review-loop stop     # Deactivate the loop manually
done                  # Say this anytime to exit even if issues remain
```

## How it works

1. You activate the review loop with criteria
2. Work on the task normally
3. When you finish responding, a Stop hook triggers
4. The hook invokes a separate Claude instance to review your work
5. If issues found → you receive feedback and continue
6. If all criteria met → loop ends successfully
7. At max iterations → pauses for user guidance (or stops if `--autonomous`)

## Escape hatch

Say "done", "stop", or "exit" at any time to end the review loop even if issues remain.

---

## Instructions for Claude

When the user invokes `/review-loop`, execute these steps:

### For `/review-loop stop`:
```bash
rm -f ~/.claude/review-loop/task.json ~/.claude/review-loop/state.json
```
Then confirm: "Review loop deactivated."

### For `/review-loop status`:
```bash
cat ~/.claude/review-loop/task.json 2>/dev/null && cat ~/.claude/review-loop/state.json 2>/dev/null
```
Report whether a review loop is active and its current state.

### For `/review-loop [criteria]`:

1. Parse the criteria text for options:
   - `--max-iterations N` → extract N (default: 5)
   - `--autonomous` → set autonomous=true (default: false)
   - `--checkpoint` → set checkpointEachCycle=true (default: false)
   - `--test-command "cmd"` → extract cmd (default: empty)
   - Remaining text is the criteria

2. Write the task config:
```bash
cat > ~/.claude/review-loop/task.json << 'EOF'
{
  "criteria": "<CRITERIA_TEXT>",
  "maxIterations": <N>,
  "autonomous": <true|false>,
  "checkpointEachCycle": <true|false>,
  "testCommand": "<CMD_OR_EMPTY>"
}
EOF
```

3. Initialize the state:
```bash
cat > ~/.claude/review-loop/state.json << 'EOF'
{
  "iteration": 0,
  "history": []
}
EOF
```

4. Confirm activation:
   "Review loop activated. I'll automatically verify my work against: **<criteria>**

   Settings: max iterations = <N>, autonomous = <true|false>

   Say 'done' at any time to exit the loop."

Then proceed to work on whatever task the user gives you next.
