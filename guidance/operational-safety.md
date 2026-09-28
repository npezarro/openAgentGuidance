<!-- Load when: self-deploy loops, restart storms, hook loops -->
# Operational Safety

Prevent feedback loops, restart storms, and cascading failures in automated systems.

## Hook Loop Prevention

Auto-posting hooks (blog, chat, notification) run on every Claude turn. If a hook failure triggers a retry or a new Claude session, you get an infinite loop.

**Rules:**
- Hooks must be fire-and-forget. Never retry on failure.
- Hooks must not spawn new Claude sessions without recursion guards.
- Hooks must have timeouts (10s max). A hung webhook should not block the session.
- If a hook fails, log the failure and continue. Do not abort the parent session.

### Stop Hook Safety

Sort Stop hooks into three tiers:
- **Tier 1, observation:** logs, metrics, notifications. No Claude calls.
- **Tier 2, verification:** checks that read state and report. No Claude calls.
- **Tier 3, Claude-invoking:** anything that runs `claude -p` or starts a session. These need all three guards below.

Every Tier 3 hook must source one shared guard library rather than carrying its own copy. The library provides:
1. **Env var circuit breaker:** the hook sets a variable (for example `IN_STOP_HOOK=1`) before calling Claude and exits immediately if it is already set.
2. **PID lockfile:** only one instance runs at a time.
3. **Per-hour rate limiter:** a hard cap on invocations per hour.

**Lesson:** a Stop hook that ran a session scorer (`claude -p` with a small model) on every session exit re-triggered itself, because the scorer's own session exit fired the same hook. It spawned thousands of recursive sessions in one day and consumed most of a week's token budget before anyone noticed. A Stop hook that invokes Claude without a recursion guard is a loop by construction.

## Concurrent Sessions in One Checkout

Two sessions working in the same checkout will overwrite each other's edits, switch branches under each other, and revert each other's work.
- **Shared working tree:** give every session its own git worktree. Never run two sessions in one checkout.
- **Singleton resources** (a deploy, a migration, a cron-owned file): use a real lock (`flock` or a lockfile with PID check), not a convention.
- **When something keeps reverting:** check for another live session in the same tree first, before debugging your own code.

## Job Recovery Safety

When a service recovers persisted jobs on startup:
- **PID alive:** Re-attach and monitor for completion. Do not re-execute.
- **PID dead:** Extract partial output, mark as failed, notify the user. Do not re-run automatically.
- **Multi-turn job partially complete:** Re-queue from the last completed turn, not from scratch.

**Never** automatically re-execute a failed job. The failure may have been caused by the job itself (e.g., it deployed the service that runs it). Automatic re-execution would repeat the failure.

## Postmortem Template

When a feedback loop or restart storm occurs, document it:

```
### Incident: [Short description]
**Date:** YYYY-MM-DD
**Duration:** How long the loop ran before intervention
**Trigger:** What action started the cascade
**Mechanism:** How the loop sustained itself
**Resolution:** How the loop was broken
**Prevention:** What guard was added to prevent recurrence
```

Add the entry to the project's `context.md` under a "Known Issues" or "Incident Log" section so future sessions are aware.

## Irreversible Content Deletion

When bulk-deleting content on external platforms (video hosts, social media, cloud storage), apply strict safeguards:

1. **Gather and confirm first:** Build the full list of items to be removed and present it to the user for confirmation before deleting anything. This catches mistakes in date ranges, filters, or account selection.
2. **Restrict to safe content types:** Only auto-generated or temporary content is eligible for bulk deletion (e.g., unlisted short clips, draft posts). Never bulk-delete public, private, or manually curated content.
3. **Filter by metadata:** Apply duration, privacy status, date range, and ownership filters to exclude anything that shouldn't be touched (e.g., skip full-length videos when deleting shorts by filtering <=90s).

**Why:** Platform deletions are irreversible. A wrong date range or missing filter can wipe out manually curated content. The confirmation step and content-type restriction ensure only disposable items are at risk.

## Verify Before Asserting

Don't claim the user did something (submitted an application, sent an email, published a post) unless you can verify it through an authoritative source. The existence of prep materials, drafts, or related files does NOT confirm the action was completed.

**Why:** An agent asserted the user had applied for a role because prep materials existed in cloud storage. The application was never submitted, and the wrong context was passed on to a third party.

**How to verify:**
- **Applications/emails:** Check the sent folder for confirmations
- **Blog posts:** Check the CMS or the live URL
- **Deploys:** Check process manager status and server logs
- **Git pushes:** Check `git log origin/main` or `gh pr list`
- **Any user action:** Look for the completion artifact, not the preparation artifact

## Rule Digest

One line per lesson.

- **Self-deploy loop prevention:** Never deploy or restart a service from within a job that service spawned.
- **Restart-recovery loop:** A deploy triggered externally while a recoverable job runs can loop forever (deploy, kill, restart, recover, deploy); cap recovery attempts per job and defer deploys while jobs are active.
- **Restart storm detection:** More than 5 restarts in under 5 minutes is a storm: `pm2 stop` it first, read the logs, fix the root cause, then start it again.
- **Key storm detection on the right counter:** Use PM2's `unstable_restarts` (crash-loop counter that resets), not `restart_time` (cumulative, never resets), or every long-lived process eventually looks like a storm.
- **Bash `pipefail` + `grep -c` silent failure:** Use `grep -c 'pattern' || true`. `grep -c` already outputs `0` on no match; it just needs the exit code suppressed, not a fallback echo.
- **A pipeline reports the LAST command's exit code:** Never end a pipeline with `&& echo "<success>"`; the message proves nothing about earlier stages.
- **A blanket rename across executable files is a destructive edit:** A repo-wide `sed` looks like a rename and behaves like a rewrite. Scope it to the files you intend, review the diff, and run the tests before committing.
- **Programmatic edits to a shared config must preserve formatting:** Rewriting a JSON config with `json.dump(...)` reformats the whole file. Make a targeted edit or preserve the original indentation and key order.
- **Regenerating from a source of truth deletes whatever only exists live:** When a live artifact (crontab, DNS zone, firewall ruleset, service config) is generated from a checked-in file, the source drifts behind as soon as anyone edits live. Diff live against source and back-port before regenerating.
- **Headless Claude CLI needs an explicit permission mode:** Every `claude -p` invocation without a TTY (cron, subprocess, server route, background job) must pass `--dangerously-skip-permissions` or an equivalent non-interactive permission setting, or it hangs waiting for approval.
- **Claude CLI rate-limit detection in service wrappers:** After collecting stdout from any `claude -p` subprocess, check for rate-limit patterns before treating the output as valid.
- **`set -e` makes post-hoc exit-code capture dead code:** Capture the exit code in the same statement (`cmd || rc=$?`) so `set -e` never sees the failure.
- **`set -e` kills functions ending in a guarded `&&`:** Write `if [ -n "$VERBOSE" ]; then log "$*"; fi` (a false `if` returns 0), or end the function with `|| true` or an explicit `return 0`.
- **Cron output redirects into root-owned dirs die silently:** A non-root crontab line redirecting into `/var/log/` fails before the job runs. Log to a user-writable path.
- **Unattended jobs that take irreversible external actions:** A job that spends, sends, cancels or files needs five guards: gate on identity, cap the magnitude, an idempotency state file, a `--dry-run` that stops just before the irreversible call, and a report on every outcome.
- **Health monitor self-exclusion:** Any monitoring daemon that iterates `pm2 jlist` must exclude its own process name from health checks.
- **Shared poller resource gates must be scoped to the executing machine:** A memory or disk gate in a poller shared across hosts must check the host that will run the work, with a flag to skip the gate where it does not apply.
- **A repo's main checkout must never be left on a merged feature branch:** Verify the branch is a strict subset of `origin/<default>` (`git diff origin/main HEAD --stat` empty or default-only), then `git checkout main && git merge --ff-only`.
- **Never inline single-quoted code in `ssh host 'block'`:** The whole remote command is already single-quoted, so inner quotes break it. Pipe a script over stdin (`ssh host 'bash -s' < script.sh`) instead.
- **Use SSH config aliases, not bare IPs:** `ssh <ip>` skips the `Host` entry that carries the correct user and key, and fails with "Permission denied (publickey)".
- **Audit the Claude Code version on every host before upgrading:** Pin fan-out and search defaults explicitly so an upgrade doesn't silently change behavior.
- **Unpinned Docker installs make rebuilds a silent no-op:** Pin versions so a rebuild actually changes something. Probes via `docker exec` run as root by default and can false-alarm on auth; exec as the user the service runs as.
- **Strict network allowlist sandboxing may not work in Docker bridges or on WSL:** Test it on the actual host before relying on it.
- **Classify before recovering:** A recovery action that cannot fix the condition must be gated on classifying the condition first.
- **A retry cap must not be spent on an infrastructure outage:** A bounded-retry loop (MAX_ATTEMPTS, cron every N minutes) permanently kills every in-flight job when a dependency is down longer than cap x interval.
- **A 429 or 503 is a verdict on the dependency's quota, not on the row:** Refund the retry attempt.
- **A watchdog that kills out of band must set a kill reason:** Otherwise the death reads as success.
- **A two-signal liveness check is only as strong as its weaker signal:** A silently empty extraction degrades it without warning; treat an empty signal as a failure, not a pass.
- **A recurring job that reports only on success makes an outage indistinguishable from a quiet day:** Report failures and skips too.
- **A boot-only reaper misses jobs stranded inside a still-running process:** Reap on a timer, not only at startup.
- **A skipped step reported as informational text will stay skipped forever:** Make skipped steps fail or warn loudly.
- **A destructive remedy must be gated on a positive match:** Never gate it on "not one of the known-benign cases".
- **One Claude Code session on WSL2 can OOM the whole VM:** That kills every session and every service at once. Cap WSL memory in `.wslconfig` (requires `wsl --shutdown` to apply) and watch per-session memory.
- **WSL start-at-boot scheduled tasks must run as the distro-owning user (S4U), not SYSTEM.**
- **`systemctl --user` may be unavailable on WSL (no user D-Bus):** Keep healing and automation bus-free (cron, PM2, plain scripts).
- **A desynced PM2 God daemon makes `pm2 restart` fail "Process <id> not found" for every process:** Only `pm2 update` or `pm2 resurrect` fixes it, and that touches all services, so it is a human decision.
- **A benign-skip guard on a nightly job needs a consecutive-skip backstop:** Alert after N consecutive skips.
- **A stale Claude Code CLI can accept a newer `--model` id and silently serve an older model:** Verify the served model (`--output-format json`, read `modelUsage`) on the exact host and PATH in use, not just that the flag was accepted; login shells can resolve a different `claude` binary than interactive ones.
- **Headless `claude -p` batch callers:** Size the timeout to real concurrency (fixed timeouts silently kill large prompts), pin `--model` and `--effort` explicitly, and exit non-zero on any item's failure, including empty stdout.
