---
name: recursive-dev
description: Recursive development system that enforces depth-first, branch-complete execution with verification at every level. Integrates tree-planner, code-path-diagrammer, and review-loop.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task, TaskCreate, TaskUpdate, TaskList, Skill
---

# Recursive Development Skill

A recursive development system that orchestrates complex multi-task projects with:
- **Hierarchical task breakdown** via tree-planner (with criteria at ALL levels)
- **Implementation planning** via code-path-diagrammer (before each task)
- **Verification at every level** via review-loop logic (leaves AND parents)
- **Depth-first, branch-complete execution** enforced by hooks and state

## Commands

```
/recursive-dev start              # Start from existing tree in plan file
/recursive-dev status             # Show current task, progress
/recursive-dev review             # Manually trigger review phase (marks all tasks completed)
/recursive-dev review-status      # Show review phase progress
/recursive-dev skip               # Skip current task (warns about parent impact)
/recursive-dev reopen T1.1        # Reopen a completed task for fixes
/recursive-dev stop               # End the session
```

## Session Environment

Each session has state files in `~/.claude/recursive-dev/<session-id>/`.

**Session identification:** The stop hook identifies active recursive-dev sessions by:
1. Checking if a `/recursive-dev` command appears in any USER message in this conversation
2. Verifying there's an active session (has `currentTask`, `currentDesignTask`, or `currentReviewTask`) for the current project directory

This ensures the hook ONLY activates when the user explicitly invoked `/recursive-dev` — it won't trigger from hook injections, system messages, or other automated prompts.

## Workflow Overview

### Phase 1: Planning (Prerequisites)

Before starting recursive-dev:
1. Enter plan mode
2. Run `/tree-planner` to break down the project
3. **Ensure criteria are captured for ALL levels** (leaves AND parents)
4. Exit plan mode with the tree in your plan file

### Phase 2: Start the Session

When `/recursive-dev start` is invoked:

1. **Parse tree from plan file**
   - Read the plan file (user provides path or we detect it)
   - Extract the task hierarchy with all criteria
   - Build internal tree structure

2. **Generate tree.json**
   - Store structured data in `~/.claude/recursive-dev/<session-id>/tree.json`
   - Calculate execution order (depth-first, branch-complete)

3. **Create Tasks for visibility**
   - Use TaskCreate for each task in the tree
   - This provides UI visibility into progress

4. **Initialize state**
   - Create `~/.claude/recursive-dev/<session-id>/state.json`
   - Set current task to first leaf in execution order

5. **Set environment variable**
   - Export `CLAUDE_RECURSIVE_DEV_SESSION=<session-id>`

6. **Begin first task**
   - Invoke code-path-diagrammer for implementation planning
   - Present the task to work on

### Phase 3: Development Loop

For each task (leaves AND parents get identical treatment):

```
┌─────────────────────────────────────────────────────┐
│ 1. code-path-diagrammer plans the task              │
│    - For leaves: plan implementation                │
│    - For parents: visualize integration of children │
└─────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────┐
│ 2. Work on the task                                 │
│    - TaskUpdate(status=in_progress)                 │
│    - Write code, tests, documentation               │
│    - For parents: integrate children as units       │
└─────────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────┐
│ 3. Stop hook fires → verification                   │
│    - Reviews against task's criteria                │
│    - Same process for ALL tasks at ALL levels       │
└─────────────────────────────────────────────────────┘
                    │
          ┌────────┴────────┐
          ▼                 ▼
     ┌─────────┐      ┌──────────┐
     │  PASS   │      │   FAIL   │
     └────┬────┘      └────┬─────┘
          │                │
          ▼                ▼
    Task → atomic    code-path-diagrammer
    Advance to         diagnoses issues
    next task        Continue working
```

### Execution Order

For a tree like:
```
T1
├── T1.1
│   ├── T1.1.1
│   └── T1.1.2
└── T1.2
    ├── T1.2.1
    └── T1.2.2
T2
└── T2.1
```

Order is depth-first, branch-complete:
1. T1.1.1, T1.1.2 → review T1.1
2. T1.2.1, T1.2.2 → review T1.2
3. Review T1 (children now atomic)
4. T2.1 → review T2
5. Final root review

### Phase 4: Automatic Design Documentation

After all dev tasks pass verification, the system **automatically** transitions to a design-documentation phase. This requires no user action — the stop hook handles the transition.

The design-documentation phase examines the code as it was built and adds structured `@design` annotations documenting the architecture, patterns, and key structural choices that emerged. This is the backward-looking counterpart to structured-planning — documenting what actually got built.

```
Dev Loop Completes (all tasks verified)
                │
                ▼
┌─────────────────────────────────────────────────────┐
│ Hook sets phase: "design-documentation"              │
│ For each task in depth-first order:                  │
│ 1. Hook injects design instruction to main session   │
│ 2. Main session spawns design subagent via Task tool │
│    - Subagent has fresh context (no dev transcript)  │
│    - Subagent reads code, adds @design annotations   │
│ 3. Main session outputs DESIGN_RESULT line           │
│ 4. Hook parses, records, advances to next task       │
│ 5. After all tasks: run design-extract.sh            │
│    → generates DESIGN.md from inline annotations     │
└─────────────────────────────────────────────────────┘
                │
                ▼
```

### Phase 5: Automatic Review Phase

After design documentation completes, the system **automatically** transitions to a review phase. Reviewers benefit from the `@design` annotations already present in the code.

```
Design Documentation Complete (DESIGN.md generated)
                │
                ▼
┌─────────────────────────────────────────────────────┐
│ Hook sets phase: "review"                            │
│ Injects: "Starting review..."                        │
│ Main session cycles → hook fires automatically      │
└─────────────────────────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────────────┐
│ Review Loop (subagent approach)                      │
│                                                     │
│ For each task in depth-first, branch-complete order: │
│ 1. Hook injects review instruction to main session   │
│    - Task description, criteria, modified files      │
│    - Instruction to use Task tool for review         │
│ 2. Main session spawns review subagent via Task tool │
│    - Subagent has fresh context (no dev transcript)  │
│    - Subagent reviews code and applies fixes         │
│ 3. Main session outputs REVIEW_RESULT line           │
│    - Format: REVIEW_RESULT: {"task":..., "issues":N} │
│ 4. Main session stops → hook fires again             │
│ 5. Hook parses REVIEW_RESULT, records, advances      │
│ 6. Repeat for next task                              │
└─────────────────────────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────────────┐
│ Holistic Review (after all per-task reviews)        │
│                                                     │
│ 1. Hook detects all per-task reviews complete       │
│ 2. Hook injects holistic review instruction         │
│    - All modified files across all tasks            │
│    - Per-task review summary                        │
│    - "Fresh eyes" review of everything together     │
│ 3. Subagent reviews entire codebase holistically    │
│    - How pieces fit together                        │
│    - Consistency across components                  │
│    - Integration issues                             │
└─────────────────────────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────────────┐
│ Validation Review (after holistic review)           │
│                                                     │
│ Confirms work is solid before moving to next phase: │
│ 1. Test coverage — do we have all needed tests?     │
│ 2. Edge cases — are there uncovered scenarios?      │
│ 3. Error handling — what happens when things fail?  │
│ 4. Integration points — will this connect properly? │
│ 5. Assumptions — what needs to be validated?        │
└─────────────────────────────────────────────────────┘
                │
                ▼
        All reviews complete → final summary
```

Key points:
- The reviewer has **fresh eyes** — Task subagent has no dev context
- The reviewer has **full tool access** and applies fixes autonomously
- Uses Claude Code's native Task infrastructure (no `claude -p` subprocesses)
- Hook orchestrates, model does the work via Task tool
- Main session outputs `REVIEW_RESULT: {...}` which hook parses
- Modified files are tracked during dev and passed to the reviewer
- The "recursive-dev stop" escape hatch works during review

**Review approach ("Trace Outward"):**
The reviewer doesn't just check if modified files work in isolation — it verifies they integrate correctly with the broader codebase:
1. **Read** modified files, identify assumptions (field accesses, types, patterns)
2. **Trace outward** — read imports, search for related patterns, check consumers
3. **Verify consistency** — do field accesses match schemas? Are patterns consistent?
4. **Fix issues** in modified files AND related files (systemic issues fixed everywhere)
5. **Verify acceptance criteria** are met

This catches issues that only become visible when you see how the code fits into the larger system (e.g., using `entity.name` when the schema has `userId`).

### Parent Task "Work"

When a parent task becomes current (after all children pass):
- The "work" is integration: ensuring children work together
- May involve writing integration code, tests, or just verification
- The parent's criteria define what needs to be true
- code-path-diagrammer shows how children connect

## State Files

### tree.json
```json
{
  "root": "Project description",
  "planFile": "/path/to/plan.md",
  "tasks": {
    "T1": {
      "id": "T1",
      "description": "User endpoints",
      "criteria": "All user CRUD operations work",
      "parent": null,
      "children": ["T1.1", "T1.2"],
      "taskToolId": "uuid-from-TaskCreate"
    }
  },
  "order": ["T1.1", "T1.2", "T1", "T2.1", "T2"]
}
```

### state.json
```json
{
  "sessionId": "abc123",
  "currentTask": "T1.1",
  "phase": "dev",
  "taskStatuses": {
    "T1.1": "in_progress",
    "T1.2": "pending",
    "T1": "blocked"
  },
  "iterations": {
    "T1.1": 2
  },
  "maxIterations": 5,
  "history": [
    {"task": "T1.1", "result": "fail", "iteration": 1, "issues": ["..."]}
  ],
  "modifiedFiles": {
    "T1.1": ["src/users.ts", "src/users.test.ts"]
  }
}
```

During design-documentation phase, additional fields are present:
```json
{
  "phase": "design-documentation",
  "currentDesignTask": "T1.1",
  "designStatuses": {
    "T1.1": "documented",
    "T1.2": "in_progress",
    "T1": "pending_design"
  },
  "designHistory": [
    {
      "task": "T1.1",
      "annotations": 3,
      "files": ["src/users.ts"],
      "summary": "Documented REST endpoint design, pagination strategy, auth middleware"
    }
  ]
}
```

**Design status values:**
- `pending_design` - Not yet analyzed
- `in_progress` - Currently being analyzed
- `documented` - Annotations added

During review phase, additional fields are present:
```json
{
  "phase": "review",
  "currentReviewTask": "T1.1",
  "reviewStatuses": {
    "T1.1": "reviewed",
    "T1.2": "in_review",
    "T1": "pending_review"
  },
  "reviewHistory": [
    {
      "task": "T1.1",
      "issuesFound": ["off-by-one in pagination"],
      "fixesApplied": ["fixed pagination offset"],
      "filesModified": ["src/users.ts"],
      "testsPassAfter": true,
      "summary": "Fixed 1 issue, all tests pass"
    }
  ]
}
```

**Status values:**
- `pending` - Not yet started
- `in_progress` - Currently being worked on
- `completed` - Passed verification (atomic)
- `blocked` - Waiting on children or reopened for fixes
- `failed` - Hit max iterations, session stopped

**Review status values:**
- `pending_review` - Not yet reviewed
- `in_review` - Currently being reviewed
- `reviewed` - Review complete

## Failure Handling

When a task fails max iterations:
1. Session STOPS (not skipped)
2. User must intervene
3. Options: fix and retry, skip (warns about parent), or abort

## Backtracking

If a parent fails because children don't integrate:
1. User runs `/recursive-dev reopen T1.1`
2. T1.1 goes back to `in_progress`
3. Parent T1 becomes `blocked`
4. Continue from reopened task
5. When T1.1 passes again, T1 becomes current

## Escape Hatch

Say "recursive-dev done" or "recursive-dev stop" to end the session at any time.
Or use `/recursive-dev stop` command.

## Command Implementations

### /recursive-dev start

```bash
# Parse arguments
PLAN_FILE="$ARGUMENTS"  # Optional: path to plan file

# If no plan file specified, try to find it
if [ -z "$PLAN_FILE" ]; then
  # Check plan mode context or ask user
fi
```

**Actions:**
1. Load tree structure from one of these sources (in priority order):
   - `~/.claude/recursive-dev/tree-export.json` if it exists (created by `/tree-planner export json`)
   - Otherwise, parse the markdown tree from the plan file using `lib/tree-parser.sh`
2. Verify the tree has `projectDir` set (should be current working directory)
3. Generate session ID: `date +%s | shasum | head -c8`
4. Create `~/.claude/recursive-dev/<session-id>/`
5. Copy/write tree.json and state.json to session directory
6. Create Tasks via TaskCreate
7. Invoke code-path-diagrammer for first task
8. Present task to user

### /recursive-dev status

Show:
- Current phase (dev, design-documentation, or review)
- Current task ID, description, criteria
- Progress: X/Y tasks complete
- Iteration count for current task
- Recent history (last 3 results)

### /recursive-dev review-status

Show review phase progress:
- Current review task
- Review progress: X/Y tasks reviewed
- Per-task review results (issues found, fixes applied, test status)
- Total issues/fixes across all reviewed tasks

### /recursive-dev review

Manually trigger the review phase. Use this when:
- Dev work completed but the hook didn't track it (e.g., session was continued after context loss)
- You want to re-run the review phase on an already-completed session

**CRITICAL: This command ONLY initializes state. You MUST NOT do any review work yourself.**

The entire value of the review phase is that it uses **fresh Task subagents** with no dev context — fresh eyes on the code. The main session has full dev context and MUST NOT review files, run tests, read project code, or write review results. The stop hook handles ALL of that autonomously.

**Actions:**

Use the helper script to initialize the review phase (this ensures correct JSON construction):

```bash
# Step 1: Find session for current project
SESSION_ID=$(~/.claude/hooks/lib/recursive-dev-helpers.sh find-session "$(pwd)")

# Step 2: Check if session found
if [ -z "$SESSION_ID" ]; then
  echo "No session found for this project"
  # Ask user for session ID or check ~/.claude/recursive-dev/ manually
fi

# Step 3: Check current status
~/.claude/hooks/lib/recursive-dev-helpers.sh status "$SESSION_ID"

# Step 4: Initialize review phase (if not already in review)
~/.claude/hooks/lib/recursive-dev-helpers.sh init-review "$SESSION_ID"
```

The `init-review` command:
- Marks all tasks as completed
- Sets phase to "review"
- Sets currentReviewTask to first task in order
- Initializes reviewStatuses and reviewHistory
- Preserves modifiedFiles if present
- Validates JSON before writing
- **Returns `reviewInstruction` with first task details**

After running the helper, **IMMEDIATELY spawn the first review subagent** using the returned `reviewInstruction`:

```
# Parse the result
RESULT=$(~/.claude/hooks/lib/recursive-dev-helpers.sh init-review "$SESSION_ID")
FIRST_TASK=$(echo "$RESULT" | jq -r '.firstTask')
TASK_DESC=$(echo "$RESULT" | jq -r '.reviewInstruction.description')
TASK_CRITERIA=$(echo "$RESULT" | jq -r '.reviewInstruction.criteria')
PROJECT_DIR=$(echo "$RESULT" | jq -r '.reviewInstruction.projectDir')
TASK_FILES=$(echo "$RESULT" | jq -r '.reviewInstruction.modifiedFiles')
```

Then tell the user: "Review phase initialized for session $SESSION_ID. Starting first review..."

Then IMMEDIATELY spawn the review Task:

```
Task(
  subagent_type: "general-purpose",
  description: "Review task $FIRST_TASK",
  prompt: "You are reviewing code for a development task. Review with fresh eyes — you have no context about how it was implemented.

TASK: $FIRST_TASK
DESCRIPTION: $TASK_DESC
ACCEPTANCE CRITERIA: $TASK_CRITERIA
PROJECT DIRECTORY: $PROJECT_DIR
FILES MODIFIED: $TASK_FILES

[Include full review instructions from the stop hook template]"
)
```

After the Task completes, output EXACTLY:
```
REVIEW_RESULT: {"task": "$FIRST_TASK", "issues": <number>, "fixes": <number>, "summary": "<brief summary>"}
```

Then STOP. The hook will record the result and inject the next review instruction.

**If already in review phase**, use `next-step` to determine what to do:

```bash
# Check what the next step should be
~/.claude/hooks/lib/recursive-dev-helpers.sh next-step "$SESSION_ID"
```

This returns one of:
- `{"nextStep": "continue_per_task", "currentTask": "T1.1"}` - A per-task review is in progress, just stop and let the hook continue
- `{"nextStep": "per_task_review", "nextTask": "T1.2"}` - Set the next task and let hook continue
- `{"nextStep": "holistic_review"}` - All per-task reviews done, need holistic review
- `{"nextStep": "validation_review"}` - Holistic done, need validation review
- `{"nextStep": "complete"}` - All reviews done

**For each case:**

1. **continue_per_task**: Tell user "Review in progress at [task]. The stop hook will continue automatically." Then STOP.

2. **per_task_review**: Run `set-task` to set the next task, then STOP:
   ```bash
   ~/.claude/hooks/lib/recursive-dev-helpers.sh set-task "$SESSION_ID" "<nextTask>"
   ```

3. **holistic_review**: Run `set-task` with "HOLISTIC", then STOP:
   ```bash
   ~/.claude/hooks/lib/recursive-dev-helpers.sh set-task "$SESSION_ID" "HOLISTIC"
   ```
   Tell user: "Per-task reviews complete. Starting holistic review."

4. **validation_review**: Run `set-task` with "VALIDATION", then STOP:
   ```bash
   ~/.claude/hooks/lib/recursive-dev-helpers.sh set-task "$SESSION_ID" "VALIDATION"
   ```
   Tell user: "Holistic review complete. Starting validation review."

5. **complete**: Tell user "All reviews complete!" and summarize the review history.

**CRITICAL: After setting up the next step, STOP. Do not do the review work yourself.** The stop hook will inject instructions for spawning Task subagents with fresh context.

### /recursive-dev skip

1. Warn user that skipping may cause parent to fail
2. If confirmed, mark current task as `completed` (with note: skipped)
3. Advance to next task

### /recursive-dev reopen T1.1

1. Find task T1.1
2. Change status from `completed` to `in_progress`
3. Change any ancestor's status to `blocked`
4. Set currentTask to T1.1
5. Resume development loop

### /recursive-dev stop

1. Clean up state files (optional: keep for debugging)
2. Summarize what was completed

Note: The session marker in the transcript naturally becomes inactive when the conversation ends or when the session files are removed.

## Tree Parsing

Parse the markdown tree from the plan file into JSON structure.

Expected format (from tree-planner):
```markdown
## Task Hierarchy

- T1 [STATUS] Description | verify: criteria
  - T1.1 [STATUS] Subtask | verify: leaf criteria
  - T1.2 [STATUS] Subtask | verify: leaf criteria
- T2 [STATUS] Description | verify: criteria
```

Parsing rules:
1. Lines starting with `-` at various indentation levels define tasks
2. Task ID is first word (e.g., T1, T1.1)
3. Status in brackets: [PENDING], [IN PROGRESS], [DONE]
4. Description follows status
5. Criteria after `| verify:` separator
6. Indentation (2 spaces) indicates parent-child relationships

## Integration with code-path-diagrammer

The hook invokes code-path-diagrammer via `claude -p` with the agent instructions:

```bash
# Read agent instructions
AGENT_MD=$(cat ~/.claude/agents/code-path-diagrammer.md)

# Build prompt
PROMPT="$AGENT_MD

---

Task: $TASK_DESCRIPTION
Criteria: $TASK_CRITERIA
Type: $([ has_children ] && echo 'Integration' || echo 'Leaf implementation')
Context: [relevant code context]

Create before/after diagrams and identify files to modify."

# Run
claude -p "$PROMPT"
```

This happens:
- When a task becomes current (before work)
- On verification failure (to diagnose issues)

## Notes

- The stop hook handles all verification logic (dev AND review phases)
- Tasks become "atomic" building blocks when they pass
- Parent reviews treat children as black boxes that work
- After all dev tasks pass, the review phase starts automatically
- The review phase uses fresh Task subagents with no dev context
- Modified files are tracked during dev and provided to reviewers
- Session identification checks USER messages for `/recursive-dev` commands, then matches by project directory — this ensures the hook only activates when the user explicitly invoked the command
- Use `/recursive-dev review` to manually trigger review if automatic transition was missed
- Multiple concurrent sessions supported (different session IDs, different project directories)
- The "recursive-dev stop" escape hatch works in both dev and review phases
