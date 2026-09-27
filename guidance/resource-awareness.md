<!-- Load when: server resource checks -->
# Resource Awareness

Shared infrastructure has limits. Find them out before you hit them. Don't memorize numbers, because they change.

## Principle: Discover, Don't Memorize

Server specs change: VMs get resized, processes get added, disks fill up. Never hardcode thresholds in your mental model. **Check before every heavy operation** instead.

## Before Heavy Work

Run these checks before starting builds, installs, large file operations, or anything CPU- or memory-intensive:

```bash
# Memory: is there enough for a build?
free -m

# Disk: is there room for node_modules, build output, logs?
df -h

# What's already running? How many processes, how much memory?
# (Example for PM2; substitute your process manager's equivalent)
pm2 jlist 2>/dev/null | python3 -c "
import sys, json
procs = json.load(sys.stdin)
for p in procs:
    print(f\"{p['name']:20s} {p['pm2_env']['status']:8s} {p['monit']['memory']//1024//1024}MB\")
" 2>/dev/null || pm2 list

# CPU load
uptime
```

If memory is tight (< 500MB free) or disk is low (< 1GB), flag it before you proceed. Don't quietly start a build that will OOM-kill something else.

## Output Size Awareness

Large responses cause problems further down the line:
- Chat notification embeds often truncate at a few thousand characters (for example, ~3,900), and anything past the limit is lost
- Blog or log posts turn into walls of text that nobody reads
- Terminal output floods the user's scrollback

**Keep responses focused.** If you need to output large content (full file listings, long logs, audit results), write it to a file and give the path. Don't dump it into your response.

## Concurrent Job Awareness

On shared infrastructure, other processes are probably running alongside yours:
- **Check before starting resource-intensive work.** Your process manager's list (e.g. `pm2 list`) shows what else is running. If three other agent sessions are active, one `npm install` might push the server over.
- **Check your notification channel** (if you have one) to see whether other agent sessions are active on the same server.
- **Don't spawn parallel builds** on a constrained VM. Sequential builds are slower, but they won't OOM.

## Disk-Heavy Searches on a Production Host

A small production VM has one slow disk shared by every app on it. A filesystem-wide `find /` or `grep -r ~` can saturate it for minutes. CPU sits at ~90% iowait, and any app blocked on a disk read stops accepting connections while its neighbours keep answering. Unscoped searches from agent sessions have taken a public app down this way, with request timeouts for as long as the searches ran. Searching is fine. Unbounded searching on a production host is the problem.

1. **Scope the path first.** Most targets have a known home (process manager state in its own dot-directory, app code in the app's own directory). A scoped search answers in seconds.
2. **If you really need a wide sweep, cap it and time-box it:**
   ```bash
   sudo systemd-run --scope -q -p IOReadBandwidthMax="/dev/sda 20M" timeout 120 find / -xdev -name <file>
   ```
   Check the device name with `lsblk` first.
3. **Don't reach for `ionice -c3`.** It only works with an I/O scheduler that honours priorities (BFQ/CFQ). Cloud VMs commonly run `none` or `mq-deadline` (`cat /sys/block/<dev>/queue/scheduler`), and there idle priority does nothing. The cgroup `io.max` cap above is enforced no matter which scheduler is in use; you can confirm it holds the configured rate with a `dd` read.
4. **Diagnosing a stall:** `vmstat 1 3` (high `wa`, non-zero `b`) plus `ps -eo pid,stat,etime,args | awk '$2 ~ /D/'` lists the processes stuck in or causing disk wait.

## Environment Variable Awareness

Before starting work on any deployed project:
- **Check whether env vars are loaded:** `echo $NODE_ENV`, and confirm `.env` exists
- **Know the difference between a build and a restart:** Static site generators (Next.js, Vite) bake env vars in at build time. Changing `.env` means a full rebuild, not just a process restart
- **Check `MAX_CONCURRENT_JOBS`** or an equivalent throttle setting in the environment before spawning background processes
