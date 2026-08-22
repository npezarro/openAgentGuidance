<!-- Load when: finding past conversations and prior work -->
# Prior Work Lookup: Where to Search for Past Conversations

When someone says "we did this before" or "our previous work on X", search these sources in order.

## 0. Session Recall Index (fastest for conversational content, if you have one)

If you maintain a local full-text + semantic index of past Claude Code sessions, that is the first
place to look when the prior work was a *conversation* (a decision, a debugging arc, an exact
command) rather than a committed file. A typical interface:

```bash
R=~/repos/session-recall/recall
$R "token refresh 401"                        # keyword: error strings, commands, names
$R "static asset drift" --project <name> --since 2026-06-01
$R --semantic "why did we abandon the local worker bridge"   # meaning-based questions
$R show <session-id>:<line>                   # expand a hit with surrounding context
```

Two caveats that matter:

- Session bodies may contain secrets or personal data. Scrub before pasting index output into any
  external surface, even if the index itself is scrubbed on ingest.
- The index only covers machines it runs on. Sessions from another host are invisible to it; use
  sources 1-6 for those.

Re-run your reindex script if results look stale.

## 1. Git History (fastest, most reliable)

- `git log --all --oneline --grep="<keyword>"` in the relevant repo
- `git log --all --oneline -- <file>` for specific file changes
- Check all branches, including stale and WIP ones
- Check `git stash list` for uncommitted work

## 2. Closeout Reports

- Per-session closeout markdown files, if your workflow writes them (e.g.
  `<private-context-repo>/deliverables/closeouts/`)
- Any published write-ups (blog, internal site) that mirror those closeouts
- Closeouts contain detailed summaries of what was done, decisions made, and what is left

## 3. Notification Channel History

If session summaries are posted to a chat platform, that channel is a searchable log. Keep the bot
token and channel IDs in your private context repo, never inline in guidance.

General pattern: fetch the token from your credential store, then page backward through the
channel's message history via its API and filter client-side:

```bash
# token and channel ID come from your private context repo
curl -s -H "Authorization: Bot $BOT_TOKEN" \
  "https://<chat-api-host>/api/v10/channels/<CHANNEL_ID>/messages?limit=100" | \
  python3 -c "
import json, sys
msgs = json.load(sys.stdin)
for m in msgs:
    if '<keyword>' in m.get('content','').lower():
        print(f'{m[\"timestamp\"][:16]} | {m[\"content\"][:300]}')
"
```

Use the API's `before=<message_id>` parameter to paginate backward through history.

## 4. GitHub PRs and Issues

```bash
gh search prs "<keyword>" --owner <your-org-or-user> --limit 20
gh search issues "<keyword>" --owner <your-org-or-user> --limit 20
gh search commits "<keyword>" --owner <your-org-or-user> --limit 20
```

## 5. Context/Progress Files

- `context.md` and `progress.md` in each repo: handoff notes between sessions
- Broader deliverables directories in your private context repo

## 6. Memory

- The agent memory directory for this project (under `~/.claude/projects/<project-slug>/memory/`)
- Check existing memory files for project context

## 7. Usage Mining: "is this file/rule/tool actually being used?"

Session logs answer *whether a reference file has ever been loaded*, which is the only honest basis
for pruning an always-loaded index (a root agent rules file, an essentials file, a memory index, a
skill roster). Count real tool invocations, not text matches:

```bash
cd ~/.claude/projects
grep -rhoE '"file_path":"[^"]*guidance/[a-z0-9-]*\.md"' . --include=*.jsonl \
  | grep -oE '[a-z0-9-]*\.md' | sort | uniq -c | sort -rn
```

Two traps, both of which produce a confident wrong answer:

- **The index contaminates its own measurement.** A bare `grep -rl "guidance/foo.md"` matches the
  SessionStart injection of the file that *lists* `foo.md`, so every entry scores ~1 hit per session
  and the data looks uniformly hot. Anchor on `"file_path"` (the Read tool) and check bash reads
  separately (`cat`/`head`/`sed`/`grep` inside `"command"`), or you are measuring the index, not usage.
- **Read count is confounded by age.** A file added last week cannot have 4,000 sessions of history.
  Check when it was added before reading a low count as "cold".

A zero-read file is not automatically dead weight. Distinguish (a) *superseded*: a skill or a root
rules file now owns the function, so the pointer is redundant; (b) *failed pointer*: the "load when"
description never matches real tasks, so fix the description rather than delete the file; (c)
genuinely cold. Cross-check against skill references (`grep -rho 'guidance/[a-z0-9-]*\.md'
<your-skills-repo>`) before cutting: a file skills route to is reachable even with no index entry.

Prefer demoting to deleting. A manifest generator with a `COLD` set can drop a file out of the
always-loaded index (so it stops consuming SessionStart context) while leaving it on disk and listed
in a manifest. Reversible in one line; deletion is not.

## Gaps

- A recall index captures conversation history verbatim even when a session produced no commit,
  closeout, or chat post: as long as the session ran on an indexed host and the index has been
  refreshed (run it on a schedule, e.g. hourly via cron).
- Remaining gap: sessions that ran only on another machine are not in the local index. A shared
  notification channel is the cross-machine backstop, but it only captures logged turns. For those,
  still rely on closeouts, commits, and chat posts.
- Closeouts remain valuable for substantive work: they add human-readable synthesis the raw index
  lacks, and they cover the cross-machine gap.
