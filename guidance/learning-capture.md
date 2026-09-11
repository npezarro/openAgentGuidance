<!-- Load when: when and where to persist operational learnings -->
# Learning Capture

Operational learnings, behavioral adjustments, and discovered patterns must be captured **immediately when they occur**, not deferred to session wrapup.

## The Multi-Destination Rule

Every learning has up to four destinations. Always evaluate which apply:

| Destination | What Goes Here | Who Benefits |
|---|---|---|
| **Memory** (your agent memory directory) | Personal cross-session recall | This user's future agent sessions |
| **Project repo** (`CLAUDE.md`, `context.md`) | Repo-specific rules and patterns | Any agent working in that specific repo |
| **This repo or your private context repo** | Cross-project patterns and operational knowledge | All agents, all repos, all sessions |
| **Your knowledge base** | Cross-repo synthesized knowledge (when a learning spans 3+ repos) | Any agent needing cross-cutting context |

**This rule stays binding for interactive sessions even if your scoring or audit tooling exempts them.** If a separate pass (a learning agent mining transcripts, for example) is assumed to cover interactive sessions, the absence of a score on these rules is not permission to skip the behavior: it means a different pass is responsible for catching the gap, not that there is no gap to catch. Whatever always-loaded core rules file you use should keep naming interactive sessions explicitly as a mandatory trigger.

### Decision: public guidance vs private context

- **This repo** (public or shareable): Behavioral rules, workflow patterns, techniques, prompt strategies, integration patterns. Nothing that reveals infrastructure, credentials, or sensitive identifiers.
- **Your private context repo** (private): Prompt templates with sensitive details, credential patterns, infrastructure-specific knowledge, project-specific operational details that reference internal systems.
- **When in doubt:** If it mentions a hostname, IP address, username, API key, or private repo name, it goes in the private context repo.

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

1. **User corrects you**: Save the feedback before continuing with the corrected approach
2. **New capability established**: After verifying it works, record it before moving on
3. **Pattern discovered**: After confirming the pattern, persist it
4. **Integration wired up**: After testing, document the wiring

Do NOT batch these to session wrapup. By then, details are lost and the learning is less precise.

## How to Capture

### Preferred: Use the Propagation Script

If this repo ships a propagation script, it is the fastest and most reliable way to capture a learning in one command:

```bash
scripts/propagate-learning.sh \
  --type feedback \
  --summary "One-line description" \
  --body "Full learning content" \
  --repo <repo-name> \
  --guidance-file guidance/<relevant-file>.md
```

This handles memory + `CLAUDE.md` + guidance file in one command. Add `--private` for private-context routing, `--cross-cutting` for knowledge-base flagging, `--dry-run` to preview.

> **Caveat, a propagation script that commits and pushes will use whatever branch is checked out.** `propagate-learning.sh` runs `git commit && git push -u origin HEAD` in the guidance repo. If `main` is checked out there (the normal session-start state), `--guidance-file` commits straight to `main`, bypassing PR review on any repo that expects review. For guidance edits that should go through review, work in a worktree on an existing open branch instead of letting the script push to the checked-out branch. The script is safe for memory and repo `CLAUDE.md` destinations when those repos have no PR-review gate on direct pushes.

For complex or nuanced learnings where the script isn't sufficient, spawn a propagation subagent (if you have one defined) to handle routing decisions, duplicate checking, and `MANIFEST.md` lookup.

### Manual Capture (when the script doesn't fit)

#### Step 1: Save to memory (always)
Standard memory file with frontmatter.

#### Step 2: Identify the right repo-level destination(s)

| Learning Type | Repo Destination | Guidance repo / private context repo? |
|---|---|---|
| Repo-specific rule | That repo's `CLAUDE.md` | Only if it's a cross-project pattern |
| Workflow pattern | N/A | `guidance/<topic>.md` in this repo |
| Prompt template | N/A | `prompts/<name>.md` in your private context repo |
| Infrastructure detail | N/A | `infrastructure.md` or `accounts.md` in your private context repo |
| User preference/style | N/A | `guidance/written-voice.md` in this repo, or similar |

#### Step 3: Commit and push
Learnings committed to the guidance repo or the private context repo must be pushed immediately. They're useless if they sit local-only.

## Updating Existing Guidance

When a learning modifies or extends an existing rule:
1. **Find the canonical source** in `MANIFEST.md`
2. **Edit in place**: Don't create a new file if an existing one covers the topic
3. **Update `MANIFEST.md`** if you add a new guidance file
4. **Update the guidance file index** in your core rules file if you add a new guidance file

## Responding to Mistakes

When you make a mistake and identify the cause, run this process before moving on:

1. **Check existing guidance.** Search `guidance/` and your private context repo for rules that should have prevented the mistake.
2. **If the rule exists:** Figure out why it wasn't followed. Is the rule too narrow? Was there a gap in the trigger condition? Update the rule to close the gap.
3. **If no rule exists:** Add one to the appropriate location (this repo for cross-session, repo `CLAUDE.md` for repo-specific).
4. **Commit and push the rule update.** Rules that aren't pushed don't help future sessions.

**Why this matters:** Rules that exist but aren't followed indicate either a rule clarity problem or a missing trigger condition. Every failure should become a rule improvement; don't just fix the symptom, patch the prevention.

## Explicit User Directives ("Update Guidance", "Record This")

When the user says **"update guidance"**, **"record this into guidance"**, **"save this direction"**, or similar, the primary target is **always repo instruction files**, not memory.

### Routing Order for User Directives

1. **Find the canonical source.** Check `MANIFEST.md` for the right file. If the directive maps to an existing guidance file, edit it in place.
2. **Update the repo file(s).** Edit the relevant file in `guidance/`, your private context repo, or the project's `CLAUDE.md`, as appropriate.
3. **Update the knowledge base.** If the change affects cross-repo knowledge (instruction architecture, integration patterns, or anything already covered by an existing article), update that article too.
4. **Commit and push.** Immediately. Unpushed rule changes don't help future sessions.
5. **Optionally save a memory file** as a personal index/cache. Memory is supplementary, never the primary destination.

### MEMORY.md Index Budget (hard constraint)

`MEMORY.md` is loaded into context every session, so it has a real size ceiling (roughly 24KB; the loader truncates the tail past it and silently drops entries). Keep it healthy:

- **One line per memory, hook under ~128 chars total line length.** The detail lives in the topic file (context-on-demand via Read), never in the index hook.
- **Only one of the two write paths is capped.** `scripts/propagate-learning.sh` truncates on append, but the built-in memory tool writes `MEMORY.md` directly and bypasses that cap entirely. Assume any index has uncapped hooks in it; the session-start hook below is what actually enforces the limit.
- **A session-start hook self-heals.** `hooks/compact-memory-index.sh` re-compacts over-long hooks every session (idempotent and non-destructive: it only trims hook text, never deletes a memory file), and both it and the appender take an `flock` on `MEMORY.md.lock` so concurrent cron appends are not clobbered. Run `hooks/compact-memory-index.sh --check` to report size and longest line (exit 3 if over the hard limit). **`--check` audits every index on the machine; the hook itself deliberately heals only the current project's**, so another project's over-budget index is invisible during your sessions. Run `--check` explicitly when you want the machine-wide picture.
- **An over-length hook is itself a trigger, independent of file size.** If compaction only runs once an index passes the soft limit, an index anywhere below that limit accumulates uncapped hooks indefinitely and is never normalised. If you are reasoning about why an index "looks long" while under budget, that is the mechanism.
- **When the hook WARNS that the index is still over budget after compaction,** truncation alone is not enough: prune. Delete or consolidate memories that are (a) redundant with an always-loaded rule, (b) marked superseded or stale, or (c) duplicates. Redundant-with-guidance memories add zero recall value because the rule is already in context every session; archive them under `memory/archived/` (reversible) rather than leaving orphaned index lines.
- **`project_`/`reference_` pruning is automated, so don't hand-prune those.** `hooks/memory-autodemote.sh` (daily cron) demotes `project_`/`reference_` entries with zero reads across all session transcripts (past a 14-day mtime grace) into the recall-searchable lazy tier, closing the gap the WARN-only bullet above describes; it existed because nothing previously subtracted entries automatically. Files stay on disk and stay searchable by recall; a pointer line in `MEMORY.md` names the tier. `feedback_`/`rule_`/`pattern_`/`rollup_`/`learning_` entries are deliberately NOT touched by this script: they work by being present in context, so a zero-read count says nothing about their value, and pruning those still needs the manual judgement call above.

### Common Mistakes to Avoid

- **Memory-only updates**: Writing a memory file and stopping. Memory is invisible to other agents and sessions that don't share your memory directory. The user said "update guidance"; they mean the durable instruction system.
- **Skipping the knowledge base**: If the topic already has an article, update it alongside the guidance file.
- **Creating new files when an existing one covers the topic**: Always check `MANIFEST.md` and search `guidance/` first.

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

### A backtick inside a double-quoted `--body` is command substitution, so the propagation script silently writes the empty result

`propagate-learning.sh` takes `--body` as a normal shell argument. Passing markdown that contains a backticked code span inside double quotes makes the shell run it as command substitution: the span disappears, stderr shows something like "proxy:: command not found", and the empty result is written to memory, the repo `CLAUDE.md`, and the guidance file. The script still exits 0 and reports success to every destination, so the corruption is only visible by reading the written file.

It bites hardest on exactly the learnings worth saving, because those are the ones naming a literal config key, flag, or sentinel; the sentence loses the identifier it existed to name and reads as complete.

Avoid it by quoting the body with a single-quoted heredoc, which does no substitution at all:

```bash
BODY=$(cat <<'EOF'
... markdown with backticks, $vars and "quotes" all literal ...
EOF
)
scripts/propagate-learning.sh --type pattern --summary "..." --body "$BODY"
```

The heredoc delimiter must be quoted. Failing that, use double quotes for code spans in the body instead of backticks. Either way, READ BACK one destination file after propagating; the exit code does not tell you the text survived.
