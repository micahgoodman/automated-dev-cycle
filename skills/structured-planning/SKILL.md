---
name: structured-planning
description: Structured specification skill that produces a recursive breakdown of each phase — phase → branches → self-contained leaves — with tests defining the business rule at every level, a Proof Plan per phase, and an optional 5-section prose overlay.
allowed-tools: Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# Structured Planning Skill

A "pre-flight checklist" for software development that produces consistent, complete specifications by asking the right questions in the right order.

## Purpose

Free-form planning tends to:
- Cover *most* important questions, but miss some
- Vary in quality based on how the conversation goes
- Not systematically address edge cases and failure modes
- Produce inconsistent documentation structure
- Skip past the concrete implementation steps, leaving large unknowns hidden

This skill fixes that by producing, for each phase:

1. A **recursive breakdown tree** from phase → branches → self-contained leaf changes.
2. **Tests at every level** of the tree (root, branch, leaf), written *before* implementation, that define the business rule for that node.
3. A **Proof Plan** that answers "What's the best way to prove this is built amazingly well?" — scoped to checks that go *beyond* the tests already listed in the tree.
4. An **optional 5-section prose overlay** (User Outcomes, Hard Constraints, Edge Cases, Hidden Assumptions, Acceptance Criteria) layered on top when invoked with `ask-about-options`.

## Commands

```
/structured-planning                                  # Start structured planning (breakdown + Proof Plan — always run)
/structured-planning ask-about-options                # Start + also walk through the 5-section overlay interactively
/structured-planning status                           # Show what's been specified
/structured-planning phase <name>                     # Add/edit a phase's recursive breakdown + Proof Plan
/structured-planning phase <name> ask-about-options   # Edit phase and walk through the 5-section overlay
/structured-planning review                           # Review all phases for completeness
/structured-planning export                           # Export structured spec to plan file with phase markers
```

### The `ask-about-options` flag

The **recursive breakdown and the Proof Plan are always produced** — they are the primary artifacts of this skill. They run whether or not the flag is set.

The `ask-about-options` flag **adds** a third layer on top: an interactive walk-through of the 5-section overlay (User Outcomes, Hard Constraints, Edge Cases, Hidden Assumptions, Acceptance Criteria) appended below each phase's breakdown and Proof Plan. Use the flag when the user wants extra structured prose on top of the tree.

## Structure Template

### Core artifact 1: recursive breakdown (always produced)

For each phase, produce a tree:

1. **The phase itself** — the root (e.g., `Phase 1`).
2. **Branches** — coherent sub-areas of work. Direct children of the phase are labeled with letters (`1.A`, `1.B`, …). For large phases, introduce an intermediate numeric grouping first (`1.1`, `1.2`, …) with lettered branches nested under.
3. **Leaves** — self-contained changes that can be reviewed and tested independently.

**Numbering convention.** The phase number is the root. Levels below alternate between letters and numbers (letter → number → letter → number…). Use additional depth only when needed.

- Small phase: `1` → `1.A`, `1.B` → `1.A.1`, `1.A.2`
- Larger phase: `1` → `1.1`, `1.2` → `1.1.A`, `1.1.B` → `1.1.A.1`, `1.1.A.2`

**Self-contained leaf criteria.** A node is a leaf (stop recursing) when ALL of these hold:

- [ ] The change is describable in a single sentence with a specific verb and a specific target (function, type, field, route, or file path).
- [ ] It modifies roughly one function, type, or small block of code — reviewable at a glance.
- [ ] Its tests form a **small, cohesive set** — one test, or several tests that all verify the same narrow behavior (e.g., a helper's happy-path plus the input-validation cases that define the same contract). If the tests would tell different stories or exercise different code paths, the node is a branch, not a leaf.
- [ ] No part of it needs to be sequenced or reviewed separately from the rest of the leaf.

If any criterion fails, the node is still a branch — break it down further.

**Tests at every level.** Every item in the tree — root, branch, and leaf — lists the tests that define its business rule. "Tests" here means the happy-path tests plus any tightly related failure-mode tests that define the same contract (e.g., the input-validation cases for a helper belong on the same node as that helper's happy-path test).

- **Leaf tests** encode the narrow behavior of that one change (typically unit tests).
- **Branch tests** span the branch's children and encode the branch-level business rule — whichever form of verification is appropriate (integration, contract, end-to-end, property-based). They are not a rollup of leaf tests; they assert the behavior that emerges once the children compose.
- **Phase tests** span the whole phase and encode the user-visible outcome of the phase (typically end-to-end or acceptance).

**Ordering rule: tests come first.** At every level of the tree, tests are listed *before* the implementation items they define.

- For a branch: the **Branch tests** block is placed at the top of the branch; implementation children follow below.
- For a leaf: the `Test:` line comes before the `Change:` line.

### Core artifact 2: Proof Plan (always produced)

After the recursive breakdown for each phase, produce a **Proof Plan** — a short section at the end of the phase that answers one question:

> **What's the best way to prove this is built amazingly well?**

The Proof Plan is explicitly **scoped to checks that go beyond the phase/branch/leaf tests already listed** in the tree. It captures how to gain *holistic* confidence that the feature works. This may already be covered by the phase/branch/leaf tests, but it's important to consider from a holistic perspective. Examples of possible Proof Plan items include:

- Manual walkthroughs of the full user-facing flow (click-by-click or curl-by-curl) that exercise real systems end-to-end.
- Live demos of the feature in a realistic environment (staging, local dev, beta device).
- Real-world exercise of edge scenarios (accidental inputs, boundary conditions, error paths) as a human would encounter them.

A good Proof Plan item is **concrete and executable**: a specific person could do the check and come away with a clear yes/no answer. "Test the system" will often not be a Proof Plan item; "open the app, sign up as a new user, confirm the welcome email arrives within 10 seconds, then close and reopen the app and confirm the session persists" is. Again, there may be cases where the existing tests fully cover the Proof Plan, but it's important to critically evaluate whether that's true for each case.

### Template

```markdown
## Phase 1: [Phase Name]

**Phase tests** (tests encoding the Phase 1 business rule — happy-path plus any tightly related failure-mode tests; typically e2e/acceptance):
- [ ] Test: [phase-level test]
- [ ] Test: [phase-level test]

### 1.A [Branch Name]

**Branch tests** (span 1.A's children and encode the 1.A business rule):
- [ ] Test: [branch-level test]
- [ ] Test: [branch-level test]

#### 1.A.1 [Leaf Name]
- **Test:** [the test(s) defining this leaf's business rule — a small, cohesive set; typically one test, sometimes a few tightly related cases]
- **Change:** [specific, one-sentence implementation change]

#### 1.A.2 [Leaf Name]
- **Test:** …
- **Change:** …

### 1.B [Branch Name]

**Branch tests**:
- [ ] Test: …

#### 1.B.1 [Leaf Name]
- **Test:** …
- **Change:** …

### Proof Plan

**What's the best way to prove this is built amazingly well?**

(Scope: usually checks that go *beyond* the phase/branch/leaf tests listed above — manual walkthroughs, live demos, perf/UX observations, real-world exercises, etc.)

- [ ] [Concrete, executable proof step]
- [ ] [Concrete, executable proof step]
```

### Optional overlay: 5-section template (with `ask-about-options`)

When `ask-about-options` is passed, the following template is walked through interactively for each phase and **appended below** that phase's recursive breakdown and Proof Plan. It annotates them with prose-level specification; it does not replace them.

```markdown
#### 1. User Outcomes
What can users DO when this is complete?
- [ ] User can...

#### 2. Hard Constraints
What MUST be true? (non-negotiable requirements)
- Security: ...
- Performance: ...
- Compatibility: ...
- Data: ...

#### 3. Edge Cases
| Scenario | Expected Behavior |
|----------|-------------------|
| ... | ... |

#### 4. Hidden Assumptions
| Assumption | If Wrong, Impact | How to Validate |
|------------|------------------|-----------------|
| ... | ... | ... |

#### 5. Acceptance Criteria
- [ ] All phase, branch, and leaf tests pass
- [ ] All Proof Plan items verified
- [ ] Edge cases handled gracefully
- [ ] No regressions in existing functionality
- [ ] [Phase-specific criteria]
```

## Command Implementations

### /structured-planning (start)

When invoked with no arguments or to start fresh:

**Step 1: Project Context**

Ask: "What project are you planning? Give me a brief description."

Wait for response.

**Step 2: Identify Phases**

Ask: "What are the major phases or features? List 2-5 distinct phases in the order they should be built."

Example prompts if user is stuck:
- "Think about what needs to exist before other things can work"
- "What's the minimum viable version? What comes after?"

Wait for response. Store the phase list.

**Step 3: Recursive Breakdown (always runs)**

For each phase, produce the recursive breakdown tree directly — do NOT ask the user section-by-section questions for the breakdown itself. Use the project description, the codebase (explore with Glob/Grep/Read), and reasonable inference.

For each phase, in order:

1. **Write phase-level tests first.** Draft 1–3 tests that encode the phase's overall business rule (happy-path plus any tightly related failure-mode tests that define the same contract). These define what "done" means for the phase.

2. **Identify branches.** Split the phase into coherent sub-areas. Label them with letters (`1.A`, `1.B`, …). For large phases, introduce numeric grouping first (`1.1`, `1.2`, …) with lettered branches nested under.

3. **For each branch:**
   a. **Write branch-level tests first** — tests that span the branch's children and encode its business rule (happy-path plus any tightly related failure-mode tests that define the same contract).
   b. Break the branch into children — sub-branches (if further decomposition is warranted) or leaves.

4. **For each leaf, write its tests first, then its implementation change.** Keep the leaf's tests a small, cohesive set — one test, or several that all verify the same narrow behavior. Then verify the leaf against the self-contained leaf criteria (single sentence, single target, cohesive tests, independently reviewable). If any criterion fails, promote the node back to a branch and decompose further.

5. **Probe for failure modes at every node before finalizing its tests.** After drafting the happy-path test(s) for a phase, branch, or leaf, ask: *what failure modes does this node's contract need to handle?* Run through this checklist:
   - Invalid input (malformed, out-of-range, wrong type)
   - Missing dependency (absent config, undefined hint, unavailable upstream)
   - Security boundary (unauthorized actor, privacy leak, defense-in-depth past an outer gate)
   - Fail-closed behavior (when the safe response is to refuse rather than guess)
   - Contract drift across siblings (consistency invariants between sibling nodes)

   Each genuine failure mode that defines the *same* contract as the node belongs on the node alongside the happy path. Failure modes that define a *different* contract get their own node. Failure modes that belong to a different layer of the system (e.g., a framework-level concern surfacing in a feature node) belong on the framework's tests, not here — note them as "deferred to [layer]" and move on.

6. **Validate ordering** before writing the tree to the file: at every level, tests MUST appear before implementation.

Write the drafted tree directly to the plan file (in plan mode) or ask the user for the target file path.

**Step 4: Proof Plan (always runs)**

After the recursive breakdown for each phase, draft a Proof Plan section at the end of that phase that answers: **"What's the best way to prove this is built amazingly well?"**

Rules for drafting Proof Plan items:

- **Check if we should scope them beyond the tests already listed** in the breakdown. Do not restate phase/branch/leaf tests.
- Each item should be **concrete and executable** — a specific person could do the check and come away with a clear yes/no answer.
- Prefer items that exercise the feature as a real user or operator would: manual walkthroughs, live demos, observed performance, UX feel.
- Think holistically. If you can only produce items that duplicate the tests, probe harder: what would a user notice that an automated test wouldn't catch? What subjective quality matters here? What would be embarrassing if it shipped and no one had checked?

Feel free to include as many Proof Plan items as you feel is appropriate, whether that's zero, one, or many. Append the item(s) in a `### Proof Plan` section at the end of the phase (after all branches, before any optional overlay).

**Step 5 (only if `ask-about-options` was passed): 5-section overlay**

After the breakdown and Proof Plan are in place, walk through the 5-section overlay interactively for each phase, appending results below the Proof Plan. Use the prompting questions below.

**5.1 User Outcomes**

Ask: "For [Phase Name], what can users DO when this is complete? Focus on concrete actions, not implementation details."

Prompt for specifics:
- "What new capability do they gain?"
- "What can they accomplish that they couldn't before?"

Wait for response. If response is vague, ask follow-up: "Can you make that more specific? What exactly would they click/type/see?"

**5.2 Hard Constraints**

Ask: "What MUST be true for [Phase Name]? These are non-negotiable requirements."

Present categories to consider:
- Security: authentication, authorization, data protection
- Performance: speed, scale, resource limits
- Compatibility: browsers, devices, versions, APIs
- Data: integrity, formats, migrations

Wait for response. If any category is empty, ask: "Any constraints for [category]?"

**5.3 Edge Cases**

Ask: "What happens when things go wrong in [Phase Name]?"

Prompt with scenarios:
- "What if the network fails?"
- "What if input is invalid?"
- "What if the user does something unexpected?"
- "What if there's no data / too much data?"

Build the edge case table together. For each scenario, ask: "What should happen?"

**5.4 Hidden Assumptions**

This is the most important overlay section. Ask: "What assumptions are you making about [Phase Name]?"

Actively probe:
- "What external services does this depend on?"
- "What user behavior are you assuming?"
- "What data format assumptions?"
- "What about the environment it runs in?"
- "What's assumed about existing code/infrastructure?"

For each assumption, ask:
- "If this assumption is wrong, what breaks?"
- "How could we validate this assumption early?"

**5.5 Acceptance Criteria**

Ask: "What's the pass/fail checklist for [Phase Name]?"

Start with defaults:
- [ ] All phase tests pass
- [ ] All branch tests pass
- [ ] All leaf tests pass
- [ ] All Proof Plan items verified
- [ ] Edge cases handled gracefully
- [ ] No regressions in existing functionality

Then ask: "Any phase-specific criteria to add?"

**Step 6: Check Completeness (only in `ask-about-options` mode)**

In `ask-about-options` mode: after each of the 5 overlay sections, ask "Is this complete? Anything missing?" After completing a phase's overlay, summarize and ask: "Does this fully capture [Phase Name]? Ready to move to next phase?"

**Step 7: Store Progress**

Write directly to the plan file (in plan mode) or ask the user for the target file path.

**If in plan mode:** Write to the current plan file.
**If not in plan mode:** Ask user where to save the spec, or suggest entering plan mode.

Format (written to plan file):

```markdown
# Structured Specification: [Project Name]

Created: [date]
Last updated: [date]
Status: [in-progress | complete]

## Project Overview
[Brief description]

## Phases
1. [Phase 1 name]
2. [Phase 2 name]
...

---

## Phase 1: [Name]

**Phase tests**:
- [ ] Test: ...

### 1.A [Branch Name]

**Branch tests**:
- [ ] Test: ...

#### 1.A.1 [Leaf Name]
- **Test:** ...
- **Change:** ...

[... more leaves ...]

### 1.B [Branch Name]
...

### Proof Plan

**What's the best way to prove this is built amazingly well?**
- [ ] ...
- [ ] ...

[--- 5-section overlay only if ask-about-options was used ---]

#### 1. User Outcomes
...
#### 2. Hard Constraints
...
[etc.]

---

## Phase 2: [Name]
...
```

**Note:** The spec is stored directly in the plan file. When `/structured-planning export` is run, it adds phase markers to the same file.

### /structured-planning status

Show the current state of the specification:

1. Read the current plan file (must be in plan mode or have a plan file from context).
2. Display:
   - Project name
   - Number of phases defined
   - For each phase: completeness indicators for the breakdown (phase tests present? at least one branch? every branch has branch tests? every leaf has both Test and Change?), the Proof Plan state, and — if the 5-section overlay is present — the state of those sections.
   - Overall status

Example output:

```
## Structured Planning Status

Project: User Management API
Phases: 3 defined

| Phase | Phase tests | Branches | Leaf tests | Leaf changes | Proof Plan | Overlay (5-section) |
|-------|-------------|----------|------------|--------------|------------|---------------------|
| 1. Basic Auth Setup | ✓ | 3 | ✓ | ✓ | ✓ (5 items) | ✓ |
| 2. User CRUD | ⚠ thin | 2 | ⚠ 1 missing | ✓ | ⚠ 2 items | ○ not run |
| 3. Admin Panel | ○ empty | ○ empty | ○ empty | ○ empty | ○ empty | ○ not run |

Legend: ✓ complete, ⚠ needs attention, ○ empty / not-run

Next: Run `/structured-planning phase "User CRUD"` to continue Phase 2
```

### /structured-planning phase <name> [ask-about-options]

Add or edit a specific phase's specification.

1. Parse the phase name and optional `ask-about-options` flag from arguments.
2. Look up the phase in the spec file.
3. If phase exists:
   - Show current breakdown and Proof Plan for that phase.
   - Ask: "What would you like to update?"
   - Apply the user's edits to the breakdown and/or Proof Plan. When editing leaves, maintain the test-before-change ordering and re-check the self-contained leaf criteria.
   - If `ask-about-options` is set, additionally walk through the 5 overlay sections the user wants to update.
4. If phase is new:
   - Add it to the phase list.
   - Produce the recursive breakdown (phase tests → branches → branch tests → leaves with Test-before-Change). Always runs.
   - Produce the Proof Plan. Always runs.
   - If `ask-about-options` is set, additionally walk through the 5 overlay sections.
5. Update the spec file.

### /structured-planning review

Review all phases for completeness and consistency.

**Completeness Check — recursive breakdown (always):**

For each phase, verify:
- Phase has at least one phase-level test.
- Phase has at least one branch.
- Every branch has at least one branch-level test.
- Every branch has at least one leaf (or sub-branch).
- Every leaf has both a **Test:** and a **Change:** entry.
- Every leaf's **Change** is describable in one sentence with a specific verb + target.
- At every level, tests appear before implementation.
- Every leaf satisfies the self-contained leaf criteria.
- For each node, surface a warning (not an error) if only happy-path tests are listed: *"Node X has only happy-path tests — confirm there are no failure modes worth pinning, or note them as deferred to a different layer."*

**Completeness Check — Proof Plan (always):**

For each phase, verify:
- Phase has a Proof Plan section, even if it only says that the proof is already covered by phase/branch/leaf tests.
- Items are concrete and executable (not vague, not mere restatements of the tests).
- Items collectively would go beyond the automated tests — in many contexts, at least one item should be a manual walkthrough, live demo, UX/perf observation, or real-world exercise.

**Completeness Check — overlay (only if present):**

For each phase that has the overlay:
- Empty section: "Section X is empty for Phase Y"
- Thin section (< 2 items): "Section X for Phase Y seems thin, consider adding more"
- Good: no message

**Cross-Phase Consistency Check:**

Look for:
- Contradicting constraints (e.g., Phase 1 says "no auth" but Phase 2 assumes auth exists)
- Missing dependencies (Phase 2 leaf assumes something Phase 1 should provide but doesn't)
- Duplicate work (same outcome in multiple phases)
- Leaves in later phases that depend on unbuilt leaves in earlier phases

Report findings:

```
## Review Results

### Breakdown Issues
- Phase 2, branch 2.B: missing branch-level test
- Phase 2, leaf 2.B.1: has **Change** but no **Test**
- Phase 3: entire breakdown is empty
- Phase 1, leaf 1.A.2: **Change** sentence describes two modifications — split into 1.A.2 and 1.A.3

### Proof Plan Issues
- Phase 2 Proof Plan item 1 ("test the system") is vague — make it concrete and executable

### Overlay Issues
- Phase 2 overlay: Edge Cases section is empty
- Phase 3 overlay: not run

### Consistency Issues
- Phase 2 assumes user authentication, but Phase 1 doesn't include it in outcomes
- Phase 3 "Admin can view all users" overlaps with Phase 2 "List all users"

### Recommendations
1. Add the missing branch-level test for 2.B
2. Write the test for leaf 2.B.1 before its implementation
3. Complete the breakdown for Phase 3
4. Expand Phase 2's Proof Plan with concrete manual-verification steps
```

### /structured-planning export

Add phase markers to the existing spec in the plan file, making it consumable by `/automated-dev-cycle`.

1. Read the current plan file.
2. Verify each phase has: at least one phase test, at least one branch, every branch has branch tests, every leaf has both Test and Change, and a Proof Plan section.
3. If incomplete, warn and ask to continue or abort.
4. Add phase markers (`<!-- PHASE:N:Title -->`) to the existing content:

```markdown
# Project: [Name]

[Project overview]

<!-- PHASE:1:Phase One Name -->

## Phase 1: Phase One Name

**Phase tests**:
- [ ] Test: ...

### 1.A [Branch Name]

**Branch tests**:
- [ ] Test: ...

#### 1.A.1 [Leaf Name]
- **Test:** ...
- **Change:** ...

[... more ...]

### Proof Plan

**What's the best way to prove this is built amazingly well?**
- [ ] ...
- [ ] ...

[--- overlay section if present ---]

<!-- PHASE:2:Phase Two Name -->

## Phase 2: Phase Two Name
...

<!-- PHASE:END -->
```

5. Report: "Exported to [plan file path]. You can now run `/automated-dev-cycle` to begin development."

## Behavior Guidelines

### Tests First, at Every Level

This is the single most important rule. Before writing implementation for any node, write the test that defines its business rule. When drafting a leaf, always put the `Test:` line before the `Change:` line. When drafting a branch, always put the **Branch tests** block above the implementation children.

Tests ARE the specification at each level: a leaf's test defines what that single change must do; a branch's tests define what its children must add up to; a phase's tests define what "the phase is done" means.

### Leaf Granularity

When drafting a leaf, verify it meets ALL the self-contained leaf criteria. If not, break it down further. A tree that's too shallow hides unknowns; a tree that's too deep is noise. The rule of thumb: if the leaf cannot be stated in one sentence with a specific verb and target, or if its tests would tell *different stories* or exercise different code paths (not simply "more than one test"), or if any piece of it would naturally be reviewed separately, then it is still a branch.

### Proof Plan Quality

The Proof Plan answers: "What's the best way to prove this is built amazingly well?" Its value is in capturing the *holistic* confidence-building checks that the automated tests don't cover on their own. When drafting:

- **Avoid restating tests.** If an item could just be rewritten as "Run the test suite," it's not a Proof Plan item — it's a test.
- Prefer items that a real human would do with real systems: manual walkthroughs, live demos, observations, comparisons.
- Make items **concrete and executable** — a reader should be able to act on each item without further interpretation.
- If you can only come up with vague or duplicative items, probe harder: what would be embarrassing if it shipped and no one had checked? What subjective quality matters here?

### Be Thorough But Not Tedious

- In the recursive breakdown and Proof Plan, draft directly from context — do not ask the user section-by-section questions.
- In `ask-about-options` mode, ask follow-up questions only when answers are vague or incomplete.
- Accept reasonable answers without over-probing.
- Trust the user's domain knowledge.

### Assumption Surfacing (overlay mode)

When the 5-section overlay runs, the Hidden Assumptions section is the most valuable part. Be proactive:
- Suggest assumptions the user might not have thought of.
- Challenge obvious-seeming choices: "You're assuming X — is that always true?"
- Connect assumptions to potential failure modes.

### Maintain Progress

- Store intermediate state after each phase.
- Allow resuming from where user left off.
- `/structured-planning` with an existing spec should ask to resume or start fresh.

### Quality Gates

Before moving to the next phase, verify:
- The phase has at least one phase-level test.
- The phase has at least one branch.
- Every branch has at least one branch-level test.
- Every leaf has both a Test and a Change.
- Tests appear before implementation at every level.
- Every leaf satisfies the self-contained leaf criteria.
- The phase has a Proof Plan section.
- For each node whose contract has non-trivial failure modes (anything past pure data transformation), at least one failure-mode test is listed alongside the happy path — or the failure modes have been explicitly noted as deferred to a different layer.

### Integration with /automated-dev-cycle

When invoked from `/automated-dev-cycle`:
- Skip the initial "what project" question (already known from context).
- Always produce the recursive breakdown and Proof Plan. Run the 5-section overlay only if `ask-about-options` was explicitly passed through.
- Export automatically when complete (add phase markers).
- **CRITICAL:** After export completes, DO NOT call ExitPlanMode or wait for user input.
- Instead, simply finish and allow the automated-dev-cycle workflow to continue.
- The calling workflow will proceed to tree-planner automatically.

**Important:** When structured-planning is invoked as part of automated-dev-cycle, you are a sub-step in a larger workflow. Your job is to complete the structured spec and export it. The automated-dev-cycle orchestrator will handle what comes next (tree-planner → recursive-dev). Do not attempt to exit plan mode or ask for user approval of the plan — that's the orchestrator's job after ALL phases complete.

## Storage

The spec is stored directly in the plan file. This keeps everything in one place and avoids synchronization issues.

**Plan file location:**
- If in plan mode: the current plan file (known from context).
- If not in plan mode: user-specified file path.

**No separate storage directory.** The plan file IS the spec file. When export is run, phase markers are added to the same file.

## Example Session

```
User: /structured-planning

Claude: I'll help you create a structured specification for your project.

What project are you planning? Give me a brief description.

User: A REST API for managing user accounts with authentication

Claude: Got it — a User Management REST API with authentication.

What are the major phases or features? List 2-5 distinct phases in the order they should be built.

User: 1. Basic auth setup, 2. User CRUD operations, 3. Admin panel

Claude: Three phases:
1. Basic Auth Setup
2. User CRUD Operations
3. Admin Panel

Drafting the recursive breakdown and Proof Plan for each phase now.

---

## Phase 1: Basic Auth Setup

**Phase tests**:
- [ ] Test: Full auth flow e2e — POST /register → POST /login → GET /me with bearer token → POST /logout → GET /me returns 401
- [ ] Test: 1000 concurrent logins complete under SLA

### 1.A Password hashing

**Branch tests**:
- [ ] Test: A user registered with password "foo" can log in with "foo" and cannot log in with "Foo"

#### 1.A.1 Add bcrypt hash helper
- **Test:** hashPassword("foo") returns a bcrypt string; verifyPassword("foo", hash) returns true; verifyPassword("bar", hash) returns false
- **Change:** Add src/auth/password.ts exporting hashPassword and verifyPassword using bcrypt with cost 12

#### 1.A.2 Add password_hash column to users
- **Test:** Migration applied produces a users.password_hash column of type text NOT NULL
- **Change:** Add migrations/NNNN_add_password_hash.sql with ALTER TABLE users ADD COLUMN password_hash text NOT NULL

#### 1.A.3 Wire hashPassword into insertUser
- **Test:** Inserting a user with password "foo" writes a bcrypt hash (not "foo") to users.password_hash
- **Change:** In src/users/insertUser.ts, call hashPassword(password) and pass the result into the INSERT

### 1.B Session tokens

**Branch tests**:
- [ ] Test: Logging in returns a JWT whose sub matches the user ID and which expires in 24h

#### 1.B.1 signSessionToken helper
- **Test:** signSessionToken({userId}) returns an ES256 JWT whose sub claim is userId and exp is 24h in the future
- **Change:** Add src/auth/sessionToken.ts with signSessionToken and verifySessionToken using the project KeyStore

#### 1.B.2 /auth/login issues token on valid credentials
- **Test:** POST /auth/login with valid creds returns {token} in body; token verifies to the correct userId
- **Change:** In src/routes/auth.ts, wire verifyPassword + signSessionToken into the /auth/login handler

[...]

### Proof Plan

**What's the best way to prove this is built amazingly well?**

- [ ] Open a fresh database, run migrations, and register a new user via curl; inspect the DB row and confirm password_hash is a bcrypt string (not plaintext, not empty).
- [ ] Log in with the registered credentials; decode the returned JWT at jwt.io and confirm sub, iat, and exp claims look correct.
- [ ] Mock the clock forward 24h and confirm a previously-valid token now produces 401 on a protected route.
- [ ] Attempt login with the correct password but wrong case ("Foo" instead of "foo") and confirm it's rejected.
- [ ] Review server logs for one full auth cycle and confirm no password or bcrypt hash appears anywhere in the logs.

---

Does this look right, or would you like to adjust any branch/leaf/test or Proof Plan item? If you want the 5-section prose overlay on top, re-run with `ask-about-options`.

User: Looks good. Move on.

Claude: [continues drafting Phase 2 and Phase 3 the same way, then exports]
```

## Notes

- This skill can be used standalone or as the first step of `/automated-dev-cycle`.
- The recursive breakdown and Proof Plan are the primary artifacts; the 5-section overlay is optional polish layered on top.
- Phase markers in the export allow multi-phase orchestration.
- Specs are preserved for reference even after development begins.
