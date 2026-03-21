---
name: tree-planner
description: Break down projects into hierarchical task trees through interactive conversation. Maintains a visual tree in the session's plan file.
allowed-tools: Read, Write, Edit, Glob, Grep
---

# Tree-Planner Skill

You are helping the user manage a hierarchical task tree for their project. The tree lives at the top of the session's plan file and tracks progress through complex projects.

## Plan File Location

The tree lives in the session's plan file:

1. **If in plan mode**: Use the current plan file (you know this from context)
2. **If not in plan mode**: Ask the user to provide the plan file path, or suggest entering plan mode first

## Context Detection (First Step)

When invoked, determine the mode based on:

1. Check if a "Project Tree" section exists in the plan file
2. Parse `$ARGUMENTS` for explicit commands
3. Use this decision matrix:

| Tree Exists? | Arguments | Mode |
|--------------|-----------|------|
| No | None | Initial breakdown |
| No | Any | Initial breakdown (use args as project description) |
| No | `auto` | **Auto mode** - Generate tree from structured spec without interaction |
| Yes | None | Show tree, ask what to do |
| Yes | `mark T1.2 done` | Update status |
| Yes | `break down T1.2` | Refine subtask |
| Yes | `show focus` | Display current focus |
| Yes | `export json` | Export tree as JSON for recursive-dev |

## Initial Breakdown Protocol

When no tree exists:

### Step 1: Ask Scope Questions (Batched)
Ask these together:
- "What's the project goal?"
- "What are the 2-4 major phases or milestones?"

### Step 2: Break Down Each Phase (One at a Time)
For each major phase:
- "What are the key tasks for [phase]?"
- Continue drilling down until tasks reach "tiny" granularity

### Step 3: Apply the Tiny Task Test

A task is small enough when it has a **single "happy path" test flow**—one coherent feature you can implement and verify in a focused session.

**Good examples of tiny tasks:**
- "Implement tab/shift+tab for checklist hierarchy" - single keyboard interaction pattern
- "Add drag-to-reorder for top-level checklist items" - one drag behavior
- "Add drag-to-reorder for nested items at any level" - extends the pattern, but still one behavior
- "Add input validation for email field" - one validation rule set

**Too big (needs further breakdown):**
- "Add checklist UX improvements" - contains multiple independent features
- "Implement drag-and-drop" - if it covers both reordering AND hierarchy changes

### Step 3.5: Ask for Verification Criteria (ALL LEVELS)

**IMPORTANT: Capture criteria for ALL tasks, not just leaves.**

When a task reaches "tiny" granularity (leaf), ask: **"How will you verify this works?"**

When defining a parent task, ask: **"How will you verify that all [children] work together correctly?"**

Present these common verification types to guide the answer:
- **Existing tests pass** - run existing test suite
- **New test written** - add a specific test for this feature
- **Manual test steps** - describe what you'll click/type/check
- **Build/lint succeeds** - compilation or linting passes
- **Visual inspection** - UI looks correct
- **API response check** - endpoint returns expected data
- **Integration works** - children combine correctly (for parents)

The brief answer becomes the inline verification criteria (added after `|` in the tree).

**Example parent criteria:**
- T1 "User endpoints" | verify: all CRUD operations work together, auth flows end-to-end
- T2 "API layer" | verify: endpoints integrate with database, error handling consistent

**The workflow for each tiny task:**
1. Use Claude Code's plan mode to write a detailed plan for the current tiny task (in the "Current Task Plan" section below the tree)
2. Exit plan mode and **write tests first** — unit tests for logic and E2E/UI tests whenever possible
3. Implement to make the tests pass, running tests to verify and assist with debugging
4. Run `/tree-planner mark Tx.x done` to update progress
5. Re-enter plan mode, update "Current Task Plan" for the next tiny task
6. Repeat until project complete

Each tiny task gets its own focused planning session. The tree provides the big picture; the Current Task Plan section holds the implementation details for whatever you're working on now.

### Step 4: Write Tree to Plan File
Add the tree section at the TOP of the plan file, followed by a separator and the "Current Task Plan" section.

## Auto Mode Protocol

When `/tree-planner auto` is invoked (typically from `/automated-dev-cycle`), generate the task tree **automatically without user interaction** based on a structured specification.

### When Auto Mode is Used

Auto mode is used when:
1. `/automated-dev-cycle` has completed structured planning
2. The plan file contains a comprehensive spec with User Outcomes, Constraints, Verification Criteria, etc.
3. The goal is hands-off tree generation

### Determining the Current Phase

Auto mode needs to know which phase to generate a tree for. Determine this by:

1. **Check project-phases state**:
   ```bash
   PHASE_INFO=$(~/.claude/hooks/lib/project-phases.sh current "$(pwd)")
   PHASE_NUM=$(echo "$PHASE_INFO" | jq -r '.number')
   PLAN_FILE=$(echo "$PHASE_INFO" | jq -r '.planFile')
   ```

2. **Extract phase content**:
   ```bash
   PHASE_CONTENT=$(~/.claude/hooks/lib/phase-parser.sh content "$PLAN_FILE" "$PHASE_NUM")
   ```

If no project-phases state exists, fall back to reading the first phase from the plan file.

### Auto Mode Steps

**Step 1: Read the Structured Spec**

Read the current phase content (determined above) and extract:
- Phase title and number (from `<!-- PHASE:N:Title -->` marker)
- User Outcomes (what users can do)
- Hard Constraints (what must be true)
- Verification Criteria (how to test)
- Edge Cases (failure scenarios)
- Acceptance Criteria (pass/fail checklist)

**Step 2: Generate Task Breakdown**

Based on the spec, generate a hierarchical task tree:

1. **Top-level tasks** map to major functionality areas from User Outcomes
2. **Subtasks** are derived by breaking down each outcome into implementation steps
3. **Verification criteria** are copied/adapted from the spec
4. **Parent criteria** combine child verifications into integration checks

Apply the Tiny Task Test: each leaf task should have a single "happy path" test flow.

**Step 3: Derive Verification Criteria**

For each task:
- **Leaf tasks**: Use the most specific verification from the spec that applies
- **Parent tasks**: Create integration criteria that verify children work together
- If the spec has explicit Verification Criteria, map them to appropriate tasks
- Ensure every task has a verification criterion

**Step 4: Write Tree Immediately**

Write the generated tree to the plan file without asking for confirmation.

Format follows the standard tree format with all verification criteria inline.

**Step 5: Auto-Export to JSON**

After writing the tree, immediately export to JSON:
1. Create `~/.claude/recursive-dev/tree-export.json`
2. Include execution order (depth-first, branch-complete)
3. Report completion

### Auto Mode Output

After auto mode completes, output:
```
Generated task tree for Phase N: [Title]

Tasks: X total (Y leaf tasks)

Top-level breakdown:
- T1: [description]
- T2: [description]
- ...

Exported to: ~/.claude/recursive-dev/tree-export.json

Ready for recursive-dev.
```

### Auto Mode Principles

1. **Trust the spec** — The structured planning phase already asked all the questions
2. **No interaction** — Don't ask clarifying questions, make reasonable decisions
3. **Be comprehensive** — Cover all User Outcomes from the spec
4. **Be practical** — Create tasks that are actually implementable
5. **Preserve intent** — Verification criteria should match spec intent

### Example Auto Mode

Given a structured spec for "User Authentication" phase:

```markdown
### User Outcomes
- User can register with email/password
- User can log in and receive a session token
- User can log out

### Verification Criteria
- [ ] POST /register creates user, returns 201
- [ ] POST /login with valid credentials returns token
- [ ] POST /logout invalidates token
- [ ] All tests pass
```

Auto mode generates:

```markdown
# Project Tree: User Authentication

## Task Hierarchy

- T1 [PENDING] User Registration | verify: register flow works e2e, user persisted
  - T1.1 [PENDING] Implement /register endpoint | verify: POST /register returns 201
  - T1.2 [PENDING] Add input validation | verify: invalid email/password rejected
  - T1.3 [PENDING] Hash and store password | verify: stored hash != plaintext
- T2 [PENDING] User Login | verify: login flow works e2e with token
  - T2.1 [PENDING] Implement /login endpoint | verify: valid credentials return token
  - T2.2 [PENDING] Generate JWT token | verify: token contains user ID, expires
  - T2.3 [PENDING] Validate credentials | verify: wrong password returns 401
- T3 [PENDING] User Logout | verify: logout invalidates session
  - T3.1 [PENDING] Implement /logout endpoint | verify: POST /logout returns 200
  - T3.2 [PENDING] Invalidate token | verify: old token rejected after logout
```

## Status Update Protocol

When updating status (e.g., `/tree-planner mark T2.1 done`):

1. Read current tree from plan file
2. Find the referenced task (e.g., T2.1)
3. **Verification gate** (for marking done): Ask "Did verification pass? What did you test?"
   - Wait for user to confirm verification passed
   - If verification failed or was skipped, don't mark done—help troubleshoot instead
4. Update its status to the requested state
5. **Propagate status** using these rules:
   - All children `[PENDING]` → parent `[PENDING]`
   - Any child `[IN PROGRESS]` → parent `[IN PROGRESS]`
   - Any child `[DONE]` but not all → parent `[IN PROGRESS]`
   - All children `[DONE]` → parent `[DONE]`
6. Update "Current focus" to next pending leaf task
7. Update progress percentage
8. Write updated tree back to file

## Refinement Protocol

When breaking down a task further (e.g., `/tree-planner break down T3.1`):

1. Read current tree
2. Find the target task
3. Ask focused questions about that specific task
4. Insert new subtasks under it with appropriate IDs (e.g., T3.1.1, T3.1.2)
5. For each new leaf task, ask "How will you verify this works?" and add verification criteria
6. **For the parent task being broken down, ask "How will you verify these subtasks work together?"**
7. Write updated tree

## JSON Export Protocol

When `/tree-planner export json` is invoked:

1. Read current tree from plan file
2. Parse into structured JSON format
3. Calculate execution order (depth-first, branch-complete)
4. Write to `~/.claude/recursive-dev/tree-export.json`
5. Return the file path

### JSON Output Format

```json
{
  "root": "Project description",
  "planFile": "/path/to/plan.md",
  "projectDir": "/path/to/project",
  "tasks": {
    "T1": {
      "id": "T1",
      "description": "User endpoints",
      "criteria": "All user CRUD operations work together",
      "status": "PENDING",
      "parent": null,
      "children": ["T1.1", "T1.2"]
    },
    "T1.1": {
      "id": "T1.1",
      "description": "Create user endpoint",
      "criteria": "POST /users creates user, returns 201",
      "status": "PENDING",
      "parent": "T1",
      "children": []
    }
  },
  "order": ["T1.1", "T1.2", "T1", "T2.1", "T2.2", "T2"]
}
```

### Execution Order Calculation

For depth-first, branch-complete order:
1. Start with all top-level tasks in order (T1, T2, ...)
2. For each task with children, recursively insert children before parent
3. Result: all leaves before their parent, all siblings in order

Example:
```
T1 (has T1.1, T1.2)
  T1.1 (leaf)
  T1.2 (has T1.2.1, T1.2.2)
    T1.2.1 (leaf)
    T1.2.2 (leaf)
T2 (leaf)

Order: T1.1, T1.2.1, T1.2.2, T1.2, T1, T2
```

## Verification Enforcement

Verification is enforced at 4 layers to ensure every task has a way to check work:

### Layer 1: During Breakdown (ALL LEVELS)
- For leaf tasks: "How will you verify this works?"
- For parent tasks: "How will you verify these work together?"

Present these verification types as options:
- Existing tests pass
- New test written
- Manual test steps (describe)
- Build/lint succeeds
- Visual inspection
- API response check
- Integration works (for parents)

The brief answer becomes inline verification criteria.

### Layer 2: Inline in Tree
Each task (leaf AND parent) includes verification after a `|` separator:
```
- T1 [PENDING] User endpoints | verify: all CRUD work, auth flows complete
  - T1.1 [PENDING] Add tab indent | verify: tab indents, shift+tab outdents
  - T1.2 [PENDING] Add email validation | verify: existing tests pass, invalid emails rejected
```

### Layer 3: Current Task Plan Section
When writing the detailed plan for a tiny task, expand the brief verification criteria into detailed steps:
```markdown
## Verification
- [ ] Press tab on a list item → item indents one level
- [ ] Press shift+tab on indented item → item outdents one level
- [ ] Tab on already-max-depth item → no change (doesn't break)
```

### Layer 4: Mark-Done Gate
When running `/tree-planner mark Tx done`, ask: **"Did verification pass? What did you test?"**

Only mark the task complete after the user confirms verification passed. This ensures work is actually validated, not just "finished."

## Plan File Format

The plan file has two sections:

```markdown
# Project Tree: [Project Name]

## Status Legend
- [PENDING] - Not started
- [IN PROGRESS] - Work has begun
- [DONE] - Completed

## Task Hierarchy

- T1 [STATUS] Task description | verify: integration criteria for parent
  - T1.1 [STATUS] Subtask description | verify: brief verification criteria
  - T1.2 [STATUS] Subtask description | verify: criteria
    - T1.2.1 [STATUS] Sub-subtask description | verify: how to check this works
- T2 [STATUS] Another task | verify: criteria
  - T2.1 [STATUS] Subtask | verify: tests pass, visual check

---
**Last updated:** YYYY-MM-DD
**Current focus:** Tx.x (Task description)
**Progress:** X/Y tasks complete (Z%)

---

# Current Task Plan: Tx.x (Task description)

[Detailed plan for the current tiny task - this section is managed during plan mode, not by tree-planner]
```

## Task ID Guidelines

- Max recommended depth: 4 levels (T1.2.3.4)
- If deeper nesting is needed, consider grouping tasks under a new top-level branch
- IDs are for reference—descriptions matter more

## Status Values

- `[PENDING]` - Not started (default for new tasks)
- `[IN PROGRESS]` - Work has begun on this task or any of its children
- `[DONE]` - Completed (for leaf tasks) or all children completed (for parent tasks)

## Progress Calculation

Count only leaf tasks (tasks with no children) for progress:
- Total = number of leaf tasks
- Complete = number of leaf tasks marked `[DONE]`
- Percentage = (Complete / Total) * 100, rounded to nearest integer

## Current Focus Selection

The current focus should be the first leaf task (deepest task with no children) that is `[PENDING]` or `[IN PROGRESS]`, traversing the tree in order (T1 before T2, T1.1 before T1.2, etc.).

## Example Interactions

### Initial Breakdown
```
User: /tree-planner
Claude: I'll help you break down your project into a task tree.

What's the project goal, and what are the 2-4 major phases or milestones you envision?
```

### With Project Description
```
User: /tree-planner build a REST API for user management
Claude: I'll help break down your REST API for user management project.

Based on this goal, I'm thinking of these major phases:
1. Design & Setup
2. Core CRUD endpoints
3. Authentication/Authorization
4. Testing & Documentation

Does this structure work, or would you like to adjust the phases?

[...after drilling down to tiny tasks...]

Claude: "Add input validation for user creation" feels like a tiny task now.

How will you verify this works? Common options:
- Existing tests pass
- New test written
- Manual test steps
- Build/lint succeeds
- Visual inspection
- API response check

User: I'll write a new test that checks invalid emails are rejected

Claude: Got it. Adding to tree as:
- T2.1.3 [PENDING] Add input validation for user creation | verify: new test, invalid emails rejected

Now for the parent T2.1 "Implement user creation endpoint" - how will you verify all these subtasks work together?

User: Integration test that creates a user end-to-end

Claude: Updated parent:
- T2.1 [PENDING] Implement user creation endpoint | verify: integration test, create user e2e
```

### Status Update
```
User: /tree-planner mark T1.2 done
Claude: Before I mark T1.2 (Add input validation) as done:

Did verification pass? What did you test?

(The verification criteria was: "new test, invalid emails rejected")

User: Yes, I wrote a test in test_users.py that checks empty email, invalid format, and duplicate email all return 400 errors. All tests pass.

Claude: Verified and updated T1.2 to [DONE].

Progress: 3/10 tasks complete (30%)
Current focus: T1.3 (Add error handling)
```

### Refinement
```
User: /tree-planner break down T2.1 further
Claude: Let's break down T2.1 (Implement user creation endpoint) into smaller steps.

What are the key parts of this task? For example:
- Input validation
- Database operations
- Response formatting
- Error handling

Which of these apply, and are there others?

User: All of those, plus password hashing

Claude: I'll add those as subtasks. For each one, how will you verify it works?

T2.1.1 - Input validation: How will you verify?
User: New test for invalid inputs

T2.1.2 - Password hashing: How will you verify?
User: Check stored password != raw password, and login works

T2.1.3 - Database operations: How will you verify?
User: Manual test - create user, check DB

T2.1.4 - Response formatting: How will you verify?
User: Existing API tests pass

T2.1.5 - Error handling: How will you verify?
User: New tests for each error case

Claude: Now for the parent T2.1 - how will you verify all these subtasks work together?

User: Integration test that creates a user with all validations and checks the DB

Claude: Updated tree:
- T2.1 [PENDING] Implement user creation endpoint | verify: integration test, full create flow
  - T2.1.1 [PENDING] Input validation | verify: new test for invalid inputs
  - T2.1.2 [PENDING] Password hashing | verify: stored != raw, login works
  - T2.1.3 [PENDING] Database operations | verify: manual test, check DB
  - T2.1.4 [PENDING] Response formatting | verify: existing API tests pass
  - T2.1.5 [PENDING] Error handling | verify: new tests for each error case
```

### Export JSON for recursive-dev
```
User: /tree-planner export json
Claude: Exported tree to JSON format.

File: ~/.claude/recursive-dev/tree-export.json

Execution order (depth-first, branch-complete):
1. T1.1 (Create user endpoint)
2. T1.2 (Update user endpoint)
3. T1 (User endpoints) ← parent review
4. T2.1 (Add authentication)
5. T2 (Auth layer) ← parent review

You can now run `/recursive-dev start` to begin the development loop.
```

### Show Focus
```
User: /tree-planner show focus
Claude: Current focus: T2.2 (Add input validation for user endpoint)

This task involves:
- Validating required fields (email, password)
- Checking email format
- Ensuring password meets requirements

Previous: T2.1 [DONE] - Create user endpoint skeleton
Next up: T2.3 [PENDING] - Add database integration
```

### Existing Tree, No Args
```
User: /tree-planner
Claude: [Shows the current tree]

# Project Tree: User Management API

[...tree content...]

Progress: 5/12 tasks complete (42%)
Current focus: T2.3 (Add database integration)

What would you like to do?
- Mark a task as done (e.g., "mark T2.3 done")
- Break down a task further (e.g., "break down T3")
- Export as JSON for recursive-dev (e.g., "export json")
- Update the current focus
- Something else?
```

## Integration with recursive-dev

The tree-planner works with `/recursive-dev` for automated development:

1. Use tree-planner to break down the project (with criteria at ALL levels)
2. Run `/tree-planner export json` to create structured data
3. Run `/recursive-dev start` to begin the automated development loop

The key difference when preparing for recursive-dev:
- **Always capture parent criteria** during breakdown
- Parent criteria define what "integration" means for that level
- The recursive-dev hook will verify against these criteria

## Important Notes

1. **Don't over-engineer the initial breakdown** - It's okay to start with fewer tasks and refine later
2. **Keep task descriptions concise** - One line each, details go in the Current Task Plan section
3. **Trust the user's judgment** - If they say a task is small enough, accept it
4. **Update immediately** - When a task is marked done, update the file right away
5. **Be conversational** - This is an interactive breakdown, not a form to fill out
6. **Always capture parent criteria** - Every task with children needs integration criteria
