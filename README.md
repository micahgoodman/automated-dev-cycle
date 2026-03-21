# Automated Dev Cycle

A collection of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills, agents, and hooks that orchestrate structured planning, hierarchical task breakdown, recursive development with verification, and multi-phase review — so you can hand Claude Code a project description and get back well-tested, well-documented code.

## What It Does

The core workflow:

1. **Structured Planning** — Interactively define outcomes, constraints, verification criteria, edge cases, and acceptance criteria for each phase of your project.
2. **Tree Planning** — Automatically break each phase into a hierarchical task tree with verification criteria at every level.
3. **Recursive Development** — Execute tasks depth-first with test-first development, verifying each task and parent before moving on.
4. **Design Documentation** — Document the as-built design via inline `@design` annotations, extracted into `DESIGN.md`.
5. **Multi-Phase Review** — Per-task reviews, holistic review, and validation review, each run as separate subagents for thoroughness.

The full cycle runs automatically after the initial planning conversation. Phase transitions, task verification, and review phases are all handled by hooks — you just answer planning questions at the start and let it run.

## Components

### Skills (slash commands)

| Skill | Command | Description |
|-------|---------|-------------|
| **Automated Dev Cycle** | `/automated-dev-cycle` | Orchestrates the full workflow end-to-end |
| **Structured Planning** | `/structured-planning` | Pre-flight checklist that guarantees spec coverage |
| **Tree Planner** | `/tree-planner` | Breaks projects into hierarchical task trees |
| **Recursive Dev** | `/recursive-dev` | Depth-first execution with verification at every level |
| **Design Decisions** | `/design-decisions` | Documents as-built design via `@design` annotations |
| **Review Loop** | `/review-loop` | Self-verifying task mode with configurable iterations |
| **Trace** | `/trace` | Visualizes code execution flow with ASCII/Mermaid diagrams |

### Agents

| Agent | Description |
|-------|-------------|
| **Code Path Diagrammer** | Creates implementation plans with before/after code flow diagrams |

### Hooks

Stop and UserPromptSubmit hooks that automate task verification, review phase transitions, and escape hatches for user-initiated stops during recursive development and review loops.

## Installation

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed and working
- [jq](https://jqlang.github.io/jq/) — used by hooks for JSON state management

### Steps

1. **Clone this repo:**
   ```bash
   git clone https://github.com/micahgoodman/automated-dev-cycle.git
   ```

2. **Run the installer:**
   ```bash
   cd automated-dev-cycle
   ./install.sh
   ```
   This symlinks skills, agents, and hooks into `~/.claude/`.

3. **Configure hooks in `~/.claude/settings.json`:**

   If you **don't** have an existing `settings.json`:
   ```bash
   cp settings.json.example ~/.claude/settings.json
   ```

   If you **already** have a `settings.json`, you need to merge the hook entries. The example file adds entries under `hooks.Stop` and `hooks.UserPromptSubmit` — each is an array of hook objects. Add each entry to the corresponding array in your existing file. For example, if your `settings.json` already has a `Stop` hook, append the two from the example to that array.

   The installer will check for these entries and warn you if they're missing.

## Usage

### Full Automated Cycle

```
/automated-dev-cycle
```

This starts the complete workflow: structured planning (interactive) followed by automatic phase execution. After planning, each phase runs tree planning, recursive development, design documentation, and reviews without further input.

```
/automated-dev-cycle status        # Check progress
/automated-dev-cycle resume        # Resume after interruption
/automated-dev-cycle skip-phase    # Skip current phase
/automated-dev-cycle restart-phase N  # Restart from phase N
```

### Individual Skills

You can also use each skill independently:

```
/tree-planner                # Interactively break down a project
/tree-planner export json    # Export task tree for recursive-dev
/recursive-dev start         # Execute tasks with verification
/recursive-dev review        # Run review phases
/review-loop "all tests pass"  # Self-verify focused work
/trace                       # Visualize code execution flow
/design-decisions            # Document design of existing code
```

## How It Works

```
/automated-dev-cycle
       │
       ▼
┌──────────────────┐
│  Structured       │  Interactive: define outcomes, constraints,
│  Planning         │  verification, edge cases per phase
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  For each phase:  │  Automatic from here on
│                   │
│  1. Tree Planner  │  Generate hierarchical tasks from spec
│  2. Recursive Dev │  Test-first, depth-first execution
│  3. Design Docs   │  @design annotations → DESIGN.md
│  4. Reviews       │  Per-task → holistic → validation
│                   │
│  Then advance to  │
│  next phase       │
└──────────────────┘
```

### Key Principles

- **Test-first development** — Tests are written before implementation at every level.
- **Hierarchical verification** — Verification criteria exist at leaf tasks *and* parent tasks. Parents verify integration, not just that children passed.
- **Atomic task completion** — Once a task passes verification, it's treated as a black box.
- **Separate review phases** — Design documentation, per-task reviews, holistic reviews, and validation reviews each run as separate subagent invocations. This catches different classes of bugs.
- **Depth-first, branch-complete** — All children are completed and the parent is verified before moving to the next branch.

## Project Structure

```
automated-dev-cycle/
├── install.sh                  # Symlinks everything into ~/.claude/
├── settings.json.example       # Required hook configuration
├── agents/
│   └── code-path-diagrammer.md
├── skills/
│   ├── automated-dev-cycle/    # Full workflow orchestrator
│   ├── recursive-dev/          # Task execution with verification
│   ├── tree-planner/           # Hierarchical task breakdown
│   ├── structured-planning/    # Spec coverage checklist
│   ├── design-decisions/       # As-built design documentation
│   ├── review-loop/            # Self-verifying task mode
│   └── trace/                  # Execution flow visualization
└── hooks/
    ├── recursive-dev-stop.sh   # Verification on task completion
    ├── recursive-dev-escape.sh # User-initiated stop escape hatch
    ├── review-loop-stop.sh     # Review loop verification
    ├── review-loop-escape.sh   # Review loop escape hatch
    └── lib/
        ├── recursive-dev-helpers.sh  # Session management
        ├── project-phases.sh         # Multi-phase state tracking
        ├── phase-parser.sh           # Parse phase markers from plans
        ├── tree-parser.sh            # Markdown tree → JSON
        ├── design-extract.sh         # @design annotations → DESIGN.md
        └── verify.sh                 # Verification logic
```

## Troubleshooting

**Hooks don't seem to be running (tasks aren't verified, reviews don't start):**
- Check that `~/.claude/settings.json` has both `Stop` and `UserPromptSubmit` hook entries. Run `cat ~/.claude/settings.json | jq '.hooks'` to inspect.
- Verify symlinks are intact: `ls -la ~/.claude/hooks/` — they should point back to this repo.

**"command not found: jq" or hooks fail silently:**
- Install jq: `brew install jq` (macOS) or `sudo apt-get install jq` (Ubuntu).

**State seems stuck or corrupted:**
- Check the debug log: `cat /tmp/recursive-dev-stop-debug.log`
- Session state lives in `~/.claude/recursive-dev/<session-id>/`. You can inspect `state.json` and `tree.json` directly.
- Use `/recursive-dev status` to see where things stand.

**Symlinks broken after moving the repo:**
- Re-run `./install.sh` from the new location. Symlinks are absolute paths to the repo directory.

## Uninstalling

To remove all installed components:

```bash
# Remove symlinked skills
for d in skills/*/; do rm -f ~/.claude/skills/$(basename "$d"); done

# Remove symlinked agents
for f in agents/*.md; do rm -f ~/.claude/agents/$(basename "$f"); done

# Remove symlinked hooks
for f in hooks/*.sh; do rm -f ~/.claude/hooks/$(basename "$f"); done
rm -f ~/.claude/hooks/lib

# Optionally remove state data
rm -rf ~/.claude/recursive-dev ~/.claude/review-loop
```

Then remove the `Stop` and `UserPromptSubmit` entries from `~/.claude/settings.json` that reference `recursive-dev-stop.sh`, `recursive-dev-escape.sh`, `review-loop-stop.sh`, and `review-loop-escape.sh`.

## License

MIT
