<!-- Load when: when and where to persist operational learnings -->
# Learning Capture

Capture operational learnings, behavioral adjustments and discovered patterns **as soon as they happen**. Do not save them up for the end of the session.

## The Multi-Destination Rule

A learning can belong in up to four places. Check which ones apply every time:

| Destination | What Goes Here | Who Benefits |
|---|---|---|
| **Memory** (`~/.claude/projects/.../memory/`) | Personal recall across sessions | This user's future Claude sessions |
| **Project repo** (`CLAUDE.md`, `context.md`) | Rules and patterns for one repo | Any agent working in that repo |
| **This repo or your private context repo** | Patterns and operational knowledge that apply across projects | All agents, all repos, all sessions |
| **Your knowledge base** | Synthesized knowledge that spans 3 or more repos | Any agent that needs cross-cutting context |

This rule applies to interactive sessions as well as autonomous ones. If an automated scorer or review pass does not check a rule for some session type, that only means a different pass is responsible for catching the gap. It does not mean you can skip the behavior.

### Decision: this repo vs your private context repo

- **This repo** (may be published): behavioral rules, workflow patterns, techniques, prompt strategies and integration patterns. Nothing that reveals infrastructure, credentials or sensitive identifiers.
- **Your private context repo**: prompt templates that contain sensitive details, credential patterns, infrastructure-specific knowledge, and project-specific operational details that name internal systems.
- **When in doubt:** if it mentions a hostname, IP, username, API key or private repo name, it goes in your private context repo.

## What Counts as a Learning

- A behavior to repeat or avoid in future sessions
- A new capability, tool or integration pattern that has been set up
- A correction from the user, whether stated or implied
- A failure mode you found, along with its fix
- A prompt strategy or framing that gave better results
- An infrastructure detail that future sessions will need
- A change to an existing rule based on new evidence

## When to Capture

Capture it **immediately**, not at session end. In particular:

1. **User corrects you:** save the feedback before you continue with the corrected approach.
2. **New capability established:** once you have verified it works, record it before moving on.
3. **Pattern discovered:** once the pattern is confirmed, persist it.
4. **Integration wired up:** once it is tested, document the wiring.

Do NOT batch these up for session wrapup. By then the details are gone and the learning is less precise.

## How to Capture

### Preferred: a single propagation command

If your setup has a propagation script that writes to memory, the repo `CLAUDE.md` and a guidance file in one step, use it. Give it a type, a one-line summary, the full body, the target repo and the target guidance file. Use its dry-run mode first when one exists.

**Know whether your script appends or queues.** Some setups send guidance-file learnings to an inbox that no session loads, and a later consolidation pass merges them into the target file. In that case the lesson is saved right away but only reaches the loaded file on the next pass. If a session needs the rule in force now, edit the target file directly on a branch or worktree. Merge the lesson into an existing rule instead of adding a new dated section, and keep the file's net growth small.

**Watch for direct pushes to `main`.** A propagation script that runs `git commit && git push` inside a guidance repo will commit straight to `main` whenever `main` is checked out, which skips PR review. For guidance edits that should be reviewed, work in a worktree on a learnings branch. Direct pushes are fine for private destinations that have no review gate.

For complex or nuanced learnings, hand the routing decision, duplicate check and manifest lookup to a dedicated propagation subagent.

### Manual Capture (when a script doesn't fit)

#### Step 1: Save to memory (always)
Write a standard memory file with frontmatter.

#### Step 2: Pick the repo-level destination(s)

| Learning Type | Repo Destination | This repo / private context repo? |
|---|---|---|
| Repo-specific rule | That repo's `CLAUDE.md` | Only if it is a cross-project pattern |
| Workflow pattern | N/A | `guidance/<topic>.md` in this repo |
| Prompt template | N/A | `prompts/<name>.md` in your private context repo |
| Infrastructure detail | N/A | An infrastructure or accounts file in your private context repo |
| User preference/style | N/A | A voice/style guidance file in this repo |

#### Step 3: Commit and push
Push learnings to this repo or your private context repo right away. A learning that only exists locally does nothing for other sessions.

## Updating Existing Guidance

When a learning changes or extends an existing rule:
1. **Find the canonical source** in the repo's manifest or index.
2. **Edit it in place.** Do not create a new file when an existing one already covers the topic.
3. **Update the manifest** if you add a new guidance file.
4. **Update the core instruction file's guidance index** if you add a new guidance file.

## Responding to Mistakes

When you make a mistake and find its cause, do this before moving on:

1. **Check existing guidance.** Search the guidance directory and your private context repo for a rule that should have prevented it.
2. **If the rule exists:** work out why it wasn't followed. Maybe it is too narrow, or its trigger condition has a gap. Update the rule to close that gap.
3. **If no rule exists:** add one in the right place (this repo for lessons that apply across sessions, the repo's `CLAUDE.md` for lessons specific to that repo).
4. **Commit and push the rule update.** A rule that isn't pushed doesn't help future sessions.

**Why this matters:** when a rule exists but isn't followed, either the rule is unclear or its trigger is missing. Turn every failure into a better rule. Don't just fix the symptom; fix what should have prevented it.

## Explicit User Directives ("Update Guidance", "Record This")

When the user says **"update guidance"**, **"record this into guidance"**, **"save this direction"** or something similar, the main target is **always the repo instruction files**, not memory.

### Routing Order for User Directives

1. **Find the canonical source.** Check the manifest for the right file. If the directive maps to an existing guidance file, edit that file in place.
2. **Update the repo file(s).** Edit the relevant guidance file, your private context repo, or the project's `CLAUDE.md`, whichever fits.
3. **Update your knowledge base** if the change affects knowledge that spans repos (instruction architecture, integration patterns, or anything an existing article already covers).
4. **Commit and push right away.** Rule changes that aren't pushed don't help future sessions.
5. **Optionally save a memory file** as a personal index or cache. Memory is always supplementary and never the main destination.

### MEMORY.md Index Budget (hard constraint)

`MEMORY.md` is loaded into context every session, so it has a real size limit (roughly 24KB and 200 lines). Past that limit the loader cuts off the end and drops entries without warning. Keep it healthy:

- **One line per memory, with the whole line at about 128 characters or less.** Put the detail in the topic file, which is read on demand. Never put it in the index line.
- **Assume some write paths have no length cap.** A script that appends to the index may truncate lines, but the built-in memory tool writes `MEMORY.md` directly and skips any such cap. Treat every index as if it may contain over-long lines. Something that runs every session, such as a SessionStart hook that re-compacts over-long lines, is what actually enforces the limit.
- **Make compaction safe.** It should be idempotent and non-destructive: only trim the line text, never delete a memory file. Take a file lock on the index during compaction and appends so that concurrent writers (for example cron jobs) don't overwrite each other. Include a check mode that reports size and longest line and exits non-zero when the index is over the hard limit.
- **Know the scope of the healer.** A per-session hook usually fixes only the current project's index. Other projects' indexes can grow over budget without anyone seeing it, so run a fleet-wide check explicitly when you want the whole picture.
- **An over-long line should trigger compaction on its own, whatever the file size.** If compaction only runs after the index passes a soft size limit, an index under that limit collects uncapped lines forever. If an index "looks long" while still under budget, this is usually the reason.
- **If the index is still over budget after compaction, prune it.** Truncating lines is not enough. Delete or merge memories that (a) repeat a rule that is already always loaded, (b) are marked superseded or stale, or (c) duplicate another memory. A memory that repeats always-loaded guidance adds nothing to recall. Move these to `memory/archived/` (which can be undone) instead of leaving orphaned index lines.
- **Automate demotion only for reference-style memories.** It is reasonable to automatically move project and reference memories that have zero reads over a grace period (for example 14 days) into a lazy tier that can still be searched. Do NOT auto-prune feedback, rule or pattern memories. They work by being in context, so a zero read count says nothing about their value, and pruning them still needs manual judgement.

### Common Mistakes to Avoid

- **Updating only memory:** writing a memory file and stopping there. Other agents, and sessions that don't share your memory directory, can't see it. When the user says "update guidance", they mean the durable instruction system.
- **Skipping the knowledge base:** if the topic already has a knowledge base article, update it along with the guidance file.
- **Creating a new file when one already covers the topic:** always check the manifest and search the guidance directory first.

### Trigger Keywords

Treat any of these as an instruction to update repo files:
- "update guidance" / "add to guidance" / "record this into guidance"
- "save this direction" / "save this rule"
- "remember this for all sessions" / "make this permanent"
- "add this to the rules" / "update the rules"
- Any correction followed by "make sure this doesn't happen again"

## What NOT to Capture

- One-off debugging steps (they are already in git history)
- Code patterns you can see by reading the code
- Task-specific context that won't come up again
- Anything the destination file already documents

## Shell Quoting: backticks in a double-quoted body get executed

If a capture script takes the learning body as a normal shell argument, markdown with a backticked code span inside double quotes triggers command substitution. The span disappears, stderr shows something like `command not found`, and the empty result is written to every destination. The script still exits 0 and reports success, so you only see the damage by reading the written file.

This hits hardest on the learnings most worth saving, because those name a literal config key, flag or sentinel. The sentence loses the identifier it was written to name, yet it still reads as complete.

Avoid it with a heredoc whose delimiter is quoted. That form does no substitution at all:

```bash
BODY=$(cat <<'EOF'
... markdown with backticks, $vars and "quotes" all literal ...
EOF
)
your-capture-script --type pattern --summary "..." --body "$BODY"
```

If you can't do that, put double quotes around code spans in the body instead of backticks. Either way, **read back at least one destination file** after capturing. The exit code does not tell you whether the text survived.
