<!-- Load when: writing or debugging a shell script that has to run on both Linux/WSL hosts and a Mac -->
# Shell Portability Across Linux Hosts and the Mac

Shared scripts often run on Linux or WSL hosts (bash 5) *and* on a Mac, where
`/bin/bash` is still **bash 3.2.57**. Apple froze it at the last GPLv2 release.
A `#!/usr/bin/env bash` script started by a LaunchAgent, a cron job or a
`bash script.sh` call may pick up that system bash, not Homebrew's newer one.

A bash-5-only construct does not degrade on the Mac. The script fails to **parse**,
so nothing in it runs, including the parts that would have reported the failure.
bash 5 on Linux parses the same file without complaint, so the bug ships unnoticed,
and a workflow that depends on the script quietly stops working on the Mac.

## Check it, do not assume it

The whole test is `bash -n script.sh` under `/bin/bash`, and it costs nothing. Sweep the
directory before shipping:

```sh
for f in scripts/*.sh; do out=$(/bin/bash -n "$f" 2>&1); [ -n "$out" ] && echo "FAIL $f: $out"; done
```

A clean sweep proves nothing until you have seen it fail once. Write the broken
construct into a scratch file and confirm the sweep catches it.

## Known traps

- **A bare `case` pattern inside `$( )` breaks bash 3.2.** Its command-substitution
  parser counts parentheses, so it reads the `)` that closes a case pattern as the one
  that closes the `$(`. The script dies with `syntax error near unexpected token ;;`.
  Balance it with the POSIX-legal leading `(`:
  `case "$x" in (*foo*) ...;; esac`. This works everywhere and is required on the Mac.
- **`readlink -f`, `sed -i`, `date -d` and `stat -c`** are GNU spellings, and BSD
  userland differs. Use `sed -i.bak` or `python3`, or test for `gsed`/`gdate`.
- **`${var,,}` / `${var^^}`** (case conversion) need bash 4+. Use `tr`.
- **Associative arrays (`declare -A`)** need bash 4+. No bash 3.2 fallback is worth
  writing, so restructure the script or use python3.
- **`/proc`** does not exist on darwin. Use `ps`.
- **`timeout N command grep ...` fails outright; it does not skip a shadowed `grep` function.**
  `command` is a shell builtin, not a binary on `$PATH`. `timeout`, `xargs` and `env` run a
  program and do not interpret shell syntax, so they find no `command` executable and the
  call exits 127. With `2>/dev/null` on the end, this looks exactly like a clean sweep with
  zero matches. Call the real binary by absolute path (`/usr/bin/grep`) instead. Always run
  a positive control before you trust a sweep that comes back empty.
