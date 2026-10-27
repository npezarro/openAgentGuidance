<!-- Load when: self-deploy loops, restart storms, hook loops -->
# Operational Safety

Prevent feedback loops, restart storms, and cascading failures in automated systems.

## Hook Loop Prevention

Hooks that post automatically (to a blog, a chat channel, or your notification channel) run on every Claude turn. If a failed hook triggers a retry or starts a new Claude session, you get an infinite loop.

**Rules:**
- Hooks must be fire-and-forget. Never retry on failure.
- Hooks must not spawn new Claude sessions unless they have recursion guards.
- Hooks must have timeouts (10s max). A hung webhook should not block the session.
- If a hook fails, log the failure and continue. Do not abort the parent session.

### Stop Hook Safety Framework

Sort every Stop hook into one of three tiers:
- **Tier 1, observation:** logs or posts something and never invokes Claude. Fire-and-forget with a timeout is enough.
- **Tier 2, verification:** runs checks such as tests or linters, and still never invokes Claude.
- **Tier 3, Claude-invoking:** calls `claude -p` or starts a session in some other way. These hooks are the dangerous ones.

Every Tier 3 hook must source a shared guard library rather than carrying its own inline copy of the guards. The library should provide:
- **Env var circuit breaker:** the hook sets a marker variable such as `IN_STOP_HOOK=1` before it invokes Claude, and exits right away if that marker is already set.
- **PID lockfile:** only one instance of the hook can run at a time.
- **Per-hour rate limiter:** a hard cap on invocations per hour, so a guard that fails still has a ceiling.

**Lesson:** one Stop hook ran a session scorer (`claude -p` with a small model) every time a session exited. When the scorer's own session exited, it re-triggered the hook. That produced thousands of recursive sessions in a day and used most of a week's token budget. The fix was an env var guard plus a content pattern match, and those guards were then standardised in the shared library.

## Concurrent Sessions in One Checkout

If several agent sessions share one working tree, they overwrite each other's edits, branch switches and stashes.
- **Use one worktree per session** (`git worktree add ../<repo>-<task> -b claude/<task>`). Never run two sessions against the same checkout.
- **Use real locks for singletons.** Anything that must run once at a time (a deploy, a migration, a sync job) needs an actual lock, for example `flock`. A convention like "check whether someone else is doing it" is not a lock.
- **Diagnostic order when changes keep reverting:** first look for another session or process writing to the same tree, then check for a generator or sync job that regenerates the file, and only after that suspect your own edit.

## Job Recovery Safety

When a service recovers persisted jobs on startup:
- **PID alive:** Re-attach and monitor for completion. Do not re-execute.
- **PID dead:** Extract partial output, mark the job as failed, and notify the user. Do not re-run it automatically.
- **Multi-turn job partially complete:** Re-queue from the last completed turn, not from scratch.

**Never** automatically re-execute a failed job. The job itself may have caused the failure (for example, it deployed the service that was running it). Automatic re-execution would repeat the failure.

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

1. **Gather and confirm first:** Build the full list of items to be removed and show it to the user for confirmation before deleting anything. This catches mistakes in date ranges, filters, or account selection.
2. **Restrict to safe content types:** Only auto-generated or temporary content is eligible for bulk deletion (for example, unlisted short clips or draft posts). Never bulk-delete public, private, or manually curated content.
3. **Filter by metadata:** Use duration, privacy status, date range, and ownership filters to exclude anything that shouldn't be touched. For example, when deleting short clips, filter to <=90s so full-length videos are skipped.

**Why:** Platform deletions are irreversible. A wrong date range or a missing filter can wipe out manually curated content. The confirmation step and the content-type restriction mean only disposable items are at risk.

## Verify Before Asserting

Don't claim the user did something (submitted an application, sent an email, published a post) unless an authoritative source confirms it. Prep materials, drafts, or related files do NOT show that the action was completed.

**Why:** An agent once told someone the user had applied to a role because prep materials existed in cloud storage. The application had never been submitted, so incorrect context reached a third party.

**How to verify:**
- **Applications/emails:** Check the sent folder or the confirmation email.
- **Blog posts:** Check the CMS or the live URL.
- **Deploys:** Check process manager status and server logs.
- **Git pushes:** Check `git log origin/main` or `gh pr list`.
- **Any user action:** Look for the completion artifact, not the preparation artifact.

## Rule Digest

One line per lesson.

- **Self-deploy loop prevention:** Never deploy or restart a service from inside a job that service spawned.
- **Restart-recovery loop:** If a deploy is triggered from outside while a recoverable job is running, it can loop forever (deploy, kill, restart, recover, deploy). Cap recovery attempts per job, and defer deploys while jobs are active.
- **Restart storm detection:** More than 5 restarts in under 5 minutes is a storm. Run `pm2 stop <name>` (or your process manager's equivalent) first, read the logs, fix the root cause, then start it again.
- **Restart storm metric:** Base storm detection on a counter that resets, such as PM2's `unstable_restarts`. Do not use a cumulative counter like `restart_time`, which never resets and eventually flags every healthy long-lived process.
- **`pipefail` + `grep -c` silent failure:** Use `grep -c 'pattern' || true`. `grep -c` already prints `0` when nothing matches, so the exit code only needs suppressing; adding a fallback `echo 0` prints the count twice.
- **A pipeline reports the LAST command's exit code:** Never end a pipeline with `&& echo "<success>"`, because the message can print even when an earlier stage failed.
- **A blanket rename across executable files is a destructive edit:** A repo-wide `sed` looks like a rename but behaves like a rewrite. Scope it to the files you have reviewed and check the diff.
- **Programmatic edits to a shared config must preserve formatting:** Rewriting a JSON config with `json.dump(...)` reformats the **whole file**. Make targeted edits, or keep the original key order and indentation.
- **Regenerating from a source of truth deletes whatever exists only live:** When a live artifact (crontab, DNS zone, firewall ruleset, service config) is generated from a checked-in source, the source falls **behind** as soon as someone edits the live copy. Diff live against source and back-port the differences before you regenerate.
- **Headless Claude CLI needs an explicit permission mode:** Every `claude -p` run without a TTY (cron, subprocess, server route, background job) must set a permission mode that cannot block on an interactive prompt, such as `--dangerously-skip-permissions` in a sandbox or a scoped allowlist. Otherwise it hangs or exits silently.
- **Claude CLI rate-limit detection in service wrappers:** After collecting stdout from any `claude -p` subprocess, check it for rate-limit patterns before treating it as valid output.
- **`set -e` makes post-hoc exit-code capture dead code:** Capture the exit code in the same statement (`cmd || rc=$?`) so `set -e` never sees the failure.
- **`set -e` kills functions that end in a guarded `&&`:** Write `if [ -n "$VERBOSE" ]; then log "$*"; fi` instead (an `if` whose condition is false returns 0), or end the function with `|| true` or an explicit `return 0`.
- **Cron output redirected into root-owned dirs dies silently:** A non-root crontab line that redirects into `/var/log/` fails before the command even runs. Log to a directory the cron user owns.
- **Unattended jobs that take irreversible external actions:** A job that spends, sends, cancels or files something needs five guards: a check on identity, a cap on magnitude, an idempotency state file, a `--dry-run` that stops just before the irreversible call, and a report on every outcome.
- **Health monitor self-exclusion:** Any monitoring daemon that calls `pm2 jlist` and loops over processes must exclude its own process name from the health checks.
- **Shared poller resource gates must be scoped to the executing machine:** If several machines share a polling function, a memory or disk gate must measure the host that will run the work. Add a flag such as `skipMemoryWatchdog` for callers on other hosts.
- **Never leave a repo's main checkout on a merged feature branch:** First confirm the current branch is a strict subset of `origin/<default>` (`git diff origin/main HEAD --stat` should be empty or show only default-branch changes). Then run `git checkout main && git merge --ff-only origin/main`.
- **Never inline single-quoted code in `ssh host 'block'`:** The whole remote command is already wrapped in single quotes, so any single quote inside the block ends the string. Use a quoted heredoc (`ssh host bash -s <<'EOF'`) or copy a script over and run it.
- **Use the SSH config alias, not a bare IP:** `ssh x.x.x.x` skips the `Host` entry that carries the correct user and key, and fails with "Permission denied (publickey)".
- **Audit the Claude Code version on every host before upgrading:** Pin fan-out and search defaults first, because new versions can change them.
- **Unpinned Docker installs make rebuilds a silent no-op:** Cached layers keep the old version. Pin versions so a rebuild actually changes something. Also, `docker exec` runs as root by default, so probing a user-installed CLI's auth that way false-alarms; pass `-u <user>`.
- **Sandbox strict network allowlists may not work everywhere:** Settings such as `sandbox.network.strictAllowlist` can break inside Docker bridge networks or on WSL hosts. Test on the actual host before you rely on them.
- **A recovery action that cannot fix the condition must be gated on classifying the condition first:** Restarting a process cannot fix an expired credential or a full disk. Find out what is wrong before you act.
- **A retry cap must not be spent on an infrastructure outage:** A bounded-retry loop (MAX_ATTEMPTS, cron every N minutes) permanently kills every in-flight job when a dependency is down longer than cap x interval. Don't count outage failures against the cap.
- **A 429 or 503 from a dependency is about its quota, not about the row:** Refund the retry attempt.
- **A watchdog that kills processes out of band must record a kill reason:** Otherwise the death looks like a normal exit and gets recorded as success.
- **A two-signal liveness check is only as strong as its weaker signal:** If extraction of one signal silently returns empty, the check is weakened without any warning. Treat an empty signal as a failure.
- **A recurring job that emails only on success makes an outage look like a quiet day:** Report every run, or alert when an expected report is missing.
- **A boot-only reaper misses jobs stranded inside a process that is still running:** Reap on a schedule too, not just at startup.
- **A skipped step reported as informational text will be skipped indefinitely:** Make skips fail or surface as warnings that need action.
- **Gate a destructive remedy on a positive match:** Never gate it on "not one of the known-benign cases".
- **On WSL2, one heavy session can OOM the whole VM:** That kills every session and every service at once. Cap WSL memory in `.wslconfig` (it takes effect after `wsl --shutdown`) and keep concurrent heavy builds to a minimum.
- **A WSL start-at-boot scheduled task must run as the user who owns the distro (S4U logon), not SYSTEM:** Under SYSTEM it starts the wrong instance or nothing at all.
- **`systemctl --user` fails on hosts with no user D-Bus (common on WSL):** Write heal and automation scripts so they don't need the bus, using cron, the process manager, or direct commands.
- **A long-lived PM2 daemon can desync so that `pm2 restart` reports "Process <id> not found" for every process:** Only `pm2 update` or `pm2 resurrect` fixes it. That restarts all services, so a human should approve it.
- **A benign-skip guard on a nightly job needs a consecutive-skip backstop:** Alert after N skips in a row, so a guard stuck on "skip" doesn't disable the job forever.
- **A stale Claude Code CLI can accept a newer `--model` id and quietly serve an older model:** Check the model actually served (`--output-format json`, read `modelUsage`) on the exact host and PATH in use. Don't stop at confirming the flag was accepted, because login shells can resolve a different `claude` than interactive ones.
- **A headless `claude -p` batch caller needs three things:** a timeout sized for real concurrency, an explicit `--model` and `--effort`, and a non-zero exit if any item fails.
- **For a logical delete that updates an index and also removes a resource irreversibly, write the index first and remove the resource last:** A crash between the two steps then leaves an orphaned resource you can recover, instead of an index row that is stuck and can't be deleted.
- **Clear a retry/backoff cooldown with a success check right after the corrective action, not only on the next scheduled poll:** Otherwise a success that is consumed instantly still waits out the old cooldown before the system can respond to the next need.
