<!-- Load when: writing or debugging a shell script that has to run on both Linux/WSL hosts and a Mac -->
# Shell Portability Across Linux Hosts and the Mac

Shared scripts often run on Linux or WSL (bash 5) *and* on a Mac, where `/bin/bash` is still **bash 3.2.57**. Apple froze it at the last GPLv2 release. Homebrew's newer bash may be installed, but a `#!/usr/bin/env bash` script can still get the system one when a LaunchAgent, a cron job or a plain `bash script.sh` call resolves it.

A bash-5-only construct does not degrade gracefully on the Mac. The script fails to **parse**, so nothing in it runs, and that includes the parts that would have reported the failure.

## Check it, do not assume it

Running `bash -n script.sh` under `/bin/bash` is the whole test, and it costs nothing. Sweep the directory before shipping:

```sh
for f in scripts/*.sh; do out=$(/bin/bash -n "$f" 2>&1); [ -n "$out" ] && echo "FAIL $f: $out"; done
```

A clean sweep proves nothing until you have seen it fail once. Write a broken construct into a scratch file and confirm the sweep catches it.

## Known traps

- **A bare `case` pattern inside `$( )` breaks bash 3.2.** Its command-substitution parser counts parentheses and takes the `)` that closes a case pattern as the one that closes the `$(`. The script dies with `syntax error near unexpected token ;;` before it does anything. bash 5 parses it either way, so it ships without anyone noticing and a script you depend on just stops working on one host. Fix it with the POSIX-legal leading `(`: `case "$x" in (*foo*) ...;; esac`. It is valid everywhere and required on the Mac.
- **`readlink -f`, `sed -i`, `date -d`, `stat -c`** are GNU spellings, and BSD userland handles them differently. Use `sed -i.bak` or `python3`, or test for `gsed`/`gdate`.
- **`${var,,}` / `${var^^}`** (case conversion) need bash 4+. Use `tr`.
- **Associative arrays (`declare -A`)** need bash 4+. No bash 3.2 fallback is worth writing, so restructure the script or use python3.
- **`/proc`** does not exist on darwin. Use `ps`.
- **`timeout N command grep ...` doesn't get you past a shadowed `grep` function; it fails outright.** `command` is a shell builtin, not a binary on `$PATH`. `timeout`, `xargs` and `env` run a program and do not interpret shell syntax, so they find no `command` executable and the call exits 127. Behind `2>/dev/null` that looks exactly like a clean sweep with zero matches. Call the real binary by absolute path (`/usr/bin/grep`) instead, and always run a positive control before you trust an empty result.

## Silent-success traps

### `python3 - <<PY` reads the PROGRAM from stdin, so data piped into it goes nowhere

`python3 - <<'PY' ... PY` takes its *program* from stdin. Anything piped into the same command (`build_patch | python3 - "$file" <<'PY'`) never reaches `sys.stdin.read()` or `json.load(sys.stdin)` inside the heredoc, which sees nothing. It fails by looking like it worked: exit 0, no error, and the intended write never happens. Fix: pass the data as an argument (`python3 - "$file" "$patch" <<'PY'`, read via `sys.argv`), or write the program to a temp file so stdin stays free.

### rclone filters: first match wins, and a slashless `--include` matches a basename at any depth

An age-based prune (`rclone delete --min-age 45d --include '*.db.gz'`) can delete a file with the same extension in a subdirectory you never meant to touch. A slashless `--include` matches the basename at any depth, so `archive/foo.db.gz` matches `*.db.gz` just as a top-level file does. rclone evaluates filters in order and the first match wins, so an `--exclude` placed AFTER the matching `--include` never runs. Fix: put the directory-scoped `--exclude 'subdir/**'` BEFORE the `--include`, and give any directory that needs a different retention window its own prune call. Check this again whenever a new file type shows up in a directory that an existing age-based prune already sweeps.
