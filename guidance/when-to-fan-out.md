<!-- Load when: when to spawn subagents (Task fan-out / parallel bash / Workflow) vs stay single-agent; concurrency-safe 3-phase pattern -->
# When to Fan Out into Subagents

Guidance for autonomous loops and interactive sessions on when to spawn subagents (Task tool, parallel `claude -p`, or Workflow) and when to stay single-agent. The default is single-agent. Fan out only when the structure of the task genuinely benefits from it.

## The three primitives, and where each applies

1. **In-session Task fan-out:** a single `claude -p` session spawns subagents through the Task tool. This works in headless `--dangerously-skip-permissions` sessions. Give the Task tool an INLINE role description. Do not rely on a custom agentType name resolving in headless mode. This is the only fan-out available to a cron `claude -p` loop.
2. **Bash-level parallelism:** `&` with a `wait -n` throttle, or `xargs -P`. Use it when a loop calls `claude -p` (or any subprocess) once per independent item. It works from cron and needs no SDK.
3. **Workflow tool:** deterministic multi-agent orchestration (fan-out, pipeline, adversarial verify, synthesize). It runs inside an interactive or SDK session, NOT a bare cron `claude -p`. Use it for heavy interactive work such as deep review, multi-source research, or migrations.

## Offload mechanical breadth to another agent CLI when Claude usage is high

Some steps are pure mechanical breadth: open every listing or page in a set, read each one's times, prices, reviews and policies, then report back. When your Claude weekly usage is high (your usage gate reads at or above about 75%), hand that step to a different agent CLI instead of a Claude subagent. For example, with Codex: `codex --search exec -s workspace-write -c sandbox_workspace_write.network_access=true --disable apps -C <output dir> -o <last-message file> - < brief.md`. Run it in the background and review its report when it finishes. Those runs use no Claude quota, and on operational fact lookups (hours, availability, addresses) they can be as accurate as Claude subagents or better. Keep Claude for the judgment layer: choosing what to dive into, checking the other agent's claims against primary pages, and synthesis. Rules for the brief:
- Read-only: no booking, no sign-in, no messaging.
- One named output file, written incrementally.
- Connector write tools turned off (`--disable apps`).

## Fan out when

- **An independent claim needs an independent check.** Before a loop reports "fixed", "passing" or "works" (especially a loop that self-merges or deploys), spawn a verifier subagent that RE-RUNS the falsifying command and tries to refute the claim. Verify before asserting, and test before reporting. A skeptic with fresh context catches what the author rationalized.
- **N genuinely independent items are processed one at a time.** For example, a `for item in list; do claude -p ...; done` loop where the items don't depend on each other: per-PR reviews, per-document drafts, per-channel analysis, per-repo audits. Run the expensive calls in parallel and keep shared-state writes serial.
- **A finding touches 3+ repos, the architecture, or security.** Spawn a deep-analysis subagent to trace the full impact chain before you act.
- **A decision benefits from diverse perspectives.** Spawn architect, reviewer, QA and security specialists in parallel on the same artifact, then synthesize their reports.

## Stay single-agent when

- The task touches a handful of files in one context.
- The work needs sequential discovery before it can be broken into parts.
- There are only a few items and each call is cheap, so fan-out overhead costs more than it saves.
- A deterministic check already exists. A real `npm run build` gate beats an LLM verifier for build and test results. Save the verifier for correctness the build can't prove (root cause, logic, symptom-silencing).

## Concurrency safety (mandatory)

Parallel agents must never share non-atomic state. If a loop writes a JSON state file through a jq read-modify-write, or makes irreversible changes (`gh pr close/ready/merge`, deploys), those steps stay SERIAL. The safe shape has three phases:

1. **Gate (serial):** decide which items go ahead. Cheap, idempotent changes are fine here.
2. **Work (parallel):** the expensive, read-only calls. Each result goes to its own file. No shared-state writes.
3. **Apply (serial):** read the results in order and make every change and state write here.

**Give each agent its own scratch subdirectory in the brief** (e.g. `<scratch>/<batch>/`). Agents independently write helpers with the same obvious names (`pub.sh`, `verify.py`). In a shared scratch root they overwrite each other mid-run, and the output silently comes out wrong (for example, uploads published as raw markdown).

## Node.js subprocess parallelism gotcha: `execSync` blocks

When you run `claude -p` calls in parallel from Node.js, use **non-blocking `spawn`**, not `execSync`. `execSync` is synchronous: it blocks the event loop until the subprocess exits. Wrapping it in `Promise.all` gives NO real parallelism, and the calls still run one after another even though the code looks async.

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

In Python, use `concurrent.futures.ThreadPoolExecutor` with a bounded pool (an env var `*_CONCURRENCY`, default 3):
```python
from concurrent.futures import ThreadPoolExecutor
with ThreadPoolExecutor(max_workers=concurrency) as pool:
    results = list(pool.map(process_item, items))
```

After collecting results, do all shared-state writes (JSON files, DB, counters) on the main thread, in the original order.

## Cost discipline

Fan-out multiplies token spend. Put every autonomous fan-out behind a usage gate (a script that checks your plan's usage and exits non-zero above a threshold). `log()` any coverage cap (top-N, no-retry) so that silent truncation never looks like full coverage.

**The gate checks the level at one moment. It is not a budget for the wave you're about to launch.** A gate that passes at launch doesn't limit how fast a burst of concurrent heavy agents spends afterward. A wave of a dozen concurrent deep-research agents can hit "session limit" rate errors on every agent about an hour in. If the agents were told to write the full report only at the end, nothing reaches disk. Before a fan-out:
1. Project the wave's cost (calibrate from your own gate history, roughly in usage-meter points per deep research agent-hour). Refuse any wave whose projection would cross the gate.
2. Cap deep research waves at about 4 concurrent agents. Launch the next one as each finishes rather than launching the whole set at once.
3. Require every research dispatch prompt to write an early skeleton file and then append one section per batch of findings, so a killed agent still leaves partial work on disk.
4. If a wave dies on a rate limit, report the loss plainly and ask before relaunching against a nearly spent weekly budget.

## When fanning out to TEST TECHNIQUES, demand a negative control

A fan-out that asks "which of these N approaches works?" produces confident-sounding successes that are easy to misread. Two requirements turn those successes into evidence:

1. **Every claimed success gets an adversarial re-run** by an agent told to *refute* it from scratch, using only the reported reproduction command. If the result can't be reproduced, the verdict defaults to REFUTED.
2. **Require a negative control in the agent's brief.** Ask explicitly: *what is the cheapest change that should NOT work, and does it in fact fail?* Without that you learn "X worked" but not "X worked *because of Y*", and only the second lets you build on it. A control that changes one variable alone (for example, one request header while everything else stays the same) and gets a byte-identical failure tells you that variable is not the mechanism. That is often the most valuable result of the whole run, because it stops you building the wrong abstraction.

Brief agents explicitly against two failure modes:

- **Fabricated test fixtures.** An invented ID or URL returns a genuine 404 that looks like "blocked" and sends the whole investigation down a false path. Control inputs must come from the real data source (the production DB, a sitemap), never from memory or typing.
- **Self-inflicted rate limiting.** Bursting a target during testing makes a working technique look like a failure. Tell agents to pace their requests and to re-test after a cooldown before declaring something impossible.

---

## Persist what agents return

A subagent's report exists in exactly one place: the tool result in your context. If you distill it into a smaller deliverable and the raw report appears only in your chat response, **the detail is gone** when the turn ends. Chat is not storage. You can't grep, diff or link it, and a long response may be cut off in the live view.

Rules:

- **Write each substantial subagent report to a file in the same turn**, alongside (not instead of) any synthesis you produce. Large outputs go to files.
- **One file per agent when they cover parallel items**, plus a `README.md` index. Don't merge N reports into one file and lose the per-item structure the fan-out gave you.
- **Commit the source too** when the work cites one (transcript, dataset, page dump, query output). It is usually small compared with its value, and it keeps every quoted claim checkable with `grep` instead of trusting the summary.
- **Verify delegated claims before publishing.** Require verbatim quotes with locators (timestamps, line numbers, file paths) in the agent's brief, then spot-check the load-bearing ones yourself. Re-run zero-counts ("term X never appears") yourself. They are the easiest claim for an agent to get wrong and the most damaging to assert.

### Verify your change in an isolated git worktree when another session is mid-edit in the same checkout

When several sessions share one working tree per repo, a repo-wide `npx tsc --noEmit` or `npm run build` can fail on files you never touched. Taking that failure at face value means either falsely reporting a broken build or committing someone else's work in progress.

If `git status` shows modified or untracked files you didn't create:
1. Attribute the errors first: `npx tsc --noEmit 2>&1 | grep -c <your-file>`. Zero hits means the failure isn't yours.
2. Verify in isolation: `git worktree add -b <branch> $HOME/wt-<repo> origin/<default-branch>`, copy in only your file(s), then run tsc and the build there.
3. In the worktree, `node_modules` must be a hardlink copy (`cp -al ../repo/node_modules node_modules`, about a second), NOT a symlink. Turbopack panics on a symlinked `node_modules` that points outside the project root and dies before compiling anything. The worktree must also be on the same filesystem as the source (under `$HOME`, not `/tmp`) for `cp -al` to work.
4. Commit from the worktree, push, open the PR, then `git worktree remove --force` and `git branch -D`.
5. Revert your leftover edits in the shared checkout afterward (`git checkout -- <files>`) so the other session's `git add -A` can't sweep a duplicate of your merged change into its commit.

Also, do NOT deploy from a shared checkout in this state. A deploy that builds from the local tree would ship the other session's unfinished work.

### A research subagent that writes its report only at the end loses everything if it hits the output-token cap

A subagent can finish a hundred research tool calls and then die with "response exceeded the output token maximum" before writing anything to disk. All the research is lost, and the parent has no partial artifact to salvage.

Why: the agent saved its whole deliverable for one final Write (or one oversized final message). The output cap applies to each assistant response, so one large write is exactly the failure mode. A dead agent leaves no transcript the parent can cheaply recover, because reading a subagent transcript overflows the parent's context.

How to apply: when you dispatch a research subagent that must produce a long file, tell it to (1) write the file INCREMENTALLY: create it early with a skeleton, then append one section per Write/Edit call, and (2) keep its final return message short (under about 300 words), since the return value is not the deliverable. Check that the file exists before relying on it. Also plan for relaunching: a usage gate may block a respawn, so one lost agent can become a gap you can't recover mid-session. Prefer several narrowly scoped agents over one broad one.

### Do NOT infer subagent liveness from its transcript file; wait for the harness notification

There is no cheap filesystem signal for "is my subagent still alive?" Neither size nor mtime works, and guessing wrong is expensive in both directions. The authoritative signal is the harness task notification, which always arrives. Wait for it.

What has been observed on agents that were alive and working:
- Size readings contradict each other at the same moment (`stat` and the file reader report different sizes for the same path).
- Mtime stays frozen for 10+ minutes while the agent is mid-flight. A long tool call or buffered writes don't move the mtime, so a frozen mtime doesn't mean the agent is dead.
- An undelivered SendMessage nudge doesn't mean dead either. It is delivered at the agent's next tool round, which may be minutes away.

When a subagent's output is overdue:
- Wait. Arm a background `until [ -f <deliverable> ]; do sleep 10; done` watcher and keep working on independent tasks. Don't poll in the foreground.
- Do NOT read a large agent transcript to investigate. It will overflow the parent's context, and the metadata tells you nothing anyway.
- Do NOT write the expected deliverable path yourself as a "status record" while the agent may still be running. That races the real agent (which then overwrites your file), and any watcher armed on that path fires on YOUR write, which is easy to misread as the report arriving.
- Never let a missing verdict silently become an implied one. Equally, never declare an agent dead unless the harness says so. Both are unfounded claims about state you didn't observe. If you published a liveness claim that later proves wrong, retract it explicitly wherever you published it.

### An unreturned verifier must degrade to "no verdict", never to a blocked session or an implied verdict

A verifier or reviewer subagent that never returns is a THIRD outcome, distinct from "confirmed" and "refuted", and it needs a planned response. Both opposite failures happen in practice: one run decides the verifier has stalled and publishes "no independent verdict backs this PR", and the agent returns a minute later. Another run waits about an hour for a notification that never comes.

**Rule 1: publish nothing about a subagent's status until it has reported.** Careful hedging ("no verdict has arrived yet") doesn't help. If the verifier then returns, a reviewer has still been shown a false statement that needs a public retraction. Say nothing, or say "verification pending". An absent report file proves nothing.

Make the wait cheap by construction, so a slow or unreturned agent costs only time:
1. COMMIT before spawning the verifier. Then the shared worktree can't become the source of a bad commit if the agent leaves half-reverted edits behind.
2. Run the authoritative test or build from a SECOND worktree pinned to the pushed commit (`git worktree add /tmp/<n> --detach <branch>`). Evidence gathered there is immune to whatever the verifier does to the shared tree.
3. At the end, re-check that HEAD is unchanged, the tree is clean, and the fix is still present (`git show HEAD:<file>`).

Set an explicit time budget for the verifier. Once it's spent, proceed with evidence you gathered yourself, labelled as such. A PR shipped with an honest "no independent verdict exists; here is my own reproducible evidence" is strictly better than a blocked session, and better than an unlabelled implication that review happened.

### Comparing an error's size to a threshold's size is a margin fallacy

Suppose a metric carries about 1 unit of contamination and the reporting rule is a cutoff of >= 5. It's tempting to dismiss the error as small compared with the threshold. But a sharp cutoff applied to ROUNDED INTEGERS means 1 unit is exactly enough to cross it. The question is never "is the error small relative to the threshold?" It is "does the error move the value ACROSS the threshold?" Test this by replaying real history through both estimators and diffing the branch taken, not the value.

Corollaries:
- Fixing one instance of a defect class obliges you to audit every sibling instance.
- Analysing only "clean" windows silently drops real production days and understates the bug.
- A test can be named for a property it doesn't actually test. A fixture that applies a uniform change is invariant under any weighting formula, so it can't pin which formula is used. Pin a choice with a fixture where the alternatives genuinely disagree.
- Don't accept a verifier's correction without checking it either. For example, "normalizing -0 is a no-op since -0 === 0" is true on most render paths, but `assert.strictEqual` uses `Object.is`, where `Object.is(-0, 0)` is false.

### Give a verifier the same preconditions the artifact states, or it refutes a claim you never made

Suppose a verifier gets the branch and the claim but NOT the precondition the claim depends on. It will test the unconditional version, find it false, and return a confident REFUTED wrapped around several correct minor findings. That is the most expensive shape of feedback, because it tempts you to reject the whole thing.

For example, a PR says its fix only becomes reachable once another open PR merges, and all its evidence was gathered against `branch + other PR`. If the verifier prompt never mentions the other PR, the verifier tests against the base alone and hands back the PR's own documented caveat as a fatal finding.

What to do:
- Put the preconditions IN the verifier prompt, not just in the artifact: which other branches are assumed merged, which env vars or flags, which build. "Verify commit X" is underspecified whenever X's correctness is conditional.
- State the environment your own evidence came from, so a mismatch shows up as a disagreement about setup rather than about the claim.
- When a verdict comes back REFUTED, first check whether the verifier tested the same configuration you did. If not, the verdict is about a different artifact. Triage the sub-findings one by one rather than dismissing them along with the headline. Minor findings about loosely written prose (an "A and B both fire" claim about mutually exclusive branches, an unreachable fallback) are often correct even when the headline is wrong.

### A research subagent can delegate instead of researching, and the orphaned child later overwrites the shared output file

A subagent given a research prompt may spawn its own subagent and return a status update ("I've launched an agent, I'll report back") as its final answer. Resuming it with "don't delegate, do it yourself" works, but the orphaned child can't be cancelled from the parent. It keeps running against the SAME output path and overwrites the resumed parent's file.

Why: a subagent's final message is its return value, so a status update is a null result that costs a full agent's runtime. Two agents writing to one file path is a last-writer-wins race that raises no error.

How to apply:
1. Tell research subagents explicitly: "Do NOT spawn subagents. Do the searching yourself and return the actual findings."
2. If you must resume a delegating agent, give the resumed run a DIFFERENT output path, or re-read the file afterward and check which version landed (grep for a marker unique to each version) before trusting it.
3. Treat "I'll report back" in a final message as a failed agent, not a partial one.

In headless single-turn sessions, blocking on a delegating parent returns only its non-answer. The grandchildren keep running and their results may still arrive as separate top-level task notifications, which you can use. Watch for those before you write the parent off.

### A SendMessage redirect to a running subagent lands only at its next tool round

Messages queue up and are delivered at the receiver's next tool round. A redirect that changes an output path is reliable only if it arrives before the agent reaches its writing step, and the sender can't observe when that happens. An agent can acknowledge receipt and still write to the original path.

Rules:
1. Get output paths right in the spawn prompt. List the destination directory FIRST, including files other sessions added recently.
2. If a mid-run rename is unavoidable, plan to `mv` the file afterward, `sed` its self-references and H1, and re-check any docs that cite the old name.
3. Content redirects (add a source, skip a section) are more likely to land because they apply to later steps. Send them early and keep them short.

### Fan-out prompts must carry the loaded skill's hard rules verbatim, and the orchestrator must check a coverage count over the population before reporting

Subagents don't inherit the rules of a skill or procedure the orchestrator loaded. If the procedure requires a particular query form, the subagents will write their own and silently get it wrong. For example, many search engines (including Gmail) parse `a OR b c` as `(a OR b) AND c`, so a loosely written OR-query drops real matches, and the missing items get reported as "no result". Separately, a hand-built target list with no count check silently leaves members out.

Rules:
1. Paste the skill's hard rules verbatim into every fan-out prompt, including exact query syntax (for example: always brace OR groups).
2. Define the population up front (e.g. every active row in the tracking sheet), print its size, and make the report conditional on every member appearing exactly once.
3. When sweeping a mailbox or log for outcomes, query by stable identifiers (sender address, system name, entity name), not by a free-text phrase the target may not repeat. Fetch the full thread or record before asserting a negative.
