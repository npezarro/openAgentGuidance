<!-- Load when: tiered stop hook classification, guard library, Tier 3 recursion prevention -->
# Stop Hook Safety

Stop hooks fire every time a Claude CLI session exits. That includes pipe-mode (`-p`) sessions started by autonomous scripts, subagents and other hooks. This makes them good for enforcement, and it also means they can recurse.

## Tier Classification

Every stop hook belongs to one of three tiers, based on how risky it is.

### Tier 1: Observation (fire-and-forget)
- Token tracking, desktop or tray notifications, logging
- Does not invoke Claude and does not block
- Timeout: 5-15 seconds
- Risk: effectively zero
- Examples: a token-usage tracker, a notification hook

### Tier 2: Verification (can block, does not invoke Claude)
- Deploy health checks and gates for unpushed code
- Can return `{"decision":"block"}` to keep the session alive
- Does not invoke Claude, so it cannot recurse
- Timeout: 15-30 seconds
- Risk: it can delay session exit, but it cannot loop
- Examples:
  - a post-deploy health check
  - an unpushed-commits check
  - a context-docs check that bounces the session once when its commits add functionality without updating the project's CLAUDE.md or context file
  - an evidence audit that bounces a final message that points to output "shown above" that isn't there, or claims a passing test suite without including the output

### Tier 3: Claude-invoking (DANGEROUS)
- Session scoring, analysis, or any post-processing that uses an LLM
- **Can recurse forever** without proper guards
- Must use every mandatory safeguard below
- Timeout: 60 seconds max for the Claude subprocess
- Must run in the background and never block session exit
- Example: a session-scoring hook

## Mandatory Safeguards for Tier 3 Hooks

Put the common guards in one shared guard library, for example `hooks/lib/stop-hook-guard.sh`, and source it from every Tier 3 hook. Don't copy the guard logic into each hook; copies drift apart.

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib/stop-hook-guard.sh"
stop_hook_init "my-hook-name" --invokes-claude

# HOOK_INPUT, SESSION_ID, TRANSCRIPT are now available
# All guards have passed if execution reaches here
```

### What the guard library must provide

1. **Env var circuit breaker.** Export `CLAUDE_HOOK_<NAME>=1` before invoking Claude. Check for it on entry and exit if it is set. This stops the hook from firing on sessions it started itself.

2. **Lockfile.** Keep a PID-based lockfile in `/tmp/claude-hook-locks/` so two copies of the same hook can't run at once. Remove it with a `trap`.

3. **Rate limiter.** Keep a per-hook invocation counter in `/tmp/claude-hook-rates/`. Default limit: 5 invocations per hour. Prune old entries automatically.

### Safeguards the hook author must add

4. **Content fingerprinting.** Search the conversation for the hook's own prompt signature. This is the fallback for when the env var guard fails because the shell didn't inherit env vars.

```bash
CONVERSATION=$(echo "$HOOK_INPUT" | jq -r '.last_assistant_message // empty')
if printf '%s' "$CONVERSATION" | grep -q 'my unique prompt marker'; then
  exit 0
fi
```

5. **Minimum conversation length.** Skip trivial sessions such as quick Q&A or accidental exits. 200 characters is a good default minimum.

6. **Background execution.** Run the Claude call in the background so the hook doesn't block session exit:

```bash
(
  timeout 60 claude -p --dangerously-skip-permissions --no-chrome \
    --model haiku "..." < "$TMPFILE" 2>/dev/null
  rm -f "$TMPFILE"
) &
exit 0
```

7. **Subprocess timeout.** Always wrap `claude -p` in `timeout 60` (or similar) so a hung Claude session can't run forever.

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

`/goal` (Claude Code 2.1.139 and later) registers its own prompt-based Stop hook for the session. After each turn, a small evaluator model checks the goal condition and prompts the session again if the condition isn't met. The harness manages this hook and it only exists while the goal is active, so the tier rules and guard-library requirements above don't apply to it. Don't flag it as an unregistered Tier 3 hook and don't wrap it. It still counts as a loop that invokes Claude, so any runner that uses goals must run behind your usage or budget gate.

## Rules for All Tiers

1. **Always `exit 0` at the end.** A non-zero exit from a stop hook can abort session teardown.
2. **Never retry on failure.** Hooks are fire-and-forget. Log the failure and move on.
3. **Timeouts are mandatory, and the `timeout` field is in SECONDS.** Set the `timeout` field in settings.json, and use the `timeout` command for subprocesses. Claude Code's per-hook `timeout` field is in seconds (default 600 for command hooks, not enforced on `async: true` hooks). A value written as if it were milliseconds, like `30000`, means 8.3 hours. Stop hooks run in parallel and the session waits for all of them, so one hung `curl` or `ssh` stalls the end of the turn. Use small integers (5-30), and give every synchronous Stop hook its own internal limit (`curl --max-time`, `timeout(1)`) so the harness timeout is never the only limit.
4. **No interactive prompts.** Stop hooks run without a TTY. Any `read` or interactive Claude session will hang.
5. **Redact before transmitting.** A hook that sends conversation content anywhere external must strip credentials (tokens, keys, passwords, connection strings) first.

## Debugging Hook Issues

Check these in order:
1. Rate log: `cat /tmp/claude-hook-rates/<hook-name>.log`
2. Lock state: `ls -la /tmp/claude-hook-locks/`
3. Env var: `env | grep CLAUDE_HOOK`
4. Token usage logs: look for clusters of sessions starting close together, which is the signature of recursion
5. Check that the hook's own log file exists. If a hook is supposed to log and its log file was never created, the hook has never run. Don't count it as enforcement until you've seen it fire.

## Adding a New Stop Hook Checklist

Before adding a new Stop hook to settings.json:

- [ ] Classified as Tier 1, 2 or 3
- [ ] Timeout set in settings.json (`"timeout"` field, in seconds)
- [ ] Ends with `exit 0`
- [ ] If Tier 3: sources the shared guard library with `--invokes-claude`
- [ ] If Tier 3: has a content fingerprint fallback
- [ ] If Tier 3: runs Claude in the background with `timeout`
- [ ] If Tier 3: checks for a minimum conversation length
- [ ] If Tier 2 (blocking): the block reason tells the agent exactly what to fix
- [ ] Tested manually: `echo '{"session_id":"test","transcript_path":""}' | bash hooks/my-hook.sh`

## Lessons from Hook Failures

### A hook that resolves the repo from its own cwd misses most commits
A hook runs in the session's starting directory, which often isn't the repo being changed. If a PostToolUse or Stop hook runs `git rev-parse` in its own cwd, it never sees `cd X && git commit` or `git -C X commit`, and it can go its whole life without firing once. Work out the target repo from the command itself (a leading `cd`, `-C` arguments), or from a ledger of commits made during the session. Also check that every field the hook reads actually exists in that hook event's input payload. If it reads a missing field, it quietly gets nothing.

### A gate can detect correctly and still report the wrong conclusion
If a gate reports the wrong category (for example "public repo" for a private one), read the whole path that produces the message before you debug detection. Detection can be correct while a later message is hardcoded and printed no matter what was detected. The usual root cause is duplication: several hooks each carry their own inline copy of logic that a shared library already provides, and the copies drift. Fix it by deleting the copies and calling the library, not by patching each copy separately.

### Never cache the value that decides whether a gate runs without an expiry
If a gate only blocks under one condition (for example, only when the repo is public), caching that condition forever is dangerous in one direction only. After the condition flips, the stale value turns the gate off silently. Give the cache a TTL. If a lookup fails, fall back to the last known value rather than "unknown", and do not refresh the cache timestamp. Otherwise one transient failure marks a stale entry as fresh for another full TTL.

### Distribution is part of the fix
Git hooks are copied into each clone's `.git/hooks` (and `init.templateDir` puts them in every new clone), so editing the source changes nothing that's already installed. Make sure your installer reaches every local clone, not just a subset. After any hook edit, grep the INSTALLED copies for a marker from the new code. Reading the source proves nothing about what's running.

### Test the hook's tests
- To simulate a missing external binary, stub it. Trimming `PATH` doesn't work if the binary lives in a directory you kept (for example `/usr/bin`), and then the "offline" path is never exercised while the test still reports PASS.
- Don't call real network APIs from hook tests. A transient 5xx error will fail correct code.
- Before trusting a new assertion, confirm it FAILS against the pre-fix code. An assertion that passes against both versions proves nothing.
