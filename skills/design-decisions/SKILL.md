---
name: design-decisions
description: Documents the as-built design of code via inline @design annotations, extractable into DESIGN.md. The backward-looking counterpart to structured-planning — examines code as it is and documents what was actually built.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Design Decisions — As-Built Design Documentation

## What I do

After code is written, I examine the implementation and document the design that emerged — the architecture, patterns, data flows, and key structural choices — as structured inline `@design` annotations directly in the source code.

These annotations are the single source of truth. A companion extraction script (`~/.claude/hooks/lib/design-extract.sh`) builds them into a standalone DESIGN.md document — the same pattern as OpenAPI/JSDoc/rustdoc where inline code generates documentation.

This is the backward-looking counterpart to structured-planning: structured-planning specifies *what we plan to build* before development; design-decisions documents *what actually got built* after development.

## Commands

### Document design decisions
```
/design-decisions
```
Analyzes the current project and adds `@design` annotations to source files, then generates DESIGN.md.

### Document a specific task
```
/design-decisions <task_id>
```
Analyzes only the modified files for a specific tree-planner task (e.g., `T1.2`). Requires an active recursive-dev session.

### Extract DESIGN.md from existing annotations
```
/design-decisions extract
```
Regenerates DESIGN.md from existing `@design` annotations without adding new ones. Useful after manual edits to annotations.

### Check annotation coverage
```
/design-decisions status
```
Counts `@design` annotations in the project and shows per-task coverage if a recursive-dev session exists.

## The @design Annotation Format

Structured comments using the host language's native comment syntax. Each annotation starts with `@design` and a title, followed by indented key-value sub-fields.

### Format

```python
# @design JWT-Based Authentication
#   design: Stateless auth via JWT access tokens (15min) + rotating refresh tokens,
#           validated by middleware on every protected route
#   context: Needed to avoid per-request DB session lookups at scale; refresh rotation
#            limits exposure window if a token is stolen
#   tradeoffs: More complex client-side token management; tokens can't be revoked
#              instantly without maintaining a blocklist
#   alternatives: Server-side sessions (simpler but needs sticky sessions/shared store)
#   task: T1.2
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| Title (on `@design` line) | Yes | Short name for the design (2-5 words) |
| `design:` | Yes | What the design is and how it works |
| `context:` | Yes | What shaped this design — reasoning, constraints, requirements |
| `tradeoffs:` | No | Properties or costs accepted with this design |
| `alternatives:` | No | Other approaches that exist |
| `task:` | No | Tree-planner task ID (auto-set in recursive-dev integration) |

### Language Examples

**TypeScript / JavaScript:**
```typescript
// @design Event-Driven State Updates
//   design: EventEmitter pattern with typed events instead of direct state mutation;
//           all state changes flow through a central dispatcher
//   context: Decouples producers from consumers; enables replay and audit logging
//   tradeoffs: Indirection makes debugging harder; event ordering must be managed
//   task: T2.1
export class StateManager {
```

**Go:**
```go
// @design Connection Pool Sizing
//   design: Fixed pool of 25 connections with 5s idle timeout
//   context: Matches DB max_connections/4 to allow multiple service instances
//   tradeoffs: Under-utilized connections during low traffic; potential queuing during spikes
//   alternatives: Dynamic pool (complexity); per-request connections (too many open)
//   task: T1.3
func NewPool(cfg Config) *Pool {
```

**Rust:**
```rust
// @design Error Propagation
//   design: Custom error enum with thiserror, propagated via ? operator
//   context: Type-safe errors with automatic From conversions; clean call sites
//   tradeoffs: Boilerplate for each new error variant
//   alternatives: anyhow (less type safety); manual Result mapping
//   task: T3.1
```

**Shell (Bash):**
```bash
# @design State File Locking
#   design: Atomic write via temp file + mv instead of file locks
#   context: mv is atomic on POSIX; avoids flock portability issues across macOS/Linux
#   tradeoffs: Brief window where parallel readers see stale data
#   task: T2.3
```

### Parsing Rules

1. An annotation starts when a comment line contains `@design` followed by the title text
2. Subsequent comment lines indented 2+ spaces (after the comment marker) with a recognized field key followed by a colon are sub-fields
3. Multi-line values continue on the next indented comment line if it doesn't start with a recognized field key
4. The annotation ends at the first non-comment line or a non-indented comment line
5. Do not put blank comment lines between fields within an annotation
6. Recognized comment prefixes: `#`, `//`, `--`, `%`, `*`

## Analysis Process

When documenting design decisions (either standalone or from recursive-dev integration):

### Step 1: Identify scope
- **With task ID**: Read the task from tree.json, focus on its modified files
- **Standalone**: Identify the project's key source files via Glob

### Step 2: Gather context
- If available, read the tree-planner task description and structured-planning spec to understand intended vs actual design
- In standalone mode without a recursive-dev session, skip this — work from the code alone

### Step 3: Read and analyze code
For each file in scope, examine the code as it is and identify:
- **Architecture patterns** — How components are organized and communicate
- **Data structures** — Key data models, schemas, state shape
- **Control flow** — How data and execution flow through the system
- **Error handling** — Recovery strategies, failure modes, error boundaries
- **API contracts** — Interfaces, endpoints, message formats
- **Concurrency** — Threading, async patterns, synchronization approaches
- **State management** — Where state lives, how it's updated, consistency guarantees

### Step 4: Add annotations
- Place `@design` annotations above the class/function/block that embodies the design
- Use the file's native comment syntax
- Check for existing annotations to avoid duplicates
- Set the `task:` field if a task ID is known

### Step 5: Generate DESIGN.md
Run the extraction script:
```bash
~/.claude/hooks/lib/design-extract.sh "$(pwd)"
```

After extracting, report what was documented:
```
DESIGN_RESULT: {"task": "<task_id>", "annotations": <count>, "summary": "<brief description of what was documented>"}
```

## Quality Guidelines

### DO annotate
- Architecture and structural patterns that aren't obvious from a single file
- Data model choices that constrain or enable future changes
- Security-related design choices
- Performance or scalability decisions
- Integration points and API contracts
- Concurrency and state management strategies
- Anything a future developer would need to understand to safely modify the code

### DO NOT annotate
- Standard framework conventions (e.g., "using Express middleware" in a Node app)
- Language idioms (e.g., "using list comprehension" in Python)
- Trivial implementation details self-evident from reading the code
- Things already documented in README, docstrings, or API docs

### Density targets
- **3-8 annotations per task** for a typical feature implementation
- **Fewer** for simple/mechanical tasks
- **Zero** is acceptable if a task involves no meaningful design decisions
- **More** for architecturally complex work (new subsystems, major refactors)
- Aim for **3-6 lines per annotation** (title + design + context, optionally tradeoffs/alternatives)

## Integration Mode

When called from the recursive-dev `design-documentation` phase, this skill runs automatically for each task:

1. The stop hook provides the task ID, description, and modified files
2. A Task subagent is spawned with fresh context to analyze the code
3. The subagent adds `@design` annotations and outputs `DESIGN_RESULT`
4. After all tasks are documented, the extraction script generates DESIGN.md
5. The review phase begins with the design documentation in place

Reviewers benefit from the annotations in two ways:
- **Inline**: When reading modified files, `@design` annotations explain the intended design
- **DESIGN.md**: Provides a holistic view of all design decisions across the project
