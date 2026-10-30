<!-- Load when: tiered stop hook classification, guard library, Tier 3 recursion prevention -->
# Stop Hook Safety

Stop hooks fire on every Claude CLI session exit. That includes pipe-mode (`-p`) sessions started by autonomous scripts, subagents and other hooks. This makes them powerful for enforcement and dangerous for recursion.

## Tier Classification

Each stop hook belongs to one of three tiers, based on its risk:

### Tier 1: Observation (fire-and-forget)
- Token tracking, desktop or tray notifications, logging
- Does not invoke Claude and does not block
- Timeout: 5-15s
- Risk: effectively zero
- Examples: a token-usage tracker, a desktop notification hook

### Tier 2: Verification (can block, no Claude)
- Deploy health checks, gates for unpushed code
- Can return `{"decision":"block"}` to keep the session alive
- Does not invoke Claude, so it cannot recurse
- Timeout: 15-30s
- Risk: can delay session exit, but cannot loop
- Examples:
  - a post-deploy health check
  - an unpushed-commits check
  - a context-docs check that bounces once when the session's commits add functionality without updating CLAUDE.md or context.md
  - a report-evidence check that bounces a final message pointing at something "shown above" that isn't there, or claiming a green test suite without pasting the output
  - a push-notification enforcer that bounces once per turn when an interactive turn ran tools but its last tool call was not a notification (it skips headless runs)

### Tier 3: Claude-invoking (DANGEROUS)
- Session scoring, analysis, or any other post-processing that calls an LLM
- **Can recurse infinitely** without the right guards
- Must use every mandatory safeguard below
- Timeout: 60s max for the Claude subprocess
- Must run in the background and never block session exit
- Example: a session-scoring hook

## Mandatory Safeguards for Tier 3 Hooks

Put the first three safeguards in a shared guard library, for example `hooks/lib/stop-hook-guard.sh`. Every Tier 3 hook then sources it:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib/stop-hook-guard.sh"
stop_hook_init "my-hook-name" --invokes-claude

# HOOK_INPUT, SESSION_ID, TRANSCRIPT are now available
# All guards have passed if execution reaches here
```

### What the guard library must provide

1. **Env var circuit breaker.** Export `CLAUDE_HOOK_<NAME>=1` before invoking Claude. Check for it at entry and exit if it is set. This stops the hook from firing on sessions it spawned itself.

2. **Lockfile.** Keep a PID-based lockfile in `/tmp/claude-hook-locks/` so the same hook can't run twice at once. Remove it with a `trap`.

3. **Rate limiter.** Keep a per-hook invocation counter in `/tmp/claude-hook-rates/`. Default: at most 5 invocations per hour. Prune old entries automatically.

### Safeguards the hook author must add

4. **Content fingerprinting.** Search the conversation for your hook's own prompt signature. The env var guard fails if the shell doesn't inherit environment variables, and this check is the fallback.

```bash
CONVERSATION=$(echo "$HOOK_INPUT" | jq -r '.last_assistant_message // empty')
if printf '%s' "$CONVERSATION" | grep -q 'my unique prompt marker'; then
  exit 0
fi
```

5. **Minimum conversation length.** Skip trivial sessions such as quick Q&A or accidental exits. A 200-character minimum is a good default.

6. **Background execution.** Run the Claude call in the background so the hook doesn't block session exit:

```bash
(
  timeout 60 claude -p --dangerously-skip-permissions --no-chrome \
    --model haiku "..." < "$TMPFILE" 2>/dev/null
  rm -f "$TMPFILE"
) &
exit 0
```

7. **Subprocess timeout.** Always wrap `claude -p` in `timeout 60` or similar, so a hung Claude session can't run forever.

## Template: Tier 3 Hook

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib/stop-hook-guard.sh"
stop_hook_init "my-analysis" --invokes-claude

# Content fingerprint fallback
LAST_MSG=$(echo "$HOOK_INPUT" | jq -r '.last_assistant_message // empty')
if printf '%s' "$LAST_MSG" | grep -q 'MY_UNIQUE_MARKER'; then
  exit 0
fi

# Skip trivial sessions
[ "${#LAST_MSG}" -lt 200 ] && exit 0

# Prepare input
TMPFILE=$(mktemp /tmp/hook-analysis-XXXXXX.txt)
printf '%s' "$LAST_MSG" | tail -c 5000 > "$TMPFILE"

# Fire and forget
(
  timeout 60 claude -p --dangerously-skip-permissions --no-chrome \
    --model haiku "Analyze this session: ..." < "$TMPFILE" 2>/dev/null
  rm -f "$TMPFILE"
) &

exit 0
```

## Exemption: the /goal Evaluator Hook

`/goal` (Claude Code >= 2.1.139) registers its own Stop hook, scoped to the session and driven by a prompt. After each turn, a small evaluator model checks the goal condition and re-prompts the session if the condition isn't met. The harness manages this hook, and it exists only while the goal is active. The tier classification and guard-library rules above don't apply to it: don't flag it as an unregistered Tier 3 hook, and don't wrap it. It still counts as a loop that invokes Claude for budget purposes, so any runner that uses goals must sit behind a usage or budget gate.

## Rules for All Tiers

1. **Always end with `exit 0`.** A non-zero exit from a stop hook can abort session teardown.
2. **Never retry on failure.** Hooks are fire-and-forget. Log the failure and move on.
3. **Timeouts are mandatory.** Set the `timeout` field in settings.json and also use the `timeout` command on subprocesses. The settings.json `timeout` is in **seconds**, not milliseconds. The default is 600 for command hooks, and it isn't enforced on `async: true` hooks. A value like `30000` means 8.3 hours. Use small integers (5-30). Stop hooks run in parallel and the session waits for all of them, so one hung `curl` or `ssh` stalls the end of every turn. Give every synchronous Stop hook an internal bound (`curl --max-time`, `timeout(1)`) so the harness timeout is never the only limit.
4. **No interactive prompts.** Stop hooks run without a TTY. Any `read` call or interactive Claude session will hang.
5. **Redact before transmitting.** Any hook that sends conversation content to an external service must strip credentials first: tokens, API keys, passwords, connection strings and webhook URLs.

## Debugging Hook Issues

Check these in order:
1. Rate log: `cat /tmp/claude-hook-rates/<hook-name>.log`
2. Lock state: `ls -la /tmp/claude-hook-locks/`
3. Env var: `env | grep CLAUDE_HOOK`
4. Token usage log: look for clusters of sessions started close together, which signal recursion

## Adding a New Stop Hook Checklist

Before you add any new Stop hook to settings.json:

- [ ] Classified as Tier 1, 2 or 3
- [ ] Timeout set in settings.json (`"timeout"` field, **in seconds**)
- [ ] Every network or remote call inside the hook has its own timeout
- [ ] Ends with `exit 0`
- [ ] If Tier 3: uses the guard library with `--invokes-claude`
- [ ] If Tier 3: has a content fingerprint fallback
- [ ] If Tier 3: runs Claude in the background with `timeout`
- [ ] If Tier 3: has a minimum conversation length check
- [ ] If Tier 2 (blocking): the block reason is actionable and tells the agent what to fix
- [ ] Tested manually: `echo '{"session_id":"test","transcript_path":""}' | bash hooks/my-hook.sh`
- [ ] Its log file actually appears after a real session (a hook whose log never appears has never run)

## Lessons from Hook and Gate Failures

### Read the whole message path before debugging detection
A gate can detect a condition correctly and still print the opposite conclusion from a hardcoded message a few lines later. If a gate reports the wrong category, check the code that emits the message before you touch the lookup. This drift usually comes from duplication: several hooks carry their own inline copy of logic that a shared library already provides. The fix is to delete the copies, not to patch each one separately.

### Never cache the value that decides whether a gate runs without an expiry
If a gate only blocks under one condition (for example "repo is public"), caching that condition forever is asymmetric. When the underlying state flips, the stale cache switches the gate off silently. Give such caches a TTL. If a lookup fails, fall back to the last known value rather than "unknown", and don't refresh the cache timestamp. Otherwise one transient failure marks a stale entry as fresh for another full TTL.

### Distribution is part of the fix
Hooks installed as copies (in each `.git/hooks`, or through `init.templateDir`) don't change when you edit the source. After any hook edit, reinstall to every location that runs it, including locations your installer might skip by default. Then verify by grepping the **installed** copies for a marker from the new code, not by reading the source.

### Make sure your tests can fail
- Narrowing `PATH` to simulate a missing binary doesn't work if the binary lives in the directories you kept, and the test reports PASS while the offline path goes untested. Stub the external binary instead.
- Tests that hit a real API become flaky on transient errors and fail correct code. Stub external calls.
- Run every new assertion against the pre-fix code and confirm it fails. An assertion that passes on both versions proves nothing.

### Resolve the target repo from the command, not the hook's cwd
A PostToolUse hook runs in the session's starting directory, which often isn't the repo being changed. A hook that runs `git rev-parse` in its own cwd never sees `cd X && git commit` or `git -C X commit`. Parse the effective directory out of the command, including `cd` prefixes and `-C` args. Read only fields that actually exist in the PostToolUse payload. Before you call a hook "enforced", confirm its log file exists and has entries.
