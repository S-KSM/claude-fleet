# Orchestrating a Claude Fleet: Parallel Development with Git Worktrees and tmux

Most developers interact with AI coding assistants in **serial mode**: prompt, watch tokens stream, run a test, fix an error, repeat. You sit idle while the model thinks; the model sits idle while you read.

In talks dissecting how Anthropic engineers use Claude Code internally, Daisy Hollman highlighted a core shift in perspective: **stop pair-programming with a single assistant and start managing a parallel fleet of agents.**

To execute multiple agent sessions concurrently on a single machine without clobbering Git branches, corrupting builds, or colliding on file locks, you combine two UNIX primitives: **Git Worktrees** and **`tmux`**.

This repository contains the philosophy, architecture, scripts, and lifecycle patterns to orchestrate Claude Code across isolated, concurrent workspaces.

---

## The Philosophy: Why "Fleet" Over "Pair"

### 1. Eliminating the Turn-Taking Bottleneck
When an agent runs an end-to-end test suite, scans 50 files, or executes an extensive refactoring pass, your local terminal is blocked. In a fleet setup, that workload runs in an isolated, detached background pane while you dispatch the next feature in parallel.

### 2. Context Window Isolation
Forcing an entire sprint or multiple unrelated bugs into one Claude session degrades reasoning over time. Claude performs best when given a crisp, singular objective. By compartmentalizing tasks into dedicated branches and directories, each agent starts with a pristine context window focused exclusively on its domain.

### 3. Filesystem Sandboxing via Git Worktrees
Running multiple AI agents inside the same local working directory causes file chaos:
* Agent A edits `src/auth.ts` while Agent B is running a test suite that relies on `src/auth.ts`.
* Stashes, checkouts, and temporary build outputs collide.
* Language servers and hot-reloading dev servers spike system load trying to track conflicting writes.

A Git worktree allows you to check out multiple branches simultaneously from the same repository into distinct directories, backed by a single shared `.git` history. You get complete isolation with zero duplicated git histories.

---

## Repository Structure

```text
claude-fleet/
├── README.md                     # Architecture, philosophy, and operational guide
├── bin/
│   ├── claude-fleet-common.sh    # Shared helpers sourced by every script below
│   ├── claude-fleet              # Ad-hoc multi-pane launcher (CLI arguments)
│   ├── claude-fleet-start        # Automated batch launcher (tasks.txt + dependency bootstrap)
│   ├── claude-fleet-status       # Cross-agent dashboard (diffs, dirty state, ahead/behind)
│   ├── claude-fleet-ship         # PR dispatcher (pushes branches, creates GitHub draft PRs)
│   ├── claude-fleet-clean        # Teardown script (kills tmux, purges .worktrees/)
│   ├── claude-fleet-brain-tasks  # Optional: team-brain "ready to ship" → tasks.brain.txt
│   └── claude-fleet-install-dispatch  # Optional: wire up team-brain + Dispatch in one pass
└── examples/
    ├── tasks.txt.example         # Sample task definition file
    ├── CLAUDE.md.example         # Agent completion protocol and guidelines
    └── .claude-fleet.conf.example  # Optional team-brain integration config
```

When active inside any target project (e.g., `baby_journey`), the directory structure organizes cleanly:

```text
baby_journey/
├── .gitignore                    # Automatically appends .worktrees/
├── .worktrees/                   # Ignored container holding active agent worktrees
│   ├── auth-modal/               # Pane 1 (Branch: agent/auth-modal)
│   ├── photo-feed/               # Pane 2 (Branch: agent/photo-feed)
│   └── api-metrics/              # Pane 3 (Branch: agent/api-metrics)
├── src/
├── package.json
└── CLAUDE.md
```

---

## Installation

Make all scripts globally available in your environment:

```bash
# Clone the repository
git clone https://github.com/your-username/claude-fleet.git
cd claude-fleet

# Link or copy binaries to your user path
mkdir -p ~/.local/bin
cp bin/* ~/.local/bin/
chmod +x ~/.local/bin/claude-fleet*
```

Ensure `~/.local/bin` is in your `$PATH` (e.g., in `~/.zshrc` or `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Verify the tools are accessible:

```bash
claude-fleet --help 2>/dev/null || which claude-fleet
```

---

## The Complete Toolchain

### 1. `bin/claude-fleet` (Interactive Ad-Hoc Launcher)

Launches ad-hoc tasks passed directly as command-line arguments. See [`bin/claude-fleet`](bin/claude-fleet).

### 2. `bin/claude-fleet-start` (Automated Batch Launcher)

Pulls `main`, reads batch goals from `tasks.txt`, bootstraps package dependencies (`npm`, `pnpm`, `poetry`, `pip`), provisions trees, and sends initial prompts directly to Claude. See [`bin/claude-fleet-start`](bin/claude-fleet-start).

### 3. `bin/claude-fleet-status` (Inspection Dashboard)

Provides a clean overview across all agent worktrees without switching panes. See [`bin/claude-fleet-status`](bin/claude-fleet-status).

### 4. `bin/claude-fleet-ship` (PR Dispatcher)

Pushes all agent branches that contain commits ahead of `main` and creates draft GitHub Pull Requests. See [`bin/claude-fleet-ship`](bin/claude-fleet-ship).

### 5. `bin/claude-fleet-clean` (Session Teardown)

Safely kills the fleet `tmux` session, removes worktree directories, and prunes the Git pointer table. See [`bin/claude-fleet-clean`](bin/claude-fleet-clean).

### 6. `bin/claude-fleet-brain-tasks` (Optional: Team-Brain Task Generator)

Generates a tasks file from a [team-brain](https://github.com/zoraxl/team-brain) checkout's `ready to ship` plan phases. Inert unless configured. See [`bin/claude-fleet-brain-tasks`](bin/claude-fleet-brain-tasks).

### 7. `bin/claude-fleet-install-dispatch` (Optional: Team-Brain + Dispatch Setup)

One-pass installer that wires this repo's fleet setup together with a [team-brain](https://github.com/zoraxl/team-brain) checkout and a [Dispatch](https://github.com/S-KSM/Manager) checkout: writes `.claude-fleet.conf`, runs Dispatch's `hooks/install.sh`, and drops in `WORKFLOW.fleet.md`. See [`bin/claude-fleet-install-dispatch`](bin/claude-fleet-install-dispatch) — it does not build or install the Dispatch app itself, only the glue between the three.

---

## Optional: Team-Brain Integration

Fleet is a parallel *execution* layer: many isolated worktrees running at once. [team-brain](https://github.com/zoraxl/team-brain) is a *knowledge and lifecycle* layer: plans move through stages (`brainstorm → planned → ready to ship → implemented-pending-pr → pr-open → implemented-and-synced → archived`) and a wiki holds only decided, implemented knowledge.

This integration is entirely opt-in — nothing below runs unless you configure it, and the default `tasks.txt` workflow is untouched.

### Setup

```bash
cp examples/.claude-fleet.conf.example .claude-fleet.conf
# edit .claude-fleet.conf: set TEAM_BRAIN_DIR to your team-brain checkout
```

Optionally, use the team-brain-flavored agent protocol instead of the default one:

```bash
cp examples/CLAUDE.md.team-brain.example CLAUDE.md
```

### Workflow

```bash
claude-fleet-brain-tasks          # scan $TEAM_BRAIN_DIR/plans for status: ready to ship,
                                   # write tasks.brain.txt (prompt: /implement <plan path>)
claude-fleet-start tasks.brain.txt
# ...agents run /implement on their assigned phase, as normal...
claude-fleet-ship                 # pushes branches, opens draft PRs, AND patches each
                                   # synced plan's frontmatter: status: pr-open, related_pr: <PR#>
```

`claude-fleet-brain-tasks` never modifies `tasks.txt` or team-brain's wiki — it only reads plan frontmatter and writes a separate `tasks.brain.txt` plus an internal slug-to-plan map (`.worktrees/.brain-map`) that `claude-fleet-ship` uses to route PR numbers back to the right plan file. team-brain's own `/wiki-sync` skill still owns closing the loop post-merge (creating/flipping ADRs, updating wiki pages, archiving the plan).

### Alternative: continuous dispatch instead of a daily batch

The above is the batch flow: a human runs `claude-fleet-brain-tasks` + `claude-fleet-start` once and walks away. If you'd rather have a daemon continuously claim `ready to ship` plans as they appear — no morning batch step — [Dispatch](https://github.com/S-KSM/Manager)'s orchestrator can drive the same worktrees directly via a `team-brain` tracker (`WORKFLOW.md` `tracker.kind: team-brain`), with `claude-fleet-status`/`-ship`/`-clean` unchanged. Run `claude-fleet-install-dispatch` once to wire it up (writes `.claude-fleet.conf`, installs Dispatch's hooks, drops in `WORKFLOW.fleet.md`), then `dispatch start --workflow ./WORKFLOW.fleet.md` instead of `claude-fleet-start`. Don't run both dispatchers against the same repo — see `WORKFLOW.fleet.md`'s header comment for why.

---

## Integrating with Claude Code (`CLAUDE.md`)

To guarantee that agents running autonomously in parallel produce clean, production-ready code, copy [`examples/CLAUDE.md.example`](examples/CLAUDE.md.example) into your repository's root `CLAUDE.md`.

---

## End-to-End Daily Operating Workflow

### Step 1: Define Tasks (`tasks.txt`)

Copy [`examples/tasks.txt.example`](examples/tasks.txt.example) to `tasks.txt` in your project root and edit it:

```text
auth-modal  | Refactor AuthModal to use JWT refresh tokens and add Vitest unit tests.
photo-feed  | Optimize image lazy-loading on the feed and resolve cumulative layout shifts.
api-metrics | Add Prometheus gauge counters to the /api/health route.
```

### Step 2: Morning Launch

Run from the root of your project:

```bash
claude-fleet-start
```

* Pulls latest changes from `main`.
* Creates `.worktrees/auth-modal`, `.worktrees/photo-feed`, and `.worktrees/api-metrics`.
* Automatically runs dependency installation in each isolated tree.
* Boots Claude Code in a 3-pane tiled `tmux` session and submits the respective prompt.

### Step 3: Monitor & Orchestrate

* **Attach to dashboard:**
  ```bash
  tmux attach -t claude-fleet
  ```
* **Switch panes:** Press `Ctrl + b`, then use the **Arrow Keys**.
* **Zoom in/out on an agent:** Press `Ctrl + b`, then **`z`**.
* **Detach (leave agents running):** Press `Ctrl + b`, then **`d`**.
* **Check status at a glance:**
  ```bash
  claude-fleet-status
  ```
  ```text
  WORKTREE / SLUG        | AHEAD (MAIN) | UNCOMMITTED  | DIFF SUMMARY
  ----------------------------------------------------------------------------------------
  auth-modal             | ahead: 2     | dirty: 0     | 4 files, +128/-22 lines
  photo-feed             | ahead: 1     | dirty: 1     | 2 files, +45/-10 lines
  api-metrics            | ahead: 1     | dirty: 0     | 1 file, +30/-2 lines
  ```

### Step 4: Ship

When tasks are committed and passing:

```bash
claude-fleet-ship
```

Pushes all `agent/*` branches with commits ahead of `main` and creates draft PRs via GitHub CLI.

### Step 5: Clean Up

Once PRs are merged or reviewed:

```bash
claude-fleet-clean
```

Terminates the background `tmux` session, deletes the temporary `.worktrees/` directory, and cleans Git's worktree pointers.
