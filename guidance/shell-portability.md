<!-- Load when: writing or debugging a shell script that has to run on BOTH Linux/WSL hosts and a Mac -->
# Shell Portability Across Linux Hosts and macOS

Shared scripts often run on Linux or WSL (bash 5) *and* on a Mac, where
`/bin/bash` is still **bash 3.2.57**. Apple froze it at the last GPLv2 release.
A `#!/usr/bin/env bash` script started from a LaunchAgent, a cron job or a plain
`bash script.sh` call usually gets that system bash, not the newer Homebrew one.

A bash-5-only construct does not degrade gracefully on the Mac. The script fails to **parse**,
so none of it runs, including any code that would have reported the failure.

## Check it, do not assume it

The whole test is `bash -n script.sh` run under `/bin/bash`, and it costs nothing. Sweep the
directory before shipping:

```sh
for f in scripts/*.sh; do out=$(/bin/bash -n "$f" 2>&1); [ -n "$out" ] && echo "FAIL $f: $out"; done
```

Don't trust a clean sweep until you have seen it fail once. Write the broken
construct into a scratch file and confirm the sweep catches it.

## Known traps

- **A bare `case` pattern inside `$( )` breaks bash 3.2.** Its command-substitution
  parser counts parentheses, so it reads the `)` that closes a case pattern as the one
  that closes the `$(`. The error is `syntax error near unexpected token ;;`.
  Balance it with the POSIX-legal leading `(`:
  `case "$x" in (*foo*) ...;; esac`. This is valid everywhere and required on the Mac.
- **`readlink -f`, `sed -i`, `date -d` and `stat -c`** are GNU spellings, and the BSD
  userland on macOS differs. Use `sed -i.bak` or `python3`, or test for `gsed`/`gdate`.
- **`${var,,}` / `${var^^}`** (case conversion) need bash 4+. Use `tr` instead.
- **Associative arrays (`declare -A`)** need bash 4+. No bash 3.2 fallback is worth
  writing, so restructure the script or use python3.
- **`/proc`** does not exist on darwin. Use `ps` instead.

## Why this matters

These failures ship unnoticed because bash 5 on the Linux hosts parses the script
either way. The first sign is often that a required workflow script has silently
stopped working on the Mac. Any script meant to run on both platforms needs the
`/bin/bash -n` sweep in its pre-ship checklist.
