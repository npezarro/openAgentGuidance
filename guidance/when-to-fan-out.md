<!-- Load when: when to spawn subagents (Task fan-out / parallel bash / Workflow) vs stay single-agent; concurrency-safe 3-phase pattern -->
# When to Fan Out into Subagents

This covers when autonomous loops and interactive sessions should spawn subagents (the Task tool, parallel `claude -p`, or Workflow) and when they should stay single-agent. The default is single-agent. Fan out only when the structure of the task actually benefits from it.

## The three primitives, and where each applies

1. **In-session Task fan-out.** One `claude -p` session spawns subagents through the Task tool. This works in headless `--dangerously-skip-permissions` sessions. Give the Task tool an INLINE role description. In headless mode, don't count on a custom agentType name resolving. This is the only fan-out a cron `claude -p` loop has.
2. **Bash-level parallelism.** Use `&` with a `wait -n` throttle, or `xargs -P`. It fits a loop that calls `claude -p` (or any subprocess) once per independent item. It works from cron and needs no SDK.
3. **Workflow tool.** Deterministic multi-agent orchestration: fan-out, pipeline, adversarial verify, synthesize. It runs inside an interactive or SDK session, NOT a bare cron `claude -p`. Use it for heavy interactive work such as deep review, multi-source research, or migrations.

## Fan out when

- **An independent claim needs an independent check.** Before a loop reports "fixed", "passing" or "works" (especially a loop that self-merges or deploys), spawn a verifier subagent. It should RE-RUN the falsifying command and try to refute the claim. This enforces "verify before asserting" and "test before reporting". A skeptic with fresh context catches what the author talked themselves into.
- **N truly independent items are being processed one at a time.** For example, a `for item in list; do claude -p ...; done` over items that don't depend on each other: per-PR reviews, per-document drafts, per-channel analysis, per-repo audits. Run the expensive calls in parallel. Keep writes to shared state serial.
- **A finding touches 3+ repos, architecture, or security.** Spawn a deep-analysis subagent to trace the full chain of impact before acting.
- **A decision benefits from several perspectives.** Run architect, reviewer, QA and security specialists in parallel on the same artifact, then combine their output.

## Stay single-agent when

- The task touches a handful of files in one context.
- The work needs sequential discovery before it can be split up.
- There are few items and each call is cheap, so fan-out overhead costs more than it saves.
- A deterministic check already exists. A real `npm run build` gate beats an LLM verifier for build and test results. Save the verifier for correctness the build can't prove: root cause, logic, symptom-silencing.

## Concurrency safety (mandatory)

Parallel agents must never share non-atomic state. Some steps must stay SERIAL: writing a JSON state file through a jq read-modify-write, and irreversible mutations (`gh pr close/ready/merge`, deploys). The safe shape has three phases:

1. **Gate (serial):** decide which items proceed. Cheap, idempotent mutations are fine here.
2. **Work (parallel):** run the expensive, read-only calls. Each result goes to its own file. No writes to shared state.
3. **Apply (serial):** read the results in order. Do all mutations and state writes here.

**Give each agent its own scratch subdirectory in the brief** (e.g. `<scratch>/<batch>/`). Agents independently write helper scripts with the same obvious names (`pub.sh`, `verify.py`). In a shared scratch root they overwrite each other mid-run, and the output silently comes out wrong.

## Node.js subprocess parallelism gotcha: `execSync` blocks

To run `claude -p` calls in parallel from Node.js, use **non-blocking `spawn`**, not `execSync`. `execSync` is synchronous: it blocks the event loop until the subprocess exits. Wrapping it in `Promise.all` gives NO real parallelism. The calls still run one after another, even though the code looks async.

**Wrong (serial despite Promise.all):**
```js
function callClaude(item) {
  return execSync(`claude -p "${prompt}"`, { encoding: 'utf8' })  // blocks event loop
}
await Promise.all(items.map(callClaude))  // still serial
```

**Right (actually parallel):**
```js
function callClaude(item, prompt) {
  return new Promise((resolve, reject) => {
    let output = ''
    const proc = spawn('claude', ['--print'], { stdio: ['pipe', 'pipe', 'inherit'] })
    proc.stdin.write(prompt); proc.stdin.end()
    proc.stdout.on('data', d => { output += d })
    proc.on('close', code => code === 0 ? resolve(output) : reject(new Error(`exit ${code}`)))
    proc.on('error', reject)
    setTimeout(() => { proc.kill('SIGTERM') }, 120_000)  // safety timeout
  })
}
await Promise.all(items.map(item => callClaude(item, buildPrompt(item))))  // actually parallel
```

In Python, use `concurrent.futures.ThreadPoolExecutor` with a bounded pool (env `*_CONCURRENCY`, default 3):
```python
from concurrent.futures import ThreadPoolExecutor
with ThreadPoolExecutor(max_workers=concurrency) as pool:
    results = list(pool.map(process_item, items))
```

After collecting results, do all shared-state writes (JSON files, DB, counters) on the main thread, in the original order.

## Cost discipline

Fan-out multiplies token spend. Put every autonomous fan-out behind a usage check that aborts above a threshold (e.g. a script that exits non-zero at 75% of your plan's usage window). Log every coverage cap (top-N, no-retry) so that silent truncation never looks like full coverage.

## When fanning out to TEST TECHNIQUES, demand a negative control

A fan-out that asks "which of these N approaches works?" produces confident successes that are easy to misread. Two requirements turn it into evidence:

1. **Every claimed success gets an adversarial re-run.** An agent told to *refute* it tries again from scratch, using only the reported reproduction command. If it can't reproduce the result, the default verdict is REFUTED.
2. **Require a negative control in the agent's brief.** Ask outright: *what is the cheapest change that should NOT work, and does it in fact fail?* Without that you learn "X worked" but not "X worked *because of Y*", and only the second lets you build on it. A skipped control can hide the real mechanism: a change that looked like the fix may produce byte-identical output to the baseline, while a different variable was doing the work. Without the control you end up with a working trick, no model of why, and the wrong abstraction built on top.

Warn agents explicitly against two failure modes:

- **Fabricated test fixtures.** An invented ID or URL returns a real 404, which reads as "blocked" and sends the investigation down a false path. Control inputs must come from the real data source (the production DB, a sitemap), never from memory or typing.
- **Self-inflicted rate limiting.** Hammering a target during testing makes a working technique look like a failure. Tell agents to pace their requests and to re-test after a cooldown before calling something impossible.

## Persist what agents return

A subagent's report exists in exactly one place: the tool result in your context. If you boil it down into a smaller deliverable and the raw report only goes out in your chat response, **the detail is gone** when the turn ends. Chat is not storage. You can't grep it, diff it or link to it, and a long response can be truncated in the live view.

- **Write each substantial subagent report to a file in the same turn**, alongside (not instead of) any synthesis you produce.
- **One file per agent when they cover parallel items**, plus a `README.md` index. Don't merge N reports into one file and lose the per-item structure the fan-out gave you.
- **Commit the source too** when the work cites one (transcript, dataset, page dump, query output). It is usually small compared to its value, and it keeps every quoted claim re-checkable with `grep` instead of taking the summary on trust.
- **Verify delegated claims before publishing.** Ask for verbatim quotes with locators (timestamps, line numbers, file paths) in the agent's brief, then spot-check the important ones yourself. Re-run zero-counts ("term X never appears") directly. They are the easiest claim for an agent to get wrong and the most damaging to assert.

## Verify in an isolated git worktree when another session is mid-edit in the same checkout

When several sessions share one working tree, a repo-wide `npx tsc --noEmit` or `npm run build` can fail on files you never touched. If you take that at face value, you either report a broken build that isn't yours or commit someone else's work in progress.

Procedure when `git status` shows modified or untracked files you didn't create:

1. Attribute the errors first: `npx tsc --noEmit 2>&1 | grep -c <your-file>`. Zero hits means the failure isn't yours.
2. Verify in isolation: `git worktree add -b <branch> ../wt-<repo> origin/<default-branch>`, copy in only your file(s), then run tsc and the build there.
3. `node_modules` in the worktree must be a hardlink copy (`cp -al ../repo/node_modules node_modules`, which takes about a second), NOT a symlink. Some bundlers (Turbopack, for one) reject a symlinked `node_modules` that points outside the project root and die before compiling anything. The worktree must be on the same filesystem as the source for `cp -al` to work.
4. Commit from the worktree, push, open the PR, then `git worktree remove --force` and `git branch -D`.
5. Afterwards, revert your leftover edits in the shared checkout (`git checkout -- <files>`). Otherwise the other session's `git add -A` can sweep a duplicate of your merged change into its commit.

Also, do NOT deploy from a shared checkout in this state. A deploy that builds from the local tree will ship the other session's unfinished work.

## Long research deliverables: write incrementally, return short

A subagent that saves its whole deliverable for one final Write (or one huge final message) can hit the per-response output-token cap and die having written nothing. All of its research is lost, and a dead agent leaves no transcript the parent can cheaply recover.

- Tell research subagents to **create the output file early with a skeleton, then append one section per Write/Edit call**.
- Keep the subagent's final return message short (under ~300 words). The return value is not the deliverable.
- Check that the file exists before relying on it.
- Plan for relaunching: a usage gate may block respawning, so one lost agent can become a gap you can't recover mid-session. Prefer several narrowly scoped agents over one broad one.

## Do NOT infer subagent liveness from its transcript file

No cheap filesystem signal tells you whether a subagent is still alive. File size readings can contradict each other at the same moment. Mtime can stay frozen for 10+ minutes while an agent is busy inside a long tool call. A queued message that hasn't been delivered doesn't mean the agent is dead either, because it gets delivered at the agent's next tool round. The authoritative signal is the harness task notification, which always arrives. Wait for it.

When a subagent's output is overdue:

- Wait. Arm a background `until [ -f <deliverable> ]; do sleep 10; done` watcher and keep working on independent tasks. Don't poll in the foreground.
- Do NOT read a large agent transcript to investigate. It will overflow the parent's context.
- Do NOT write the expected deliverable path yourself as a "status record" while the agent may still be running. It races the real agent, which then overwrites your file, and any watcher on that path fires on YOUR write, which is easy to mistake for the report arriving.
- Never let a missing verdict quietly become an implied one, and never declare an agent dead unless the harness says so.

## An unreturned verifier is a third outcome: "no verdict"

A verifier that never returns is neither "confirmed" nor "refuted", and you need a response planned in advance. The two opposite failures are: (a) announcing that the verifier stalled, and then it returns a minute later; (b) blocking the session for an hour waiting on a notification that never comes.

**Do not publish anything about a subagent's status until it has reported.** Careful hedging ("no verdict has arrived yet") still puts a false impression in front of a reviewer when the verdict lands shortly after, and then you have to retract it in public. Say nothing, or "verification pending".

Make the wait cheap by construction, so that a slow or missing agent costs only time:

1. **Commit before spawning the verifier.** Then the shared worktree can't produce a bad commit if the agent leaves half-reverted edits behind.
2. **Run the authoritative test and build from a second worktree pinned to the pushed commit** (`git worktree add /tmp/<n> --detach <branch>`). Evidence gathered there is unaffected by whatever the verifier does to the shared tree.
3. **At the end, re-check** that HEAD is unchanged, the tree is clean, and the fix is still present (`git show HEAD:<file>`).

Give the verifier an explicit time budget. Once it runs out, proceed with evidence you gathered yourself, labelled as such. A PR shipped with honest provenance ("no independent verdict exists; here is my own reproducible evidence") beats both a blocked session and an unlabelled hint that review happened.

## Lessons verifiers tend to surface

- **Comparing an error's size to a threshold's size is a margin fallacy.** When a sharp cutoff (e.g. `>= 5`) is applied to rounded integers, 1 unit of contamination is exactly enough to cross it. The question isn't "is the error small next to the threshold", it's "does the error move the value ACROSS the threshold". Test by replaying real history through both versions and diffing which branch each one takes, not just the values.
- **Fixing one instance of a defect class means auditing every sibling instance.** Hardening one field against a trap while its twin keeps the same flaw is a half-fix.
- **Analysing only "clean" windows silently drops real production cases.** Restricting to full-length windows can exclude real outputs and understate how big the bug is.
- **A test can be named for a property it doesn't test.** An "invariant to X" fixture built on uniform input can pass for any implementation. Pin a choice with a fixture where the alternatives truly disagree, and confirm every new assertion FAILS against the pre-fix code.
- **Check verifier corrections too.** For example, `-0 === 0` is true, but `assert.strictEqual` uses `Object.is`, where `Object.is(-0, 0)` is false. A "no-op" normalisation can be what keeps a test suite passing.

## Brief a verifier with the same preconditions the artifact states

A verifier given the branch and the claim, but NOT the precondition the claim depends on, will test the unconditional version, find it false, and return a confident REFUTED wrapped around several correct minor findings. Example: the PR says its fix only becomes reachable once another open PR merges, but the verifier tests against the base alone and reports the documented caveat as a fatal flaw.

- Put the preconditions IN the verifier prompt, not just in the artifact: which other branches are assumed merged, which env or flags, which build. "Verify commit X" is underspecified whenever X's correctness is conditional.
- State the environment your own evidence came from, so a mismatch shows up as a disagreement about setup rather than about the claim.
- When a verdict comes back REFUTED, first check whether it tested the same configuration you did. If it didn't, the verdict is about a different artifact.
- A wrong headline verdict does not justify throwing out the details. Triage the sub-findings one by one. Loose prose that your own evidence contradicts ("A and B both fire" for two branches that can't both run, "only a reload fixes it" when something else also does) is a real finding.

## Research subagents must not delegate

A subagent given a research prompt may spawn its own subagent and return "I've launched an agent, I'll report back" as its final answer. A subagent's final message is its return value, so that answer is a null result that cost a full agent's runtime. The orphaned child can't be cancelled from the parent and keeps writing to the same output path, overwriting whatever lands there later (last writer wins, no error).

- Tell research subagents explicitly: "do NOT spawn subagents; do the searching yourself; return the actual findings."
- If you resume a delegating agent, give the resumed run a DIFFERENT output path. Otherwise, re-read the file afterwards and grep for a marker unique to each version before trusting it.
- Treat "I'll report back" in a final message as a failed agent, not a partial one.
- In single-turn headless sessions, blocking on a delegating parent returns only its non-answer. The grandchildren may still finish and show up as separate top-level task notifications. Watch for those before synthesizing, instead of writing the whole branch off as failed.

## Mid-run redirects land late

A message sent to a running subagent is queued and delivered at its next tool round. A redirect that changes an output path may arrive after the agent has already written the file.

- Get output paths right in the spawn prompt. List the destination directory FIRST, including files other sessions added recently, so you don't collide with existing names.
- If a mid-run rename can't be avoided, plan to `mv` the file afterwards and `sed` its self-references and H1, then re-check any docs that cite the old name.
- Content redirects (add a source, skip a section) are more likely to land because they affect later steps. Send those early and keep them short.

## Fan-out prompts carry the hard rules verbatim; assert coverage before reporting

Subagents don't inherit a skill or ruleset that the orchestrator has loaded. If the orchestrator knows a rule (e.g. "always wrap OR terms in braces or parentheses in search queries", "fetch the full thread before concluding a negative") and the subagents never see it, they write queries that silently exclude real matches and report false negatives. As an example of that failure, many search engines parse `a OR b c` as `(a OR b) AND c`.

1. **Paste the skill's hard rules into every fan-out prompt.** Don't assume they carry over.
2. **Define the population up front** (e.g. every row where Active=Y), print its size, and don't report until every member has appeared exactly once in the results. A target list built by hand with no count check will miss items.
3. **When sweeping for outcomes in email or notifications, query by sender and entity name**, not by a phrase you expect in the body. Automated messages rarely repeat the exact title or wording you're searching for.
