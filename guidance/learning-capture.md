<!-- Load when: when and where to persist operational learnings -->
# Learning Capture

Operational learnings, behavioral adjustments, and discovered patterns must be captured **immediately when they occur**, not deferred to session wrapup.

## The Multi-Destination Rule

Every learning has up to four destinations. Always evaluate which apply:

| Destination | What Goes Here | Who Benefits |
|---|---|---|
| **Memory** (`~/.claude/projects/<project>/memory/`) | Personal cross-session recall | This user's future Claude sessions |
| **Project repo** (`CLAUDE.md`, `context.md`) | Repo-specific rules and patterns | Any agent working in that specific repo |
| **This repo, or your private context repo** | Cross-project patterns and operational knowledge | All agents, all repos, all sessions |
| **Your knowledge base** | Cross-repo synthesized knowledge (when a learning spans 3+ repos) | Any agent needing cross-cutting context |

### Decision: shared guidance vs private context

- **This repo** (public or team-visible): behavioral rules, workflow patterns, techniques, prompt strategies, integration patterns. Nothing that reveals infrastructure, credentials, or sensitive identifiers.
- **Your private context repo**: prompt templates with sensitive details, credential patterns, infrastructure-specific knowledge, operational details that reference internal systems.
- **When in doubt:** if it mentions a hostname, IP address, username, API key, or private repo name, it goes in the private repo.

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

1. **User corrects you:** save the feedback before continuing with the corrected approach
2. **New capability established:** after verifying it works, record it before moving on
3. **Pattern discovered:** after confirming the pattern, persist it
4. **Integration wired up:** after testing, document the wiring

Do NOT batch these to session wrapup. By then, details are lost and the learning is less precise.

## How to Capture

### Preferred: Use the Propagation Script

The fastest and most reliable way to capture a learning is the single-command propagation script:

```bash
scripts/propagate-learning.sh \
  --type feedback \
  --summary "One-line description" \
  --body "Full learning content" \
  --repo <repo-name> \
  --guidance-file guidance/<relevant-file>.md
```

This handles memory + `CLAUDE.md` + guidance file in one command. Add `--private` to route to your private context repo, `--cross-cutting` to flag for the knowledge base, `--dry-run` to preview.

> **Caveat: the script pushes directly.** `propagate-learning.sh` runs `git commit && git push -u origin HEAD` in the guidance repo. If `main` is checked out there (the normal session-start state), `--guidance-file` commits straight to `main`, bypassing any PR-review gate; this is easy to miss and can accumulate many unreviewed commits before anyone notices. For guidance edits that should go through review, use a git worktree on an existing open branch instead of editing the checkout that is sitting on `main`. The script is safe for memory and repo-`CLAUDE.md` destinations when those repos have no PR-review gate on direct pushes.

For complex or nuanced learnings where the script isn't sufficient, spawn a propagation subagent (if you have one defined) to handle routing decisions, duplicate checking, and index lookup.

### Manual Capture (when the script doesn't fit)

#### Step 1: Save to memory (always)
Standard memory file with frontmatter.

#### Step 2: Identify the right repo-level destination(s)

| Learning Type | Repo Destination | Shared guidance / private context? |
|---|---|---|
| Repo-specific rule | That repo's `CLAUDE.md` | Only if it's a cross-project pattern |
| Workflow pattern | N/A | `guidance/<topic>.md` in this repo |
| Prompt template | N/A | `prompts/<name>.md` in your private context repo |
| Infrastructure detail | N/A | `infrastructure.md` or `accounts.md` in your private context repo |
| User preference/style | N/A | the voice/style guidance file in this repo |

#### Step 3: Commit and push
Learnings committed to shared guidance or private context must be pushed immediately. They're useless if they sit local-only.

## Updating Existing Guidance

When a learning modifies or extends an existing rule:
1. **Find the canonical source** in your guidance index (`MANIFEST.md` or equivalent)
2. **Edit in place:** don't create a new file if an existing one covers the topic
3. **Update the index** if you add a new guidance file
4. **Update the core rules file's guidance index** if you add a new guidance file

## Responding to Mistakes

When you make a mistake and identify the cause, run this process before moving on:

1. **Check existing guidance.** Search `guidance/` and your private context repo for rules that should have prevented the mistake.
2. **If the rule exists:** figure out why it wasn't followed. Is the rule too narrow? Was there a gap in the trigger condition? Update the rule to close the gap.
3. **If no rule exists:** add one to the appropriate location (shared guidance for cross-session, repo `CLAUDE.md` for repo-specific).
4. **Commit and push the rule update.** Rules that aren't pushed don't help future sessions.

**Why this matters:** rules that exist but aren't followed indicate either a rule clarity problem or a missing trigger condition. Every failure should become a rule improvement; don't just fix the symptom, patch the prevention.

## Explicit User Directives ("Update Guidance", "Record This")

When the user says **"update guidance"**, **"record this into guidance"**, **"save this direction"**, or similar, the primary target is **always repo instruction files**, not memory.

### Routing Order for User Directives

1. **Find the canonical source.** Check the guidance index for the right file. If the directive maps to an existing guidance file, edit it in place.
2. **Update the repo file(s).** Edit the relevant file in `guidance/`, your private context repo, or the project's `CLAUDE.md`, as appropriate.
3. **Update the knowledge base.** If the change affects cross-repo knowledge (instruction architecture, integration patterns, or anything already covered by an existing article), update that article too.
4. **Commit and push.** Immediately. Unpushed rule changes don't help future sessions.
5. **Optionally save a memory file.** As a personal index/cache. Memory is supplementary, never the primary destination.

### MEMORY.md Index Budget (hard constraint)

`MEMORY.md` is loaded into context every session, so it has a real size ceiling
(roughly 24KB; the loader truncates the tail past it and silently drops entries).
Keep it healthy:

- **One line per memory, hook under ~128 chars total line length.** The detail lives
  in the topic file (context-on-demand via Read), never in the index hook.
- **Only one of the two write paths is capped.** `scripts/propagate-learning.sh`
  truncates on append, but the built-in memory tool writes `MEMORY.md` directly
  and bypasses that cap entirely. Assume any index has uncapped hooks in it; the
  session-start hook below is what actually enforces the limit.
- **A session-start hook self-heals.** `hooks/compact-memory-index.sh` re-compacts
  over-long hooks every session (idempotent, non-destructive: it only trims hook
  text, never deletes a memory file) and both it and the appender take an
  `flock` on `MEMORY.md.lock` so concurrent background appends are not clobbered. Run
  `hooks/compact-memory-index.sh --check` to report size and longest line (exit 3 if
  over the hard limit). **`--check` audits every index on the machine; the hook
  itself deliberately heals only the current project's**, so another project's
  over-budget index is invisible during your sessions. Run `--check` explicitly
  when you want the fleet-wide picture.
- **An over-length hook is itself a trigger, independent of file size.** If compaction
  only runs once an index passes the soft size limit, an index sitting anywhere below
  it accumulates uncapped hooks indefinitely and is never normalised. If you are
  reasoning about why an index "looks long" while under budget, that is the mechanism.
- **When the hook WARNS that the index is still over budget after compaction,**
  truncation alone is not enough: prune. Delete or consolidate memories that are
  (a) redundant with an always-loaded rule, (b) marked superseded/stale, or
  (c) duplicates. Redundant-with-guidance memories add zero recall value because
  the rule is already in context every session; archive them under
  `memory/archived/` (reversible) rather than leaving orphaned index lines.

### Common Mistakes to Avoid

- **Memory-only updates:** writing a memory file and stopping. Memory is invisible to other agents and sessions that don't share your memory directory. The user said "update guidance"; they mean the durable instruction system.
- **Skipping the knowledge base:** if the topic already has an article there, update it alongside the guidance file.
- **Creating new files when an existing one covers the topic:** always check the guidance index and search `guidance/` first.

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
