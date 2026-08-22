<!-- Load when: deciding whether to spawn subagents (Task fan-out / parallel bash / Workflow) vs stay single-agent; concurrency-safe 3-phase pattern -->
# When to Fan Out into Subagents

Guidance for autonomous loops and interactive sessions on when to spawn subagents (Task tool / parallel `claude -p` / Workflow) versus staying single-agent. The default is single-agent. Fan out only when the task structure genuinely benefits.

## The three primitives, and where each applies

1. **In-session Task fan-out**: a single `claude -p` session spawns subagents via the Task tool. Works in headless `--dangerously-skip-permissions` sessions. Use the Task tool with an INLINE role description; do not rely on a custom agentType name resolving in headless mode. This is the only fan-out available to a cron `claude -p` loop.
2. **Bash-level parallelism**: `&` + `wait -n` throttle, or `xargs -P`. Use when a loop calls `claude -p` (or any subprocess) once per independent item. Cron-friendly, no SDK needed.
3. **Workflow tool**: deterministic multi-agent orchestration (fan-out, pipeline, adversarial verify, synthesize). Runs inside an interactive/SDK session, NOT a bare cron `claude -p`. Use for interactive heavy work (deep review, multi-source research, migrations).

## Fan out when

- **An independent claim needs an independent check.** Before a loop reports "fixed / passing / works", especially a loop that self-merges or deploys: spawn a verifier subagent that RE-RUNS the falsifying command and tries to refute. Verify before asserting; test before reporting. A skeptic with fresh context catches what the author rationalized.
- **N genuinely independent items are processed one at a time.** A `for item in list; do claude -p ...; done` where items do not depend on each other (per-PR reviews, per-item generation, per-repo audits). Parallelize the expensive calls; keep shared-state writes serial.
- **A finding touches 3+ repos, architecture, or security.** Spawn a deep-analysis subagent to trace the full impact chain before acting.
- **A decision benefits from diverse perspectives.** Spawn architect/reviewer/qa/security specialists in parallel on the same artifact, then synthesize.

## Stay single-agent when

- The task touches a handful of files in one context (an orchestrator reading a few small files gains nothing from fan-out).
- Work requires sequential discovery before it can be decomposed.
- The item count is small and each call is cheap (fan-out overhead exceeds the saving).
- A deterministic check already exists. A real `npm run build` gate beats an LLM verifier for build/test; reserve the verifier for correctness the build cannot prove (root cause, logic, symptom-silencing).

## Concurrency safety (mandatory)

Parallel agents must never share non-atomic state. If a loop writes a JSON state file via jq read-modify-write, or performs irreversible mutations (`gh pr close/ready/merge`, deploys), those steps stay SERIAL. The safe shape is three phases:

1. **Gate (serial):** decide which items proceed; cheap idempotent mutations OK.
2. **Work (parallel):** the expensive, read-only calls; write each result to its own file. No shared-state writes.
3. **Apply (serial):** read results in order; perform all mutations and state writes here.

## Node.js subprocess parallelism gotcha: `execSync` blocks

When parallelizing `claude -p` calls from Node.js, use **non-blocking `spawn`**, not `execSync`. `execSync` is synchronous: it blocks the Node.js event loop until the subprocess exits. Wrapping it in `Promise.all` gives NO actual parallelism; calls still run serially despite the async appearance.

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

For Python, use `concurrent.futures.ThreadPoolExecutor` with a bounded pool (env `*_CONCURRENCY`, default 3):
```python
from concurrent.futures import ThreadPoolExecutor
with ThreadPoolExecutor(max_workers=concurrency) as pool:
    results = list(pool.map(process_item, items))
```

Keep all shared-state writes (JSON files, DB, counters) on the main thread in original order after collection.

## Cost discipline

Fan-out multiplies token spend. Gate every autonomous fan-out behind a usage check, and log any coverage cap (top-N, no-retry) so silent truncation never reads as full coverage.

## When fanning out to TEST TECHNIQUES, demand a negative control

A fan-out that asks "which of these N approaches works?" produces confident-sounding successes that are easy to misread. Two requirements turn it into evidence:

1. **Every claimed success gets an adversarial re-run** by an agent instructed to *refute* it, from scratch, using only the reported reproduction command. Default to REFUTED when it cannot be reproduced. (Same rule as above, applied to technique discovery rather than to bug fixes.)

2. **Require a negative control in the agent's brief.** Ask explicitly: *what is the cheapest change that should NOT work, and does it in fact not work?* Without it you learn "X worked" but not "X worked *because of Y*", and only the second lets you build on it.

> A fan-out testing ~20 approaches against an anti-automation wall returned dozens of verified successes. The single most valuable output was not a technique. A verifier ran the control that had been skipped, changing only the client identification string, same IP, same moment, and showed the wall came back byte-identical, while a different client-fingerprint approach returned a real page. That is what identified the transport-layer fingerprint as the mechanism. Without it there was a working trick and no model, and the wrong abstraction (a per-host profile map that later evidence showed would rot silently) would have been built on top of it.

Two failure modes to brief agents against explicitly, both of which bit in that run:

- **Fabricated test fixtures.** An invented ID or URL returns a genuine 404 and reads as "blocked", sending the whole investigation down a false path. Control URLs must come from the real data source (the production database, a sitemap), never from memory or typing.
- **Self-inflicted rate limiting.** Bursting a target during testing turns a working technique into an apparent failure. Instruct agents to pace and to re-test after a cooldown before declaring something impossible.

---

## Persist what agents return

A subagent's report exists in exactly one place: the tool result in your context. If you distill it into a smaller deliverable and let the raw report go out only in your chat response, **the detail is gone** the moment the turn ends. Chat is not storage. It is not greppable, diffable, or linkable, and a long response can be truncated in the live view.

> Two subagents each read a long conference-talk transcript and returned dense, timestamped, verbatim-quoted reports. A condensed synthesis was written to a `.md` and committed; both raw reports went out only in the chat response. The next request was to push those summarizations to a file for review. The reports were more detailed than the synthesis and had to be reconstructed from context rather than read back from disk.

Rules:

- **Write each substantial subagent report to a file in the same turn**, alongside (not instead of) whatever synthesis you produce. Large outputs go to files.
- **One file per agent when they cover parallel items**, plus a `README.md` index. Do not merge N reports into one file and lose the per-item structure the fan-out bought you.
- **Commit the source too** when the work cites one (transcript, dataset, page dump, query output). It is usually small relative to its value, and it is what keeps every quoted claim re-checkable with `grep` instead of trusting the summary.
- **Verify delegated claims before publishing.** Require verbatim quotes with locators (timestamps, line numbers, file paths) in the agent's brief, then spot-check the load-bearing ones yourself. Zero-counts ("term X never appears") are worth re-running directly; they are the easiest claim for an agent to get wrong and the most damaging to assert.

### Verify your change in an isolated git worktree when another session is mid-edit in the same checkout

Multiple agent sessions can share one working tree per repo, so a repo-wide `npx tsc --noEmit` or `npm run build` can fail on files you never touched. In one case a concurrent session's in-flight edits to shared data-layer files produced 8 type errors across three apps while the single component file under test was clean; taking that at face value would mean either falsely reporting a broken build or committing someone else's WIP.

Procedure when `git status` shows modified/untracked files you did not create:

1. Attribute the errors first: `npx tsc --noEmit 2>&1 | grep -c <your-file>`. Zero hits means the failure is not yours.
2. Verify in isolation: `git worktree add -b <branch> ~/wt-<repo> origin/<default-branch>`, copy in only your file(s), then run tsc + build there.
3. node_modules in the worktree must be a hardlink copy (`cp -al ../repo/node_modules node_modules`, ~1s for a large tree), NOT a symlink; some bundlers panic with "Symlink [project]/node_modules is invalid, it points out of the filesystem root" and the build dies before compiling anything. The worktree also must live on the same filesystem as the source (under `$HOME`, not `/tmp`) for `cp -al` to work.
4. Commit from the worktree, push, open the PR, then `git worktree remove --force` and `git branch -D`.
5. Revert your leftover edits from the shared checkout afterwards (`git checkout -- <files>`) so the other session's `git add -A` cannot sweep a duplicate of your merged change into their commit.

Also: do NOT deploy from a shared checkout in this state; a deploy command builds from the local tree and would ship the other session's incomplete work.

### A research subagent that writes its report only at the end loses everything if it hits the output-token cap

A subagent dispatched to produce a long research file completed over 100 research tool calls, then died with "response exceeded the output token maximum" before writing anything to disk. All of that research was lost, and the parent had no partial artifact to salvage.

Why: the agent batched its whole deliverable into one final Write (or a single oversized final message). The output cap applies per assistant response, so a large single write is the exact failure mode. A dead agent leaves no transcript the parent can cheaply recover; the parent is told not to read the subagent JSONL (context overflow).

How to apply: when dispatching a research subagent that must produce a long file, instruct it to (1) write the file INCREMENTALLY, creating it early with a skeleton then appending one section per Write/Edit call, and (2) keep its final return message short (under ~300 words), since the return value is not the deliverable. Then verify the file exists before relying on it. Also budget for relaunch: a usage guardrail may block respawning, so a single lost agent can become an unrecoverable gap mid-session. Prefer several narrowly-scoped agents over one broad one.

### Do NOT infer subagent liveness from its transcript file; wait for the harness notification

There is no cheap filesystem signal for "is my subagent still alive". Neither size nor mtime works, and guessing wrong is expensive in both directions. The authoritative signal is the harness task-notification, which always arrives. Wait for it.

Measured, in one run, on a verifier that was alive and working the whole time:

- Size readings CONTRADICTED each other at the same instant: `stat -c %s` said 123 bytes while the file reader refused the same path as "270.2KB".
- MTIME was frozen for 10+ minutes while the agent was mid-flight. A long tool call (or buffered writes) produces no mtime movement, so "frozen mtime" does not mean dead.
- A queued message nudge sitting undelivered also does not mean dead: it is delivered at the agent's next tool round, which may be minutes away.

An earlier version of this entry advised using mtime over size. That was wrong and is corrected here: the agent it was derived from finished normally about a minute later and returned a full verdict.

What to do when a subagent's output is overdue:

- Wait. Arm a background `until [ -f <deliverable> ]; do sleep 10; done` watcher and keep working on independent tasks; do not poll in the foreground.
- Do NOT read a large agent transcript to investigate; it will overflow the parent's context. (Metadata is also uninformative, per above.)
- Do NOT write the expected deliverable path yourself as a "status record" while the agent may still be running. It races the real agent (which then overwrites your file), and any watcher armed on that path fires on YOUR OWN write, which is easy to misread as the report arriving.
- Never let a missing verdict silently become an implied one, but equally, never declare an agent dead without the harness saying so. Both are unfounded claims about state you did not observe. If you have already published a liveness claim that later proves wrong, retract it explicitly wherever it was published.

### An unreturned verifier subagent must degrade to "no verdict", never to a blocked session or an implied verdict

A spawned verifier/reviewer subagent that never returns is a THIRD outcome, distinct from both "confirmed" and "refuted", and it needs a pre-planned response. Two opposite failures are on record in the same runner, one run apart:

- One run concluded mid-flight that the verifier had stalled and published "no independent verdict backs this PR". The agent returned about a minute later. The inference was drawn from transcript size and mtime, neither of which is a liveness signal.
- The next run's verifier genuinely never returned. About an hour of session time was spent holding for a notification that never arrived.

The rule that covers both: report only what is observable ("no notification arrived, no report file was written"), never escalate that to a claim about the agent being dead or stalled, and never let the absence of a verdict silently read as a verdict either way.

Make the wait cheap by construction, so an unreturned agent costs nothing but time:

1. COMMIT before spawning the verifier. The shared worktree then cannot become the source of a bad commit if the agent leaves mid-revert edits behind.
2. Run the authoritative test/build from a SECOND worktree pinned to the pushed commit (`git worktree add /tmp/<n> --detach <branch>`). Evidence gathered there is immune to whatever the verifier is doing to the shared tree.
3. Re-check at the end that HEAD is unchanged, the tree is clean, and the fix is still present via `git show HEAD:<file>`.

Set an explicit time budget for the verifier and proceed past it with self-gathered evidence, labelled as such. A PR shipped with honest "no independent verdict exists, here is my own reproducible evidence" provenance is strictly better than either a blocked session or an unlabelled implication that review happened.

### Never publish a subagent's status before it reports; and comparing an error's size to a threshold's size is a margin fallacy

CORRECTS the earlier version of this entry, which was written while a verifier was still outstanding and is wrong.

RULE 1: do not publish anything about a subagent status until it has actually reported. One run concluded a verifier had stalled and published "no independent verdict backs this PR"; it returned a minute later. The next run was careful NOT to claim the agent had died, said only "no verdict has arrived", published that on the PR, and the verifier returned CONFIRMED WITH CORRECTIONS shortly after. Careful phrasing did not help: the practical effect was still a false statement in front of a reviewer, requiring a public retraction. The fix is not better hedging, it is silence. Say nothing about the agent, or "verification pending". There is no cheap filesystem liveness signal (not size, not mtime, not the absence of an expected report file) and an absent report proves nothing.

Keep the wait cheap by construction so a slow agent costs only time: COMMIT before spawning the verifier (the shared worktree can then never be the source of a bad commit if the agent leaves mid-revert edits); run the authoritative test/build from a SECOND worktree pinned to the pushed commit (`git worktree add /tmp/<n> --detach <branch>`); re-check at the end that HEAD is unchanged and the fix is still present via `git show HEAD:<file>`.

RULE 2 (the substantive lesson from what that verifier found): comparing an ERROR SIZE to a THRESHOLD SIZE is a margin fallacy. A metric had ~1 unit of measurement contamination and the reporting rule was a `>= 5` cutoff, so the contamination was dismissed as immaterial. But a sharp cutoff applied to ROUNDED INTEGERS means 1 unit is exactly enough to cross it. The question is never "is the error small relative to the threshold", it is "does the error move the value ACROSS the threshold". Measured on real data: 2 of 28 production days emitted the OPPOSITE user-facing advice. Test by replaying real history through both estimators and diffing the branch taken, not the value.

Three corollaries, all from the same review:

- Fixing one instance of a defect class obliges auditing every sibling instance. The same run hardened one LLM-brief field against exactly this trap and left its twin shipping a differently-weighted pair WITH a prompt instruction to difference it.
- Analysing only "clean" windows silently drops real production days. Restricting to full-length lookback windows excluded six genuinely shipped reports and understated the bug from 8 days to 5.
- A test can be named for a property it does not actually test. An "invariant to the later day weights" fixture used a UNIFORM move, which is weight-invariant under ANY index formula, so the estimator could be mutated Laspeyres to Paasche with the whole suite still green. Pin a choice with a fixture where the alternatives genuinely disagree.

And: do not accept a verifier correction without checking it either. One correction here claimed a `-0` normalisation was a no-op since `-0 === 0`. True on production render paths, but `assert.strictEqual` uses `Object.is`, where `Object.is(-0, 0)` is false, so it was load-bearing for the suite.
