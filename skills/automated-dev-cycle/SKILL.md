---
name: automated-dev-cycle
description: Orchestrates the full automated development cycle - tree planning, export, and recursive development with reviews.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task, TaskCreate, TaskUpdate, TaskList, Skill, AskUserQuestion
---

# Automated Development Cycle

A meta-skill that orchestrates the complete automated development workflow:

1. **Structured Planning** — Systematically define outcomes, constraints, verification, edge cases
2. **Tree Planning** — Break down each phase into hierarchical tasks (auto-generated from spec)
3. **Export** — Export the tree structure to JSON
4. **Recursive Development** — Execute tasks with verification at every level
5. **Design Documentation** — Document the as-built design via inline `@design` annotations
6. **Review Phase** — Per-task reviews, holistic review, and validation review

## Workflow Overview

```
┌─────────────────────────────────────────────────────────────┐
│ /automated-dev-cycle (full workflow)                        │
│                                                             │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Step 0: Structured Planning (INTERACTIVE)               │ │
│ │                                                         │ │
│ │ Systematically define for EACH phase:                   │ │
│ │ • User outcomes (what can users DO?)                    │ │
│ │ • Hard constraints (what MUST be true?)                 │ │
│ │ • Verification criteria (how do we KNOW it works?)      │ │
│ │ • Edge cases (what happens when things go wrong?)       │ │
│ │ • Hidden assumptions (what are we assuming?)            │ │
│ │ • Acceptance criteria (pass/fail for each feature)      │ │
│ └─────────────────────────────────────────────────────────┘ │
│                              │                              │
│                              ▼                              │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Steps 1-N: Per-Phase Development (AUTOMATIC)            │ │
│ │                                                         │ │
│ │ For each phase (runs automatically):                    │ │
│ │ 1. Tree-planner auto-generates tasks from spec          │ │
│ │ 2. Export to JSON                                       │ │
│ │ 3. Recursive-dev executes with verification             │ │
│ │ 4. Design documentation (@design annotations)          │ │
│ │ 5. Review phase (per-task, holistic, validation)        │ │
│ │ 6. Advance to next phase                                │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Usage

```
/automated-dev-cycle              # Start the full cycle (structured planning → phases)
/automated-dev-cycle resume       # Resume from current state
/automated-dev-cycle status       # Show current phase and progress
/automated-dev-cycle skip-phase   # Skip current phase, advance to next
/automated-dev-cycle restart-phase N  # Restart from phase N
```

## Command Implementations

### /automated-dev-cycle (or /automated-dev-cycle start)

Start the full automated development cycle.

**Actions:**

1. **Check for existing project state**
   ```bash
   # Check if there's existing multi-phase state for this project
   HAS_STATE=$(~/.claude/hooks/lib/project-phases.sh exists "$(pwd)")
   ```

   If state exists, ask user:
   - "Resume from current phase?"
   - "Start fresh (delete existing progress)?"

2. **Check for phase markers in plan file**
   ```bash
   # Check if plan file has phase markers
   HAS_MARKERS=$(~/.claude/hooks/lib/phase-parser.sh has-markers "<plan_file>")
   ```

3. **Structured Planning Phase** (if no markers)

   If no phase markers exist in the plan file:
   - Tell the user: "Starting structured planning to define your project specification."
   - Invoke: `Skill(skill: "structured-planning")`
   - The structured-planning skill will:
     - Ask about the project
     - Guide through each phase's 6 sections
     - Export with phase markers when complete

   **CRITICAL:** After structured-planning completes and exports, you MUST immediately continue to step 4. Do NOT call ExitPlanMode or wait for user approval. The structured spec is complete — now proceed to initialize state and start the first phase automatically.

4. **Initialize Multi-Phase State**
   ```bash
   # Parse phases and create project state
   ~/.claude/hooks/lib/project-phases.sh init "$(pwd)" "<plan_file>"
   ```

5. **Start First Phase**

   Begin the per-phase development loop (see Phase Development Loop below).

### Phase Development Loop

For each phase, the following happens automatically:

**Step 1: Extract Phase Content**
```bash
# Get current phase info
PHASE_INFO=$(~/.claude/hooks/lib/project-phases.sh current "$(pwd)")
PHASE_NUM=$(echo "$PHASE_INFO" | jq -r '.number')
PHASE_TITLE=$(echo "$PHASE_INFO" | jq -r '.title')

# Get phase content from plan file
PHASE_CONTENT=$(~/.claude/hooks/lib/phase-parser.sh content "<plan_file>" "$PHASE_NUM")
```

**Step 2: Tree Planning (Auto Mode)**

Tell user: "Phase $PHASE_NUM: $PHASE_TITLE — Generating task tree..."

The tree-planner runs in **auto mode** — no user interaction:
- Invoke: `Skill(skill: "tree-planner", args: "auto")`
- Tree-planner reads the structured spec from the plan file
- Generates task tree automatically based on User Outcomes and Verification Criteria
- Exports to JSON automatically

**Step 3: Recursive Development**

Tell user: "Task tree generated. Starting recursive development..."

- Invoke: `Skill(skill: "recursive-dev", args: "start")`
- Recursive-dev executes all tasks with verification
- Review phase runs automatically (per-task, holistic, validation)

**Step 4: Phase Completion**

When recursive-dev completes its review phase (state.json shows `phase: "complete"`):
- The recursive-dev stop hook will output a completion message
- Tell user: "Phase $N complete!"

**Step 5: Automatic Phase Transition**

Within an active `/automated-dev-cycle` session, phase transitions happen automatically:
1. Mark the completed phase in project-phases state
2. Immediately start the next phase (return to Step 1 for new phase)

**Note:** The `/automated-dev-cycle resume` command is ONLY for resuming after session interruption (e.g., context loss, terminal closed, session timeout). Within a continuous session, you should automatically proceed through all phases without waiting for user input.

**When checking for next phase:**
```bash
# Check if recursive-dev review is truly complete
SESSION_ID=$(~/.claude/hooks/lib/recursive-dev-helpers.sh find-session "$(pwd)")
NEXT_STEP=$(~/.claude/hooks/lib/recursive-dev-helpers.sh next-step "$SESSION_ID")
STEP=$(echo "$NEXT_STEP" | jq -r '.nextStep')

if [ "$STEP" = "complete" ]; then
  # Mark session as complete if not already (validates reviews done)
  ~/.claude/hooks/lib/recursive-dev-helpers.sh complete-session "$SESSION_ID"
  # Now advance phase (will verify session phase is "complete")
  ~/.claude/hooks/lib/project-phases.sh advance "$(pwd)" "$SESSION_ID"
fi
```

If next phase exists:
- Tell user: "Starting Phase $N+1: [Title]"
- Continue with Step 1 for new phase

If all phases complete:
- Tell user: "All phases complete!"
- Generate final project summary

### /automated-dev-cycle resume

Resume the development cycle after a session interruption (e.g., context loss, terminal closed, timeout).

**When to use:** This command is ONLY needed when the automated-dev-cycle was interrupted. Within a continuous session, phase transitions happen automatically — you don't need to run resume between phases.

**Actions:**

1. Check for existing project state:
   ```bash
   HAS_STATE=$(~/.claude/hooks/lib/project-phases.sh exists "$(pwd)")
   ```

2. If no state, tell user to run `/automated-dev-cycle` to start fresh.

3. Get current status:
   ```bash
   STATUS=$(~/.claude/hooks/lib/project-phases.sh status "$(pwd)")
   CURRENT=$(~/.claude/hooks/lib/project-phases.sh current "$(pwd)")
   ```

4. Based on current phase status:
   - If `pending`: Start the phase (tree-planner auto → recursive-dev)
   - If `in_progress`: Check for active recursive-dev session
     - If found: invoke `Skill(skill: "recursive-dev", args: "status")` and continue
     - If not found: restart the phase
   - If `complete`: advance to next phase and start it

5. Resume the phase development loop (automatic transitions from here on).

### /automated-dev-cycle status

Show current status of the development cycle.

**Actions:**

1. Get project state:
   ```bash
   STATUS=$(~/.claude/hooks/lib/project-phases.sh status "$(pwd)")
   ```

2. Display:
   ```
   ## Automated Dev Cycle Status

   Project: [directory name]

   ### Phase Progress
   | # | Phase | Status |
   |---|-------|--------|
   | 1 | Architecture Setup | ✓ Complete |
   | 2 | Core Infrastructure | ⏳ In Progress |
   | 3 | Feature Implementation | ○ Pending |

   Overall: 1/3 phases complete (33%)

   ### Current Phase: Core Infrastructure
   [Show recursive-dev status if in dev phase]
   ```

3. If a recursive-dev session is active, also show task progress:
   ```bash
   Skill(skill: "recursive-dev", args: "status")
   ```

### /automated-dev-cycle skip-phase

Skip the current phase and advance to the next.

**Actions:**

1. Warn user about implications:
   - "Skipping this phase may cause issues in later phases that depend on it."
   - "Are you sure? (y/n)"

2. If confirmed:
   ```bash
   ~/.claude/hooks/lib/project-phases.sh skip "$(pwd)"
   ```

3. Show updated status and start next phase.

### /automated-dev-cycle restart-phase N

Restart from a specific phase number.

**Actions:**

1. Validate phase number exists.

2. Warn user:
   - "This will reset phases $N and later to pending."
   - "Work from those phases will need to be redone."
   - "Continue? (y/n)"

3. If confirmed:
   ```bash
   ~/.claude/hooks/lib/project-phases.sh restart "$(pwd)" "$N"
   ```

4. Start the phase development loop from phase N.

## Failure Handling

When a phase fails (recursive-dev hits max iterations, tests fail repeatedly, etc.):

1. **Pause and ask user** via AskUserQuestion:
   ```
   Phase [N] encountered an issue: [error description]

   Options:
   - Retry this phase
   - Skip to next phase
   - Stop and fix manually
   ```

2. Record the decision:
   ```bash
   ~/.claude/hooks/lib/project-phases.sh fail "$(pwd)" "error message"
   ```

3. Based on user choice:
   - **Retry**: Restart the current phase
   - **Skip**: Advance to next phase (with warning)
   - **Stop**: Exit the automated cycle, user fixes manually

## Phase Archiving

When a phase completes, auto-archive with a **smart summary**:

**In-place collapse:**
```markdown
<!-- PHASE:1:Architecture Setup -->
## Phase 1: Architecture Setup ✓ COMPLETE

**Summary:** Set up project structure, configured build system, established core patterns.
**Key decisions:** TypeScript strict mode, Vitest for testing, modular architecture.
**Artifacts:** src/, tests/, package.json, tsconfig.json
[Session: abc123 | Full spec in archive]
```

**Generate the summary** based on:
- Completed tasks from tree.json
- Modified files from state.json
- Key patterns established

**Move full spec to archive section** at the bottom of the plan file.

## Phase Resilience

Each phase should handle missing artifacts from previous phases:

- When generating the task tree, if dependencies from previous phases are missing, include tasks to create them
- This allows phases to be somewhat self-contained and recoverable
- The tree-planner auto mode considers what already exists in the codebase

## Integration Notes

### Structured Planning Integration

`/automated-dev-cycle` runs `/structured-planning` as its first step when no phase markers exist:

1. Check for phase markers in plan file
2. If no markers: invoke structured-planning
3. Structured planning guides through all phases
4. Export adds phase markers
5. Continue to tree-planner for first phase

**This ensures structured planning is never skipped**, guaranteeing comprehensive specs.

### Tree-Planner Auto Mode

When invoked from `/automated-dev-cycle`, tree-planner runs in auto mode:
- No user interaction required
- Reads structured spec from plan file
- Generates task tree based on User Outcomes and Verification Criteria
- Auto-exports to JSON

The comprehensive structured spec makes this possible — all the questions have already been answered.

### Recursive-Dev Session Management

Each phase creates its own recursive-dev session:
- Different session ID per phase
- Previous sessions preserved in `~/.claude/recursive-dev/`
- Session ID recorded in project-phases.json for reference

### Stop Hook Integration

The recursive-dev stop hook handles:
- Task verification during development
- Review phase automation
- Session completion detection

The automated-dev-cycle skill checks for completion by reading state.json:
```json
{
  "phase": "complete"  // Indicates all reviews done
}
```

## State Files

### Project State
Location: `~/.claude/recursive-dev/project-<hash>.json`

```json
{
  "projectDir": "/path/to/project",
  "planFile": "/path/to/plan.md",
  "phases": [
    {"number": 1, "title": "Architecture setup", "status": "complete"},
    {"number": 2, "title": "Core infrastructure", "status": "in_progress"},
    {"number": 3, "title": "Feature implementation", "status": "pending"}
  ],
  "currentPhase": 2,
  "completedSessions": ["abc123", "def456"],
  "created": "2024-01-15T10:00:00Z",
  "lastUpdated": "2024-01-15T14:30:00Z"
}
```

### Phase Status Values
- `pending` — Not started
- `in_progress` — Currently being worked on
- `complete` — Successfully finished
- `skipped` — User chose to skip
- `failed` — Hit an error (recorded with error message)

## Important Notes

1. **Only structured-planning is interactive** — Everything after runs automatically
2. **Each phase is independent** — Has its own recursive-dev session
3. **Trust the structured spec** — Tree-planner auto mode relies on comprehensive specs
4. **Phase transitions are automatic** — Within an active session, proceed through all phases without user input
5. **Resume is for interruptions only** — `/automated-dev-cycle resume` is for recovering from session interruption, not for normal phase transitions
6. **Failure prompts user** — Don't silently skip or fail
7. **Preserve history** — Previous sessions kept for reference
8. **Archive intelligently** — Collapse completed phases with useful summaries

## Plan File Detection

The plan file is determined by:
1. **If in plan mode**: Use the current plan file (from context)
2. **If not in plan mode**: Check for `~/.claude/recursive-dev/project-*.json` matching current directory and read `planFile` from state
3. **Otherwise**: Ask user to provide the plan file path or enter plan mode

Always store the plan file path in project-phases state so it can be retrieved on resume.
