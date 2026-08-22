<!-- Load when: server resource checks -->
# Resource Awareness

Shared infrastructure has limits. Discover them before you hit them; don't memorize numbers that change.

## Principle: Discover, Don't Memorize

Server specs change (VMs get resized, processes get added, disk fills up). Never hardcode thresholds in your mental model. Instead, **check before every heavy operation**.

## Before Heavy Work

Run these checks before starting builds, installs, large file operations, or anything CPU/memory-intensive:

```bash
# Memory: is there enough for a build?
free -m

# Disk: is there room for node_modules, build output, logs?
df -h

# What's already running? How many processes, how much memory?
pm2 jlist 2>/dev/null | python3 -c "
import sys, json
procs = json.load(sys.stdin)
for p in procs:
    print(f\"{p['name']:20s} {p['pm2_env']['status']:8s} {p['monit']['memory']//1024//1024}MB\")
" 2>/dev/null || pm2 list

# CPU load
uptime
```

Substitute your own process manager for `pm2` if you use a different one (`systemctl list-units --type=service`, `docker stats --no-stream`, `supervisorctl status`).

If memory is tight (< 500MB free) or disk is low (< 1GB), flag it before proceeding. Don't silently start a build that will OOM-kill something else.

## Output Size Awareness

Large responses create problems downstream:
- Chat and webhook embeds truncate at a few thousand characters; anything beyond is silently lost
- Long-form posts become walls of text that nobody reads
- Terminal output floods the user's scrollback

**Keep responses focused.** If you need to output large content (full file listings, extensive logs, audit results), write it to a file and reference the path. Don't dump it into your response.

## Concurrent Job Awareness

On shared infrastructure, you're probably not the only process running:
- **Check before starting resource-intensive work.** A process list shows what else is running. If three other agent sessions are active, an `npm install` might push the server over.
- **Check your shared job log** (a notification channel, a status file, a `ps` sweep) to see if other agent sessions are active on the same host.
- **Don't spawn parallel builds** on a constrained VM. Sequential is slower but won't OOM.

## Environment Variable Awareness

Before starting work on any deployed project:
- **Check if env vars are loaded:** `echo $NODE_ENV`, confirm `.env` exists
- **Understand the build/restart distinction:** static site generators and bundlers (Next.js, Vite) bake env vars in at build time. Changing `.env` requires a full rebuild, not just a process restart
- **Check `MAX_CONCURRENT_JOBS`** or the equivalent throttle setting in the environment before spawning background processes
