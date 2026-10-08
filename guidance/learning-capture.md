<!-- Load when: when and where to persist operational learnings -->
# Learning Capture

Capture operational learnings, behavioral adjustments and discovered patterns **as soon as they happen**. Do not save them up for the end of the session.

## The Multi-Destination Rule

A learning can go to up to four places. Check every one of them each time:

| Destination | What Goes Here | Who Benefits |
|---|---|---|
| **Memory** (your agent's per-user memory directory) | Personal recall across sessions | This user's future sessions |
| **Project repo** (`CLAUDE.md`, `context.md`) | Rules and patterns specific to that repo | Any agent working in that repo |
| **This repo or your private context repo** | Patterns and operational knowledge that apply across projects | All agents, all repos, all sessions |
| **Your knowledge base** | Cross-repo knowledge, used when a learning spans 3+ repos | Any agent that needs cross-cutting context |

The rule still applies when no automated check or score enforces it in a given session type. If nothing scores you on it, that only means some other pass is meant to catch the gap. The gap is still real.

### Decision: this repo vs your private context repo

- **This repo** (shareable): behavioral rules, workflow patterns, techniques, prompt strategies, integration patterns. Nothing that reveals infrastructure, credentials or sensitive identifiers.
- **Your private context repo**: prompt templates that contain sensitive details, credential patterns, infrastructure-specific knowledge, and operational details that name internal systems.
- **When in doubt:** if it mentions a hostname, IP, username, API key or private repo name, it goes in the private context repo.

## What Counts as a Learning

- Behavior to repeat or avoid in future sessions
- A new capability, tool or integration pattern you set up
- A correction from the user, explicit or implied
- A failure mode you found, along with its fix
- A prompt strategy or framing that worked better
- An infrastructure detail future sessions will need
- A change to an existing rule based on new evidence

## When to Capture

**Right away**, not at session end. In particular:

1. **The user corrects you:** save the feedback before you continue with the corrected approach.
2. **You set up a new capability:** once it is verified to work, record it before moving on.
3. **You discover a pattern:** once the pattern is confirmed, persist it.
4. **You wire up an integration:** once it is tested, document the wiring.

Do NOT batch these for session wrapup. By then the details are gone and the learning is less precise.

## How to Capture

### Preferred: a single propagation command

If your setup has a propagation script that writes memory, the repo `CLAUDE.md` and a guidance file in one step, use it. It is the fastest and most reliable path. A typical interface looks like this:

```bash
./scripts/propagate-learning.sh \
  --type feedback \
  --summary "One-line description" \
  --body "Full learning content" \
  --repo <repo-name> \
  --guidance-file guidance/<relevant-file>.md
```

Useful flags: `--private` routes to the private context repo, `--cross-cutting` flags the learning for the knowledge base, and `--dry-run` previews the result.

**Find out whether the script appends or queues.** Some setups send guidance learnings to an inbox file that no session loads, and a later consolidation pass merges them into the target file. In that case the lesson is saved right away but does not take effect until that pass runs. If a session needs the rule in force now, edit the target file directly on a branch. Merge into an existing rule rather than adding a dated section, and stay within any size limit the guidance files have.

**Watch for scripts that commit and push straight to `main`.** If a helper runs `git commit && git push` in a clone where `main` is checked out, every learning it writes skips PR review. For guidance edits that should be reviewed, work in a worktree on a learnings branch instead. Direct pushes are fine for destinations that have no review gate, such as memory or private repo `CLAUDE.md` files.

For complex or nuanced learnings the script can't handle, hand the job to a dedicated propagation agent if you have one. It can make the routing decisions, check for duplicates and look up the right file in your guidance index.

### Manual Capture (when the script doesn't fit)

#### Step 1: Save to memory (always)
Write a standard memory file with frontmatter.

#### Step 2: Pick the repo-level destination(s)

| Learning Type | Repo Destination | Shared guidance / private context? |
|---|---|---|
| Repo-specific rule | That repo's `CLAUDE.md` | Only if it is a cross-project pattern |
| Workflow pattern | N/A | `guidance/<topic>.md` in this repo |
| Prompt template | N/A | A prompts directory in your private context repo |
| Infrastructure detail | N/A | An infrastructure or accounts file in your private context repo |
| User preference or style | N/A | A voice/style guidance file in this repo |

#### Step 3: Commit and push
Push learnings committed to this repo or the private context repo immediately. A learning that only exists locally helps nobody.

## Updating Existing Guidance

When a learning changes or extends an existing rule:
1. **Find the canonical source** in your guidance index or manifest.
2. **Edit it in place.** Don't create a new file if an existing one already covers the topic.
3. **Update the manifest** if you add a new guidance file.
4. **Update the guidance file index** in your core agent instructions if you add a new guidance file.

## Responding to Mistakes

When you make a mistake and identify the cause, work through these steps before moving on:

1. **Check existing guidance.** Search this repo's guidance and your private context repo for a rule that should have prevented the mistake.
2. **If the rule exists:** work out why it wasn't followed. Is it too narrow? Does its trigger condition miss this case? Update the rule to close the gap.
3. **If no rule exists:** add one in the right place (this repo for cross-session rules, the repo `CLAUDE.md` for repo-specific ones).
4. **Commit and push the rule update.** Rules that aren't pushed don't help future sessions.

**Why this matters:** a rule that exists but wasn't followed points to an unclear rule or a missing trigger condition. Every failure should improve a rule. Don't just fix the symptom; fix what should have prevented it.

## Explicit User Directives ("Update Guidance", "Record This")

When the user says **"update guidance"**, **"record this into guidance"**, **"save this direction"** or something similar, the main target is **always the repo instruction files**, not memory.

### Routing Order for User Directives

1. **Find the canonical source.** Check the manifest for the right file. If the directive fits an existing guidance file, edit that file in place.
2. **Update the repo file(s).** Edit the relevant file in this repo's `guidance/`, your private context repo, or the project's `CLAUDE.md`.
3. **Update the knowledge base** if the change affects cross-repo knowledge, such as instruction architecture, integration patterns, or a topic that already has a knowledge base article.
4. **Commit and push** right away. Rule changes that aren't pushed don't help future sessions.
5. **Optionally save a memory file** as a personal index or cache. Memory is extra, never the main destination.

### MEMORY.md Index Budget (hard constraint)

`MEMORY.md` loads into context every session, so it has a real size limit (around 24KB). Past that limit the loader cuts off the end and silently drops entries. Keep the index healthy:

- **One line per memory, with each line at most about 128 characters.** The detail goes in the topic file, which gets read on demand, never in the index line.
- **Assume not every write path is capped.** A propagation script may truncate lines when it appends, but a built-in memory tool that writes `MEMORY.md` directly skips that cap. Assume any index contains over-long lines, and enforce the limit with a separate compaction step.
- **Run a self-healing compaction step at session start.** It should be idempotent and non-destructive: it only trims index line text and never deletes a memory file. Have it and every appender take a file lock (for example `flock` on `MEMORY.md.lock`) so concurrent cron appends don't overwrite each other. Give it a `--check` mode that reports size and longest line and exits non-zero when the index is over the hard limit. If the hook only heals the current project's index, another project's over-budget index stays hidden during your sessions. Run the check across all indexes now and then.
- **An over-long line triggers compaction on its own, whatever the file size.** If compaction only runs after the index passes a soft size limit, an index below that limit collects uncapped lines forever and never gets cleaned up.
- **When compaction warns that the index is still over budget,** trimming isn't enough, so prune. Delete or merge memories that are (a) redundant with an always-loaded rule, (b) marked superseded or stale, or (c) duplicates. A memory that repeats an always-loaded rule adds nothing, because the rule is already in context every session. Move such memories to `memory/archived/`, which can be undone, rather than leaving orphaned index lines.
- **Automate pruning only for project and reference memories.** A daily job can demote `project_`/`reference_` entries that have zero reads across session transcripts (after a grace period of about 14 days since they were last modified) into a lazy tier that recall can still search. The files stay on disk and a pointer line in `MEMORY.md` names the tier. Do NOT auto-prune feedback, rule or pattern memories. They work by being in context, so a zero read count tells you nothing about their value, and pruning them needs a manual judgement call.

### Common Mistakes to Avoid

- **Updating only memory:** writing a memory file and stopping there. Other agents, and sessions that don't share your memory directory, can't see it. When the user says "update guidance", they mean the durable instruction system.
- **Skipping the knowledge base:** if the topic already has a knowledge base article, update it along with the guidance file.
- **Creating a new file when one already covers the topic:** always check the manifest and search `guidance/` first.

### Trigger Keywords

Treat any of these as a directive to update repo files:
- "update guidance" / "add to guidance" / "record this into guidance"
- "save this direction" / "save this rule"
- "remember this for all sessions" / "make this permanent"
- "add this to the rules" / "update the rules"
- Any correction plus "make sure this doesn't happen again"

## What NOT to Capture

- One-off debugging steps (git history already has them)
- Code patterns anyone can see by reading the code
- Task-specific context that won't come up again
- Anything the destination file already documents

## A backtick inside a double-quoted shell argument is command substitution

If a propagation script takes `--body` as a normal shell argument, markdown with a backticked code span inside double quotes gets run as command substitution. The span disappears, stderr shows something like "command not found", and the empty result is written to every destination. The script still exits 0 and reports success, so you can only spot the damage by reading the written file.

This hits hardest on the learnings most worth saving: the ones that name a literal config key, flag or sentinel. The sentence loses the identifier it was written to name and still reads as complete.

To avoid it, build the body with a quoted heredoc, which does no substitution at all:

```bash
BODY=$(cat <<'EOF'
... markdown with backticks, $vars and "quotes" all literal ...
EOF
)
./scripts/propagate-learning.sh --type pattern --summary "..." --body "$BODY"
```

The heredoc delimiter must be quoted. If you can't use a heredoc, write code spans in the body with double quotes instead of backticks. Either way, **read back one destination file after propagating**. The exit code doesn't tell you whether the text survived.
