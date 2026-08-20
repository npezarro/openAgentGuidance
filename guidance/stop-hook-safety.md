<!-- Load when: tiered stop hook classification, guard library, Tier 3 recursion prevention -->
# Stop Hook Safety

Stop hooks fire on every Claude CLI session exit, including pipe-mode (`-p`) sessions spawned by autonomous scripts, subagents, and other hooks. This makes them powerful for enforcement but dangerous for recursion.

## Tier Classification

Every stop hook falls into one of three tiers based on its risk profile:

### Tier 1: Observation (fire-and-forget)
- Token tracking, tray notifications, logging
- No Claude invocation, no blocking
- Timeout: 5-15s
- Risk: effectively zero

### Tier 2: Verification (can block, no Claude)
- Deploy health checks, unpushed code gates
- Can return `{"decision":"block"}` to keep the session alive
- No Claude invocation, so no recursion risk
- Timeout: 15-30s
- Risk: can delay session exit, but can't loop
- Examples: a deploy health check, an unpushed-commits gate, an evidence audit that bounces a final message which dangles a "shown above" reference or claims a green test suite with no pasted output

### Tier 3: Claude-invoking (DANGEROUS)
- Session scoring, analysis, any LLM-powered post-processing
- **Can create infinite recursion** if not properly guarded
- Must use all mandatory safeguards below
- Timeout: 60s max for the Claude subprocess
- Must run in background (never block session exit)

## Mandatory Safeguards for Tier 3 Hooks

Put these in a shared guard library (for example `hooks/lib/stop-hook-guard.sh`) so every Tier 3 hook gets them automatically rather than reimplementing them:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib/stop-hook-guard.sh"
stop_hook_init "my-hook-name" --invokes-claude

# HOOK_INPUT, SESSION_ID, TRANSCRIPT are now available
# All guards have passed if execution reaches here
```

### What the guard library provides:

1. **Env var circuit breaker** — Exports `CLAUDE_HOOK_<NAME>=1` before invoking Claude. Checks it at entry and exits if set. Prevents the hook from firing on sessions it spawned.

2. **Lockfile** — PID-based lockfile in `/tmp/claude-hook-locks/`. Prevents concurrent execution of the same hook. Auto-cleaned via trap.

3. **Rate limiter** — Per-hook invocation counter in `/tmp/claude-hook-rates/`. Default: max 5 invocations per hour. Pruned automatically.

### Additional safeguards the hook author must implement:

4. **Content fingerprinting** — Grep the conversation for the hook's own prompt signature. The env var guard can fail if the shell doesn't inherit env vars; this is the fallback.

```bash
CONVERSATION=$(echo "$HOOK_INPUT" | jq -r '.last_assistant_message // empty')
if printf '%s' "$CONVERSATION" | grep -q 'my unique prompt marker'; then
  exit 0
fi
```

5. **Minimum conversation length** — Skip trivial sessions (quick Q&A, accidental exits). A 200-char minimum is a good default.

6. **Background execution** — The Claude invocation must run in background so the hook doesn't block session exit:

```bash
(
  timeout 60 claude -p --dangerously-skip-permissions --no-chrome \
    --model haiku "..." < "$TMPFILE" 2>/dev/null
  rm -f "$TMPFILE"
) &
exit 0
```

7. **Subprocess timeout** — Always wrap `claude -p` in `timeout 60` (or similar). A hung Claude session should not persist indefinitely.

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

`/goal` (Claude Code >= 2.1.139) registers its own session-scoped, prompt-based Stop hook: after each turn a small evaluator model checks the goal condition and re-prompts the session if unmet. This hook is harness-managed, exists only for the life of the goal, and is NOT subject to the tier classification or guard-library requirements above; do not flag it as an unregistered Tier 3 hook, and do not wrap it. It does count as a Claude-invoking loop for budget purposes, so goal-wrapped autonomous runners must sit behind whatever usage gate throttles your other Claude-invoking automation.

## Rules for All Tiers

1. **Always `exit 0` at the end.** A non-zero exit from a stop hook can abort session teardown.
2. **Never retry on failure.** Hooks are fire-and-forget. Log the failure and move on.
3. **Timeouts are mandatory.** Use the `timeout` field in settings.json AND the `timeout` command for subprocesses.
4. **No interactive prompts.** Stop hooks run without a TTY. Any `read` or interactive Claude session will hang.
5. **Redact before transmitting.** Any hook that sends conversation content externally must strip credentials first.

## Debugging Hook Issues

Check these in order:
1. Rate log: `cat /tmp/claude-hook-rates/<hook-name>.log`
2. Lock state: `ls -la /tmp/claude-hook-locks/`
3. Env var: `env | grep CLAUDE_HOOK`
4. Token usage: your session usage log, looking for clusters of sessions started close together

## Adding a New Stop Hook Checklist

Before adding any new Stop hook to settings.json:

- [ ] Classified into Tier 1, 2, or 3
- [ ] Timeout set in settings.json (`"timeout"` field)
- [ ] Ends with `exit 0`
- [ ] If Tier 3: uses the shared guard library with `--invokes-claude`
- [ ] If Tier 3: has content fingerprint fallback
- [ ] If Tier 3: runs Claude in background with `timeout`
- [ ] If Tier 3: has minimum conversation length check
- [ ] If Tier 2 (blocking): block reason is actionable (tells the agent what to fix)
- [ ] Tested manually: `echo '{"session_id":"test","transcript_path":""}' | bash hooks/my-hook.sh`

## Four Failure Modes Worth Generalising

These come from a real set of repo-visibility gates. The lessons apply to any hook that classifies something and then acts on the classification.

1. **Right detection, hardcoded conclusion.** A pre-push hook computed repo visibility correctly, branched on PRIVATE, printed "Private repo, scanned anyway", then seven lines later printed "This is a PUBLIC repo" unconditionally. The repo was told both at once. The instinct on seeing a gate report the wrong category is to debug detection; detection was fine. Read the whole message-emitting path before touching the lookup. Root cause was duplication: two hooks each carried an inline copy of a lookup and its wording that a shared library already provided, so they drifted. The fix is to delete the copies, not to correct them in parallel.

2. **A permanent cache is asymmetric when the gate is conditional.** Visibility was cached forever, justified as "changes once in a repo's lifetime". But the downstream gates blocked ONLY when visibility was PUBLIC, so a repo flipped private to public keeps a stale PRIVATE entry forever and those gates silently switch off. Never cache the value that decides whether a gate runs without an expiry. On lookup failure, fall back to the last known value rather than UNKNOWN, and do NOT refresh the mtime, or one transient failure marks a stale entry fresh for another full TTL. (The general form: a check that silently no-ops looks identical to a check that passes. A token refresh once ran at 0% success for weeks behind a fallback that kept the end state healthy.)

3. **Distribution is part of the fix.** Git hooks are COPIES in each `.git/hooks`, and `init.templateDir` puts them in every clone. Editing the source changes nothing: dozens of existing repos plus the global template kept running the pre-fix copy. An installer that only walks public repos will skip every private one, including the one that exhibited the bug; make sure yours can walk all local repos. After any hook edit, verify by grepping the INSTALLED copies for a marker from the new code, not by reading the source.

4. **Two ways the test for this was itself wrong.** `PATH=/usr/bin:/bin` was used to simulate a CLI being unavailable, but that CLI lives in `/usr/bin`, so the offline path went untested while reporting PASS. Replacing it with real API calls then made the suite flaky when the API returned 503 between two consecutive lookups, failing correct code. Stub the external binary instead. And confirm every new assertion FAILS against the pre-fix code: four of the first-draft cache tests passed against both versions, so they proved nothing.
