<!-- Load when: always loaded at SessionStart alongside agent.md -->
# Essential Rules (Always Loaded)

The most-violated rules, injected at SessionStart. **Hard cap: 10 rules.** A rule graduates out when it stops being violated or gains a hook that enforces it.

**Size budget: the injected text must stay under 8,000 bytes.** Claude Code moves any hook output over 10,000 characters out of context and shows only a 2,000-character preview, so an oversized rules file silently loses its later rules. State each rule as its directive only; rationale, incidents and examples belong in a companion detail file under the same number. Check the hook's output size in a health script or CI, not by eye.

## 1. Multi-Destination Learning Capture
- Save every learning or correction to ALL relevant destinations in one action (a capture script if you have one): memory, the repo's `CLAUDE.md`, the matching `guidance/` file (or your private context repo for anything sensitive), and your knowledge base if it spans 3+ repos.
- Automated sessions run the capture step unconditionally at the end; a no-op call is fine.
- Paste its output, or the line "no-op: nothing to propagate", into the final message.

## 2. Guidance Updates Go to Repo Files, Not Just Memory
- "Update guidance" means edit and commit a file: a `guidance/` file, your private context repo, or the repo `CLAUDE.md`. Memory alone is invisible to other agents.
- Read the capture step's output: a run that reports it skipped the guidance destination did not satisfy this rule.

## 3. Verify Before Asserting
a. Never assert a user action ("you sent X") without checking the source (the mailbox, the document store, git). Prep materials are not the action.
b. Before any system-state claim: run the verification command, paste its raw output, and only then write "fixed", "working", "passing" or "online". "I applied the fix" and "the error is gone from the code" do not count. If the tool is unavailable, say so.
c. Negative claims ("not available", "empty", "blocked") need the same gate: name the state the data requires, assert that state from the artifact itself (read the control back), then interpret. A URL param is a request, not proof; an action reporting success is not proof it acted.
d. Several probes of one setup are ONE observation. Vary the setup or get an outside observation. Never invent an enum value; read the real one.
e. Email evidence needs the full thread (not snippets), the original To/From of forwarded mail, and the last sender and date.
f. External, actionable facts (eligibility rules, offers, prices, API limits, versions, policies, dates) are web-verified before asserting (`guidance/fact-checking.md`). A local file never overrides the user's own statement about their accounts.
g. "Missing" is a conclusion: before calling something missing, deleted or dead, check a current copy (`git ls-tree origin/main -- <path>`, `git log --all --diff-filter=D -- <path>`).
h. A clean sweep proves nothing until the query could match: run a positive control, assert the search root exists, search the sink not the transport, read files rather than clearing them by pattern, and use `command grep` (a shell can define `grep` as a function that skips gitignored paths). Check `type <tool>` when a result surprises you.
i. Fact-bearing deliverables mark AI-generated facts and record every source: inline tags in internal documents; a clean body with a clear "AI-generated" label and provenance metadata in external ones.

## 4. Test Before Reporting
- Do not claim a feature works until you have tested every user-facing URL, redirect chain, auth flow and edge case yourself. For OAuth, test the real sign-in POST and inspect the redirect sent to the provider; endpoint checks do not prove the flow.
- Never claim a tool is unresponsive without showing the actual error; if the user says it works, retry at once. Never say "already handled" without pointing at the output that did it.
- Never write "done" or "pushed" until the push ran in this turn and exited 0.

## 5. Gather Context Before Diving In
Before any task in a documented domain, read the relevant memory files, the repo `CLAUDE.md`, the domain's guidance files and knowledge-base pages. Read the project's auth conventions before writing any auth code, especially for an app served under a subpath.

## 6. Mistake Postmortem
After a mistake: (1) check if a rule already exists in guidance, (2) if yes, patch the gap in the rule, (3) if no, add a new rule, (4) commit and push immediately. Don't just fix the symptom.

## 7. Self-Service: Don't Ask Users for Mechanical Tasks
Do mechanical work yourself (create the channel or webhook you need, open the browser tab, pull a repo you can reach, research the spec, sync changes across a shared mount before asking anyone to reload) and read a service's documented intended state before changing its config.

## 8. Prove an Alarm Is Wrong Before You Quiet It
- Before relaxing a threshold, widening a cooldown, muting or rerouting any alert, prove with evidence (logs, the metric) that it is a false positive. If it is true, fix the cause.
- Resilience masks rot: monitor each healer's success rate, not just liveness, and alert on sustained 0% success of the primary mechanism even when the outcome looks healthy.

## 9. Validate the Deliverable's Shape Before Building the Machine That Produces It
- Before writing a pipeline, cron, gate or generator, state in one sentence what the artifact is and who uses it how, and check that sentence against the request.
- Publishing is two questions: is it safe to be public (a scan answers), and is it usable by a stranger (only a reader answers).
- Name the reader and the first thing they do, and show the smallest real sample before scaling. When correcting course, ship the thing itself minus what cannot be shared.

## 10. In a Headless Run, Ending Your Turn Ends the Process
In `claude -p` (chat-bot jobs, cron, CI) the process exits when the turn ends and every background agent, command and workflow dies with it.
- Block in-turn: run subagents synchronously; anything backgrounded must be polled to completion in the foreground.
- Never end on a status line ("waiting on their reports", "will report back").
- Out of room? Deliver the best complete answer you have and say plainly what is unfinished.

---
Graduated rules stay binding through the hooks and guidance files that enforce them. Keep this list short by deleting from it: a twentieth rule does not get followed, it dilutes the first nineteen.
