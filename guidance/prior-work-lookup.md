<!-- Load when: finding past conversations and prior work -->
# Prior Work Lookup: Where to Search for Past Conversations

When a user says "we did this before" or "our previous work on X", search these sources in order:

## 0. Local Session Recall Index (fastest for conversational content)

If you maintain a local full-text plus semantic index over past agent sessions, this is the first place to look when the prior work was a *conversation* (a decision, a debugging arc, an exact command) rather than a committed file. A typical interface:

```bash
recall "auth token refresh 401"                    # keyword: error strings, commands, names
recall "static asset drift" --project <name> --since 2026-06-01
recall --semantic "why did we abandon the local worker bridge"   # meaning-based questions
recall show <session-id>:<line>                    # expand a hit with surrounding context
```

Session bodies may contain secrets or personal data; scrub before pasting index output into any external surface. Reindex if the index looks stale.

Note that such an index is per-machine: sessions that ran on a different host are not in it. Use sources 1-6 for those.

## 1. Git History (fastest, most reliable)
- `git log --all --oneline --grep="<keyword>"` in the relevant repo
- `git log --all --oneline -- <file>` for specific file changes
- Check all branches including stale/WIP ones
- Check `git stash list` for uncommitted work

## 2. Closeout Reports
- Per-session closeout markdown files, if your workflow writes them (e.g. `<private-context-repo>/deliverables/closeouts/`)
- Any long-form write-ups published to your knowledge base or blog
- Closeouts contain detailed summaries of what was done, decisions made, and what's left

## 3. Chat / Notification Channel History

If your agent posts to a notification channel, that channel is a searchable log of past work. Fetch recent messages via the platform's API and filter by keyword, paginating backward through history with the platform's `before`/cursor parameter. Keep the API token in your private context repo, never inline in a command you commit.

## 4. GitHub PRs and Issues
```bash
gh search prs "<keyword>" --owner <you> --limit 20
gh search issues "<keyword>" --owner <you> --limit 20
gh search commits "<keyword>" --owner <you> --limit 20
```

## 5. Context/Progress Files
- `context.md` and `progress.md` in each repo: handoff notes between sessions
- Any broader deliverables directory in your private context repo

## 6. Memory
- The agent memory directory for the project (`memory/` under the project's session state)
- Check existing memory files for project context

## 7. Usage Mining: "is this file/rule/tool actually being used?"

Session logs answer *whether a reference file has ever been loaded*, which is the only honest basis for pruning an always-loaded index (a core rules file, a memory index, a skill roster). Count real tool invocations, not text matches:

```bash
cd <session-logs-dir>
grep -rhoE '"file_path":"[^"]*guidance/[a-z0-9-]*\.md"' . --include=*.jsonl \
  | grep -oE '[a-z0-9-]*\.md' | sort | uniq -c | sort -rn
```

Two traps, both of which produce a confident wrong answer:

- **The index contaminates its own measurement.** A bare `grep -rl "guidance/foo.md"` matches the session-start injection of the file that *lists* `foo.md`, so every entry scores ~1 hit per session and the data looks uniformly hot. Anchor on `"file_path"` (the Read tool) and check bash reads separately (`cat`/`head`/`sed`/`grep` inside `"command"`), or you are measuring the index, not usage.
- **Read count is confounded by age.** A file added last week cannot have thousands of sessions of history. Check when it was added before reading a low count as "cold".

A zero-read file is not automatically dead weight. Distinguish (a) *superseded*: a skill or project instruction file now owns the function, so the pointer is redundant; (b) *failed pointer*, the "load when" description never matches real tasks, so fix the description rather than delete the file; (c) genuinely cold. Cross-check against skill references (`grep -rho 'guidance/[a-z0-9-]*\.md' <skills-repo>`) before cutting: a file skills route to is reachable even with no index entry.

Prefer demoting to deleting. A generated manifest can carry a `COLD` set that drops a file out of the loaded index (so it stops consuming session-start context) while leaving it on disk and listed in the full manifest. Reversible in one line; deletion is not.

## Gaps
- A local recall index captures conversation history verbatim even when a session produced no commit, closeout, or chat post, as long as the session ran on that host and the index is current.
- Remaining gap: sessions that ran only on a remote VM or another machine. A chat channel that mirrors CLI turns is the cross-machine backstop, but it only captures logged turns. For those, rely on closeouts, commits, and chat posts.
- Closeouts remain valuable for substantive work: they add human-readable synthesis the raw index lacks, and they cover the cross-machine gap.

### Route personal research output to your private context repo, not to a scannable public repo

A subagent told to write a job, recruiter, or interview research report into a repo that can go public will have that commit BLOCKED by the secret-scan pre-commit hook, because this content inherently carries the identifiers the hook exists to catch: personal email, social handles, resume header blocks, recruiter and hiring-manager names, and applicant-tracking req ids. This is not an occasional collision, it is the nature of the content, so it happens every time.

The failure surfaces at the worst moment: after the deliverable is written, often under time pressure, when the only fast options look like `--no-verify` or abandoning the file.

**Why:** A public-eligible repo is scanned on that assumption. Your private context repo is the one allowed to hold personal detail, and a dated `deliverables/job-search/` directory is the established home (`<YYYY-MM-DD>-<slug>.md`). The private repo scans too, but only blocks raw contact blocks, which generalise away without losing meaning.

**How to apply:** When spawning a subagent to research a role, company, recruiter, or interview, name the output path as `<private-context-repo>/deliverables/job-search/<YYYY-MM-DD>-<slug>.md` IN THE PROMPT. Do not let it default to a public-eligible repo. If a file is already stranded in the wrong repo, `git mv` it rather than bypassing the hook. Never reach for `--no-verify` to clear this gate: the gate is correct and the routing is what is wrong.
