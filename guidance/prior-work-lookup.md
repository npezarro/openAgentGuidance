<!-- Load when: finding past conversations and prior work -->
# Prior Work Lookup: Where to Search for Past Conversations

When a user says "we did this before" or "our previous work on X", search these sources in order.

## 0. Local Session Recall Index (fastest for conversational content)

If you maintain a local full-text + semantic index over past session transcripts, search it first. This is the right place to look when the prior work was a *conversation* (a decision, a debugging arc, an exact command) rather than a committed file.

```bash
recall "token refresh 401"                          # keyword: error strings, commands, names
recall "static asset drift" --project <name> --since 2026-06-01
recall --semantic "why did we abandon the local worker bridge"   # meaning-based questions
recall show <session-id>:<line>                     # expand a hit with surrounding context
```

Two caveats:

- Session bodies may contain unscrubbed detail. Do not paste raw index output into external surfaces without re-scrubbing.
- The index only covers sessions that ran on the machine holding it. Sessions from other hosts need sources 1-6.

Re-run your reindex step if the index looks stale.

## 1. Git History (fastest, most reliable)

```bash
git log --all --oneline --grep="<keyword>"     # in the relevant repo
git log --all --oneline -- <file>              # specific file changes
git stash list                                 # uncommitted work
```

Check all branches, including stale and WIP ones.

## 2. Closeout Reports

- A per-session closeout directory (for example `deliverables/closeouts/` in your private context repo) holds markdown summaries of what was done, what was decided, and what remains.
- If you publish session writeups to a blog or knowledge base, search that too.

Closeouts are worth keeping even with a recall index: they add human-readable synthesis the raw transcript lacks, and they cover the cross-machine gap.

## 3. Chat / Notification Channel History

If session activity is mirrored to a chat platform, its message history is the cross-machine backstop. Pull recent messages via the platform's API and filter locally:

```bash
curl -s -H "Authorization: Bot $BOT_TOKEN" \
  "https://<chat-api>/channels/<CHANNEL_ID>/messages?limit=100" | \
  python3 -c "
import json, sys
for m in json.load(sys.stdin):
    if '<keyword>' in m.get('content','').lower():
        print(f'{m[\"timestamp\"][:16]} | {m[\"content\"][:300]}')
"
```

Paginate backward with the API's `before=<message-id>` parameter. Keep tokens and channel IDs in your private context repo, never inline in commands you commit.

## 4. GitHub PRs, Issues, and Commits

```bash
gh search prs "<keyword>" --owner <you> --limit 20
gh search issues "<keyword>" --owner <you> --limit 20
gh search commits "<keyword>" --owner <you> --limit 20
```

## 5. Context / Progress Files

- `context.md` and `progress.md` in each repo: handoff notes between sessions.
- Your private context repo's deliverables directory for broader outputs.

## 6. Memory

- The agent memory directory under your Claude config (`~/.claude/projects/<project-slug>/memory/`).
- Check existing memory files for project context before concluding nothing exists.

## 7. Usage Mining: "is this file/rule/tool actually being used?"

Session logs answer *whether a reference file has ever been loaded*, which is the only honest basis for pruning an always-loaded index (a global rules file, an essentials file, a memory index, a skill roster). Count real tool invocations, not text matches:

```bash
cd ~/.claude/projects
grep -rhoE '"file_path":"[^"]*guidance/[a-z0-9-]*\.md"' . --include=*.jsonl \
  | grep -oE '[a-z0-9-]*\.md' | sort | uniq -c | sort -rn
```

Two traps, both of which produce a confident wrong answer:

- **The index contaminates its own measurement.** A bare `grep -rl "guidance/foo.md"` matches the session-start injection of the file that *lists* `foo.md`, so every entry scores about one hit per session and the data looks uniformly hot. Anchor on `"file_path"` (the Read tool) and check shell reads separately (`cat`/`head`/`sed`/`grep` inside `"command"`), or you are measuring the index, not usage.
- **Read count is confounded by age.** A file added last week cannot have 4,000 sessions of history. Check when it was added before reading a low count as "cold".

A zero-read file is not automatically dead weight. Distinguish:

1. *Superseded*: a skill or a project rules file now owns the function, so the pointer is redundant.
2. *Failed pointer*: the "load when" description never matches real tasks, so fix the description rather than delete the file.
3. Genuinely cold.

Cross-check against skill references (`grep -rho 'guidance/[a-z0-9-]*\.md' <your-skills-repo>`) before cutting: a file that skills route to is reachable even with no index entry.

Prefer demoting to deleting. Keep a `COLD` set in your index generator that drops a file out of the loaded index (so it stops consuming session-start context) while leaving it on disk and listed in a full manifest. Reversible in one line; deletion is not.

## Gaps in Coverage

- A local recall index captures conversation history verbatim even when a session produced no commit, closeout, or chat post, as long as the session ran on that host and the index is current.
- Sessions that ran only on a remote VM or another machine are not in the local index. A chat mirror is the cross-machine backstop, but it only captures logged turns. For those, rely on closeouts, commits, and chat posts.

## Routing Rule: Personal or Sensitive Research Output

Research about people, companies, recruiters, or interviews inherently carries the identifiers a secret-scan pre-commit hook exists to catch: personal email addresses, social handles, resume header blocks, individual names, and applicant-tracking req ids. If you route that output into a repo that can go public, the commit will be blocked. This is not an occasional collision, it is the nature of the content, so it happens every time.

The failure surfaces at the worst moment: after the deliverable is written, under time pressure, when the only fast-looking options are `--no-verify` or abandoning the file.

**Why:** A repo that may be published is scanned on that assumption. Your private context repo is the one allowed to hold personal detail; a dated subdirectory there (for example `deliverables/<topic>/<YYYY-MM-DD>-<slug>.md`) is the correct home.

**How to apply:** When spawning a subagent to research a person, role, company, or interview, name the private output path explicitly IN THE PROMPT. Do not let it default to a publishable repo. If a file is already stranded in the wrong repo, `git mv` it rather than bypassing the hook. Never reach for `--no-verify` to clear this gate: the gate is correct, the routing is what is wrong.

## Rule: "Like We Did for X" Means X's Actual File Set

When a request cites a prior deliverable ("structure it like we did for X"), the reference is X's *file set*, not just X's headings. A prior pack may hold eight or more documents (intel brief, strategy doc, playbook, prompt bank, story bank, template); reproducing only the hub document's headings misses the deliverable.

Rules that follow:

- Before writing, `ls` the referenced folder and diff your planned deliverables against it. Do this first, not after a draft exists.
- A "reading resources" deliverable means in-line digests: fetch each source, quote the figures, give one take-line each. Never a bare link list; the reader may be on a phone in transit.
- Every review pass starts with a completeness diff against the best prior pack. Verifying facts in what you wrote is not review if the set itself is short.
- A skill's documented "typical set" lags the best prior instance until someone writes it back. When an output exceeds the skill's floor, update the skill's deliverable list and quality gate in the same session.
