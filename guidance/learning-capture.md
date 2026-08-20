<!-- Load when: when and where to persist operational learnings -->
# Learning Capture

Operational learnings, behavioral adjustments, and discovered patterns must be captured **immediately when they occur**, not deferred to session wrapup.

## The Multi-Destination Rule

Every learning has up to four destinations. Always evaluate which apply:

| Destination | What Goes Here | Who Benefits |
|---|---|---|
| **Memory** (your agent's per-user memory directory) | Personal cross-session recall | Your future sessions |
| **Project repo** (`CLAUDE.md`, `context.md`) | Repo-specific rules and patterns | Any agent working in that specific repo |
| **The guidance repo or your private context repo** | Cross-project patterns and operational knowledge | All agents, all repos, all sessions |
| **Your knowledge base** | Cross-repo synthesized knowledge (when a learning spans 3+ repos) | Any agent needing cross-cutting context |

### Decision: guidance repo vs private context repo

- **Guidance repo** (public): Behavioral rules, workflow patterns, techniques, prompt strategies, integration patterns. Nothing that reveals infrastructure, credentials, or sensitive identifiers.
- **Private context repo** (private): Prompt templates with sensitive details, credential patterns, infrastructure-specific knowledge, project-specific operational details that reference internal systems.
- **When in doubt:** If it mentions a hostname, IP, username, API key, or private repo name, it goes in the private context repo.

## What Counts as a Learning

- A behavior that should be repeated or avoided in future sessions
- A new capability, tool, or integration pattern that was established
- A correction from the user (explicit or implied)
- A failure mode discovered and its fix
- A prompt strategy or framing that produced better results
- An infrastructure detail that future sessions will need
- An adjustment to an existing rule based on new evidence

## When to Capture

**Immediately**, not at session end. Specifically:

1. **User corrects you** — Save the feedback before continuing with the corrected approach
2. **New capability established** — After verifying it works, record it before moving on
3. **Pattern discovered** — After confirming the pattern, persist it
4. **Integration wired up** — After testing, document the wiring

Do NOT batch these to session wrapup. By then, details are lost and the learning is less precise.

## How to Capture

### Preferred: Use a Propagation Script

The fastest and most reliable way to capture a learning is a single-command propagation script that writes every destination at once. A workable interface:

```bash
scripts/propagate-learning.sh \
  --type feedback \
  --summary "One-line description" \
  --body "Full learning content" \
  --repo <repo-name> \
  --guidance-file guidance/<relevant-file>.md
```

This handles memory + `CLAUDE.md` + guidance file in one command. Add `--private` for private-repo routing, `--cross-cutting` for knowledge-base flagging, `--dry-run` to preview.

> **Caveat — direct-to-main push:** a propagation script that runs `git commit && git push -u origin HEAD` inside the guidance repo will commit straight to whatever branch is checked out. If `main` is checked out there (the normal state at session start), `--guidance-file` bypasses PR review on a public repo. This is not hypothetical: 15+ commits once landed on a public repo's `main` this way before anyone noticed. For guidance edits that should go through review, work on a branch or a worktree instead. Direct push is fine for memory and repo-`CLAUDE.md` destinations when those repos are private and have no PR-review gate.

For complex or nuanced learnings where the script isn't sufficient, spawn a dedicated propagation subagent that handles routing decisions, duplicate checking, and manifest lookup.

### Manual Capture (when the script doesn't fit)

#### Step 1: Save to memory (always)
Standard memory file with frontmatter.

#### Step 2: Identify the right repo-level destination(s)

| Learning Type | Repo Destination | Guidance/private repo? |
|---|---|---|
| Repo-specific rule | That repo's `CLAUDE.md` | Only if it's a cross-project pattern |
| Workflow pattern | N/A | `guidance/<topic>.md` in the guidance repo |
| Prompt template | N/A | `prompts/<name>.md` in your private context repo |
| Infrastructure detail | N/A | `infrastructure.md` or `accounts.md` in your private context repo |
| User preference/style | N/A | A voice/style guidance file in the guidance repo |

#### Step 3: Commit and push
Learnings committed to the guidance or private context repo must be pushed immediately. They're useless if they sit local-only.

## Updating Existing Guidance

When a learning modifies or extends an existing rule:
1. **Find the canonical source** in the guidance repo's manifest/index
2. **Edit in place** — Don't create a new file if an existing one covers the topic
3. **Update the manifest** if you add a new guidance file
4. **Update the top-level agent instructions' guidance file index** if you add a new guidance file

## Responding to Mistakes

When you make a mistake and identify the cause, run this process before moving on:

1. **Check existing guidance.** Search the guidance repo and your private context repo for rules that should have prevented the mistake.
2. **If the rule exists:** Figure out why it wasn't followed. Is the rule too narrow? Was there a gap in the trigger condition? Update the rule to close the gap.
3. **If no rule exists:** Add one to the appropriate location (guidance repo for cross-session, repo `CLAUDE.md` for repo-specific).
4. **Commit and push the rule update** — rules that aren't pushed don't help future sessions.

**Why this matters:** Rules that exist but aren't followed indicate either a rule clarity problem or a missing trigger condition. Every failure should become a rule improvement — don't just fix the symptom, patch the prevention.

## Explicit User Directives ("Update Guidance", "Record This")

When the user says **"update guidance"**, **"record this into guidance"**, **"save this direction"**, or similar — the primary target is **always repo instruction files**, not memory.

### Routing Order for User Directives

1. **Find the canonical source** — Check the guidance manifest for the right file. If the directive maps to an existing guidance file, edit it in place.
2. **Update the repo file(s)** — Edit the relevant file in the guidance repo, your private context repo, or the project's `CLAUDE.md`, as appropriate.
3. **Update the knowledge base** — If the change affects cross-repo knowledge (instruction architecture, integration patterns, or anything already covered by an existing article), update that page too.
4. **Commit and push** — Immediately. Unpushed rule changes don't help future sessions.
5. **Optionally save a memory file** — As a personal index/cache. Memory is supplementary, never the primary destination.

### Memory Index Budget (hard constraint)

The memory index file (`MEMORY.md`) is loaded into context every session, so it has a real size ceiling (~24.4KB; past it the loader truncates the tail and silently drops entries). Keep it healthy:

- **One line per memory, hook ≤ ~128 chars total line length.** The detail lives in the topic file (context-on-demand via Read), never in the index hook.
- **Cap the write path at the source.** Have the propagation script truncate the hook when it appends a new entry.
- **Self-heal on session start.** A session-start hook that re-compacts over-long hooks every session (idempotent, non-destructive: it only trims hook text, never deletes a memory file) keeps drift from accumulating. Have both the compactor and the appender take an `flock` on `MEMORY.md.lock` so concurrent scheduled appends are not clobbered. A `--check` mode that reports size and longest line (exit 3 if over the hard limit) makes the state auditable.
- **When the hook WARNS that the index is still over budget after compaction,** truncation alone is not enough: prune. Delete or consolidate memories that are (a) redundant with an always-loaded rule, (b) marked superseded/stale, or (c) duplicates. Redundant-with-guidance memories add zero recall value because the rule is already in context every session; archive them under `memory/archived/` (reversible) rather than leaving orphaned index lines.

### Common Mistakes to Avoid

- **Memory-only updates**: Writing a memory file and stopping. Memory is invisible to other agents and sessions that don't share your memory directory. The user said "update guidance" — they mean the durable instruction system.
- **Skipping the knowledge base**: If the topic already has an article there, update it alongside the guidance file.
- **Creating new files when an existing one covers the topic**: Always check the manifest and search `guidance/` first.

### Trigger Keywords

React to any of these as a directive to update repo files:
- "update guidance" / "add to guidance" / "record this into guidance"
- "save this direction" / "save this rule"
- "remember this for all sessions" / "make this permanent"
- "add this to the rules" / "update the rules"
- Any correction + "make sure this doesn't happen again"

## What NOT to Capture

- One-time debugging steps (they're in git history)
- Code patterns visible from reading the code
- Task-specific context that won't recur
- Anything already documented in the destination file
