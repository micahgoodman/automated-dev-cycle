---
name: structured-planning
description: Structured specification skill that guarantees coverage of outcomes, constraints, verification, edge cases, assumptions, and acceptance criteria before development.
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

This skill fixes that by guiding through a structured template for each phase/feature.

## Commands

```
/structured-planning                    # Start structured planning
/structured-planning status             # Show what's been specified
/structured-planning phase <name>       # Add/edit a phase's specification
/structured-planning review             # Review all phases for completeness
/structured-planning export             # Export structured spec to plan file with phase markers
```

## Structure Template

For each phase/feature, guide through these 6 sections:

```markdown
## Phase: [Name]

### 1. User Outcomes
What can users DO when this is complete?
- [ ] User can...
- [ ] User can...

### 2. Hard Constraints
What MUST be true? (non-negotiable requirements)
- Security: ...
- Performance: ...
- Compatibility: ...
- Data: ...

### 3. Verification Criteria
How do we KNOW it works? (concrete, testable)
- [ ] [Action] → [Expected result]
- [ ] [Action] → [Expected result]

### 4. Edge Cases
What happens when things go wrong?
| Scenario | Expected Behavior |
|----------|-------------------|
| ... | ... |

### 5. Hidden Assumptions
What assumptions are we making that should be surfaced?
| Assumption | If Wrong, Impact | How to Validate |
|------------|------------------|-----------------|
| ... | ... | ... |

### 6. Acceptance Criteria
Pass/fail checklist for completion:
- [ ] All verification criteria pass
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

**Step 3: Guide Each Phase**

For each phase in order, walk through all 6 sections:

**3.1 User Outcomes**

Ask: "For [Phase Name], what can users DO when this is complete? Focus on concrete actions, not implementation details."

Prompt for specifics:
- "What new capability do they gain?"
- "What can they accomplish that they couldn't before?"

Wait for response. If response is vague, ask follow-up: "Can you make that more specific? What exactly would they click/type/see?"

**3.2 Hard Constraints**

Ask: "What MUST be true for [Phase Name]? These are non-negotiable requirements."

Present categories to consider:
- Security: authentication, authorization, data protection
- Performance: speed, scale, resource limits
- Compatibility: browsers, devices, versions, APIs
- Data: integrity, formats, migrations

Wait for response. If any category is empty, ask: "Any constraints for [category]?"

**3.3 Verification Criteria**

Ask: "How will you KNOW [Phase Name] works? What specific tests or checks?"

Present verification types:
- Automated tests (unit, integration, e2e)
- Manual test steps (what to click/type/check)
- Build/lint passes
- Performance benchmarks
- API response validation

Wait for response. Each criterion should be concrete and testable.

**3.4 Edge Cases**

Ask: "What happens when things go wrong in [Phase Name]?"

Prompt with scenarios:
- "What if the network fails?"
- "What if input is invalid?"
- "What if the user does something unexpected?"
- "What if there's no data / too much data?"

Build the edge case table together. For each scenario, ask: "What should happen?"

**3.5 Hidden Assumptions**

This is the most important section. Ask: "What assumptions are you making about [Phase Name]?"

Actively probe:
- "What external services does this depend on?"
- "What user behavior are you assuming?"
- "What data format assumptions?"
- "What about the environment it runs in?"
- "What's assumed about existing code/infrastructure?"

For each assumption, ask:
- "If this assumption is wrong, what breaks?"
- "How could we validate this assumption early?"

**3.6 Acceptance Criteria**

Ask: "What's the pass/fail checklist for [Phase Name]?"

Start with defaults:
- [ ] All verification criteria pass
- [ ] Edge cases handled gracefully
- [ ] No regressions in existing functionality

Then ask: "Any phase-specific criteria to add?"

**Step 4: Check Completeness**

After each section, ask: "Is this complete? Anything missing?"

After completing a phase, summarize and ask: "Does this fully capture [Phase Name]? Ready to move to next phase?"

**Step 5: Store Progress**

Write directly to the plan file (in plan mode) or ask user for the target file path.

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

### 1. User Outcomes
...

### 2. Hard Constraints
...

[etc.]

---

## Phase 2: [Name]
...
```

**Note:** The spec is stored directly in the plan file, not in a separate location. When `/structured-planning export` is run, it adds phase markers to this same file.

### /structured-planning status

Show the current state of the specification:

1. Read the current plan file (must be in plan mode or have a plan file from context)
2. Display:
   - Project name
   - Number of phases defined
   - For each phase: completeness indicator (which sections are filled)
   - Overall status

Example output:
```
## Structured Planning Status

Project: User Management API
Phases: 3 defined

| Phase | Outcomes | Constraints | Verification | Edge Cases | Assumptions | Acceptance |
|-------|----------|-------------|--------------|------------|-------------|------------|
| 1. Auth Setup | ✓ | ✓ | ✓ | ✓ | ⚠ thin | ✓ |
| 2. User CRUD | ✓ | ✓ | ⚠ missing | ○ empty | ○ empty | ○ empty |
| 3. Admin Panel | ○ empty | ○ empty | ○ empty | ○ empty | ○ empty | ○ empty |

Legend: ✓ complete, ⚠ needs attention, ○ empty

Next: Run `/structured-planning phase "User CRUD"` to continue Phase 2
```

### /structured-planning phase <name>

Add or edit a specific phase's specification.

1. Parse the phase name from arguments
2. Look up the phase in the spec file
3. If phase exists:
   - Show current spec for that phase
   - Ask: "What would you like to update?"
   - Walk through the sections they want to change
4. If phase is new:
   - Add it to the phase list
   - Walk through all 6 sections (same as initial breakdown)
5. Update the spec file

### /structured-planning review

Review all phases for completeness and consistency.

**Completeness Check:**

For each phase, check each section:
- Empty: "Section X is empty for Phase Y"
- Thin (< 2 items): "Section X for Phase Y seems thin, consider adding more"
- Good: no message

**Cross-Phase Consistency Check:**

Look for:
- Contradicting constraints (e.g., Phase 1 says "no auth" but Phase 2 assumes auth exists)
- Missing dependencies (Phase 2 assumes something Phase 1 should provide but doesn't mention)
- Duplicate work (same outcome in multiple phases)

Report findings:
```
## Review Results

### Completeness Issues
- Phase 2: Edge Cases section is empty
- Phase 3: Hidden Assumptions seems thin (only 1 item)

### Consistency Issues
- Phase 2 assumes user authentication, but Phase 1 doesn't include it in outcomes
- Phase 3 "Admin can view all users" overlaps with Phase 2 "List all users"

### Recommendations
1. Add edge cases for Phase 2 (consider: what if user doesn't exist?)
2. Move authentication to Phase 1 or add it as a new phase
3. Clarify the difference between admin view and regular user list
```

### /structured-planning export

Add phase markers to the existing spec in the plan file, making it consumable by `/automated-dev-cycle`.

1. Read the current plan file
2. Verify all phases have at least User Outcomes and Verification Criteria
3. If incomplete, warn and ask to continue or abort
4. Add phase markers (`<!-- PHASE:N:Title -->`) to the existing content:

```markdown
# Project: [Name]

[Project overview]

<!-- PHASE:1:Phase One Name -->

## Phase 1: Phase One Name

### User Outcomes
- User can...

### Hard Constraints
- Security: ...

### Verification Criteria
- [ ] Action → Result

### Edge Cases
| Scenario | Expected Behavior |
|----------|-------------------|
| ... | ... |

### Hidden Assumptions
| Assumption | If Wrong, Impact | How to Validate |
|------------|------------------|-----------------|
| ... | ... | ... |

### Acceptance Criteria
- [ ] All verification criteria pass
- [ ] ...

<!-- PHASE:2:Phase Two Name -->

## Phase 2: Phase Two Name
...

<!-- PHASE:END -->
```

5. Report: "Exported to [plan file path]. You can now run `/automated-dev-cycle` to begin development."

## Behavior Guidelines

### Be Thorough But Not Tedious

- Ask follow-up questions only when answers are vague or incomplete
- Accept reasonable answers without over-probing
- Don't require every cell in tables to be filled if not applicable
- Trust the user's domain knowledge

### Assumption Surfacing is Critical

The Hidden Assumptions section is the most valuable part of this process. Be proactive:
- Suggest assumptions the user might not have thought of
- Challenge obvious-seeming choices: "You're assuming X - is that always true?"
- Connect assumptions to potential failure modes

### Maintain Progress

- Store intermediate state after each phase
- Allow resuming from where user left off
- `/structured-planning` with an existing spec should ask to resume or start fresh

### Quality Gates

Before moving to the next phase, verify:
- User Outcomes has at least one concrete outcome
- Verification Criteria has at least one testable criterion
- If Edge Cases is empty, prompt once more before continuing

### Integration with /automated-dev-cycle

When invoked from `/automated-dev-cycle`:
- Skip the initial "what project" question (already known from context)
- Focus on phase breakdown and the 6 sections
- Export automatically when complete (add phase markers)
- **CRITICAL:** After export completes, DO NOT call ExitPlanMode or wait for user input
- Instead, simply finish and allow the automated-dev-cycle workflow to continue
- The calling workflow will proceed to tree-planner automatically

**Important:** When structured-planning is invoked as part of automated-dev-cycle, you are a sub-step in a larger workflow. Your job is to complete the structured spec and export it. The automated-dev-cycle orchestrator will handle what comes next (tree-planner → recursive-dev). Do not attempt to exit plan mode or ask for user approval of the plan — that's the orchestrator's job after ALL phases complete.

## Storage

The spec is stored directly in the plan file. This keeps everything in one place and avoids synchronization issues.

**Plan file location:**
- If in plan mode: the current plan file (known from context)
- If not in plan mode: user-specified file path

**No separate storage directory.** The plan file IS the spec file. When export is run, phase markers are added to the same file.

This design:
- Keeps the spec and markers together
- Avoids two sources of truth
- Works naturally with plan mode
- Simplifies resume/continuation

## Example Session

```
User: /structured-planning

Claude: I'll help you create a structured specification for your project.

What project are you planning? Give me a brief description.

User: A REST API for managing user accounts with authentication

Claude: Got it - a User Management REST API with authentication.

What are the major phases or features? List 2-5 distinct phases in the order they should be built.

For example:
- Think about what needs to exist before other things can work
- What's the minimum viable version? What comes after?

User: 1. Basic auth setup, 2. User CRUD operations, 3. Admin panel

Claude: Three phases:
1. Basic Auth Setup
2. User CRUD Operations
3. Admin Panel

Let's define Phase 1: Basic Auth Setup.

**User Outcomes** - What can users DO when this is complete?

User: Users can register and log in

Claude: Let me make that more specific:
- Users can register with email and password
- Users can log in and receive a session/token
- Users can log out

Anything else they can do after Phase 1?

User: No that's it

Claude: Got it.

**Hard Constraints** - What MUST be true for Basic Auth Setup?

Categories to consider:
- Security: authentication, authorization, data protection
- Performance: speed, scale, resource limits
- Compatibility: browsers, devices, versions, APIs
- Data: integrity, formats, migrations

User: Passwords must be hashed, tokens should expire after 24h, must work with our existing PostgreSQL database

Claude: Good constraints:
- Security: Passwords hashed (bcrypt), tokens expire in 24h
- Compatibility: Must integrate with existing PostgreSQL database
- Any performance requirements? Expected user count?

User: Should handle 1000 concurrent users

Claude: Added. Moving on...

**Verification Criteria** - How will you KNOW Basic Auth Setup works?

User: Unit tests for auth logic, integration tests for the endpoints, manual test of the full flow

Claude: Specific tests:
- [ ] Unit tests for password hashing/verification pass
- [ ] Integration tests for /register, /login, /logout endpoints pass
- [ ] Manual test: register → login → access protected route → logout → verify token invalid

Anything else?

User: That covers it

[...continues through all 6 sections for all 3 phases...]

Claude: Phase 3 complete. Here's your specification status:

| Phase | Outcomes | Constraints | Verification | Edge Cases | Assumptions | Acceptance |
|-------|----------|-------------|--------------|------------|-------------|------------|
| 1. Basic Auth Setup | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 2. User CRUD Operations | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 3. Admin Panel | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Ready to export? Run `/structured-planning export` to add phase markers for automated development.
```

## Notes

- This skill can be used standalone or as the first step of `/automated-dev-cycle`
- The structured spec becomes input for `/tree-planner auto` mode
- Phase markers in the export allow multi-phase orchestration
- Specs are preserved for reference even after development begins
