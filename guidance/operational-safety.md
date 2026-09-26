<!-- Load when: self-deploy loops, restart storms, hook loops -->
# Operational Safety

Prevent feedback loops, restart storms, and cascading failures in automated systems.

## Hook Loop Prevention

Auto-posting hooks (blog, notification channel) run on every Claude turn. If a hook failure triggers a retry or a new Claude session, you get an infinite loop.

**Rules:**
- Hooks must be fire-and-forget. Never retry on failure.
- Hooks must not spawn new Claude sessions without recursion guards.
- Hooks must have timeouts (10s max). A hung webhook should not block the session.
- If a hook fails, log the failure and continue. Do not abort the parent session.

### Stop Hook Safety Framework

Classify every Stop hook by tier before writing it:

- **Tier 1, observation:** logs or posts, never invokes Claude. Low risk.
- **Tier 2, verification:** runs checks (tests, lint, status) and reports. Must not invoke Claude.
- **Tier 3, Claude-invoking:** runs `claude -p` or otherwise starts a session. High risk: the child session's own exit fires the Stop hook again.

Every Tier 3 hook must use a shared guard library rather than its own ad-hoc checks. The guard should provide:

1. **Env var circuit breaker:** the hook sets a variable (e.g. `IN_STOP_HOOK=1`) before invoking Claude and exits immediately if it is already set.
2. **PID lockfile:** only one instance runs at a time.
3. **Per-hour rate limiter:** a hard cap on invocations per hour, so a guard bug degrades into a slow leak instead of a storm.

Add a content pattern match as well, so the hook ignores sessions it created itself.

**Lesson:** A Stop hook that ran a session scorer (`claude -p` with a small model) on every session exit re-triggered itself on the scorer's own exit. It produced thousands of recursive sessions in one day and consumed most of a week's token budget. Any hook that invokes Claude is a potential fork bomb until proven otherwise.

## Concurrent Sessions in One Checkout

Never run two agent sessions in the same working tree. Give each session its own git worktree, and protect singleton resources (a deploy, a migration, a shared state file) with a real lock, not a convention. If a change keeps mysteriously reverting, suspect another session sharing the checkout before debugging the code.

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

**Why:** Preparation artifacts are routinely mistaken for completion. Asserting an action happened because the drafts exist leads to incorrect context being passed on to other people.

**How to verify:**
- **Applications/emails:** Check the sent mail folder for the sent message or a confirmation
- **Blog posts:** Check the live URL
- **Deploys:** Check the process manager status and server logs on the host
- **Git pushes:** Check `git log origin/main` or `gh pr list`
- **Any user action:** Look for the completion artifact, not the preparation artifact

## Rule Digest

One line per lesson.

- **Self-deploy loop prevention:** Never deploy or restart a service from within a job that service spawned.
- **Restart-recovery loop:** A deploy triggered externally while a recoverable job runs can loop forever (deploy, kill, restart, recover, deploy); cap recovery attempts per job and defer deploys while jobs are active.
- **Restart storm detection:** More than 5 restarts in under 5 minutes is a storm: stop the process first (e.g. `pm2 stop <name>`), read the logs, fix the root cause, then start it again.
- **Key storm detection on the crash-loop counter, not the lifetime counter:** A cumulative restart count never resets, so it flags healthy long-lived services; use a counter that resets on stable uptime (e.g. PM2's `unstable_restarts`, not `restart_time`).
- **Bash `pipefail` + `grep -c` silent failure:** Use `grep -c 'pattern' || true`. `grep -c` already outputs `0` on no match; it just needs the exit code suppressed, not a fallback echo.
- **A pipeline reports the LAST command's exit code:** Never end a pipeline with `&& echo "<success>"`; the success message can print after an earlier stage failed.
- **Blanket rename across executable files is a destructive edit:** A repo-wide `sed` looks like a rename and behaves like a rewrite. Scope it, review the diff, and run the affected code.
- **Programmatic edits to a shared config must preserve formatting:** Rewriting a JSON config with `json.dump(...)` reformats the whole file. Make a targeted edit or preserve the original indentation and key order.
- **Regenerating from a source of truth deletes whatever only exists live:** When a live artifact (crontab, DNS zone, firewall ruleset, service config) is generated from a checked-in file, the source drifts behind the moment anyone edits the live copy. Diff live against source and fold live-only entries back in before regenerating.
- **Headless Claude CLI needs a non-interactive permission mode:** Every `claude -p` invocation without a TTY (cron, subprocess, server route, background job) must pass `--dangerously-skip-permissions` or an explicit tool allowlist, or it hangs waiting on a prompt nobody will answer.
- **Claude CLI rate limit detection in service wrappers:** After collecting stdout from any `claude -p` subprocess, check for rate limit patterns before treating the output as valid.
- **`set -e` makes post-hoc exit-code capture dead code:** Capture the exit code in the same statement (`cmd || rc=$?`) so `set -e` never sees the failure.
- **`set -e` kills functions ending in a guarded `&&`:** Use `if [ -n "$VERBOSE" ]; then log "$*"; fi` (an `if` whose condition is false returns 0), or end the function with `|| true` or an explicit `return 0`.
- **Cron output redirects into root-owned dirs die silently:** A non-root crontab line that redirects into `/var/log/` fails to open the file and the job never runs, leaving no trace. Redirect into a user-owned log directory.
- **Unattended jobs that take irreversible external actions:** A job that spends, sends, cancels or files needs five guards: gate on identity, cap the magnitude, an idempotency state file, a `--dry-run` that stops just before the irreversible call, and a report on every outcome.
- **Health monitor self-exclusion:** Any monitoring daemon that iterates over processes (e.g. `pm2 jlist`) must exclude its own process name from health checks.
- **Shared poller resource gates must be scoped to the executing machine:** A memory or disk gate in shared polling code must measure the machine that will run the work; add a flag (e.g. `skipMemoryWatchdog`) for pollers that dispatch elsewhere.
- **A repo's main checkout must never be left on a merged feature branch:** Verify the current branch is a strict subset of `origin/<default>` first (`git diff origin/main HEAD --stat` should be empty or default-only), then `git checkout main && git merge --ff-only origin/main`.
- **Never inline single-quoted code in `ssh 'block'`:** `ssh host 'big block ...'` wraps the whole remote command in single quotes, so any single quote inside breaks it. Pipe a script via a quoted heredoc (`ssh host bash -s <<'EOF'`) instead.
- **Use the SSH config alias, not a bare IP:** The alias carries the correct user and key; `ssh <ip>` falls back to defaults and fails with "Permission denied (publickey)".
- **Audit the Claude Code version on every host and pin fan-out/search defaults before upgrading:** Hosts drift apart silently, and a new version can change defaults under running automation.
- **Pin versions in Docker installs:** An unpinned install makes a rebuild a silent no-op (cached layer) or an unplanned upgrade. Run health probes as the service user, not root, or auth checks false-alarm.
- **A recovery action that cannot fix the condition must be gated on classifying the condition first.**
- **A retry cap must not be spent on an infrastructure outage:** A bounded-retry loop (MAX_ATTEMPTS, cron every N minutes) permanently kills every in-flight job when the dependency is down longer than cap x interval.
- **A 429 or 503 from a dependency is a verdict on its quota, not on the row:** Refund the retry attempt.
- **A watchdog that kills out of band must set a kill reason,** or the death reads as success.
- **A two-signal liveness check is only as strong as its weaker signal:** A silently-empty extraction degrades it to one signal without warning; treat "no data" as a failure, not a pass.
- **A recurring job that reports only on success makes an outage indistinguishable from a quiet day:** Report failures and "nothing to do" explicitly.
- **A boot-only reaper misses jobs stranded inside a still-running process:** Reap on a schedule, not just at startup.
- **A skill or script that reports a skipped step as informational text will have that step skipped indefinitely:** A required step that did not run must fail loudly.
- **A destructive remedy must be gated on a positive match,** never on "not one of the known-benign cases".
- **One runaway agent session can exhaust host memory and take down every co-hosted service:** Cap memory at the VM/container level and leave headroom for the services that share the host.
- **A desynced process-manager daemon can fail every restart with "process not found":** For PM2, only `pm2 update` / `pm2 resurrect` fixes it, and that restarts all services, so it is a human decision, not an automated remedy.
- **A benign-skip guard on a nightly job needs a consecutive-skip backstop:** Alert after N skips in a row, or the skip becomes a permanent silent disable.
