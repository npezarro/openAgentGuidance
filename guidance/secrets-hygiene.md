<!-- Load when: secret rotation, history rewrite, detection patterns -->
# Secrets Hygiene

Rules for handling secrets, credentials and infrastructure details in code, especially in public repositories.

## The Core Rule

**Never commit secrets, infrastructure specifics or internal paths to a repository that is public or could become public.** This includes:
- API keys, tokens, webhook URLs
- IP addresses, hostnames, SSH aliases
- Internal directory paths (home directories, deploy paths)
- SSH commands that reveal server structure
- Architecture docs with specific IPs, ports or usernames

## Never Echo Secrets to Conversation Output

When you read credential files (your private context repo, `.env` and so on), confirm that you found them by name, but **never put the actual values in your response text**. Refer to credentials by variable name only (for example, "Got the API credentials from the project `.env`"). The user already knows the values. Echoing them to chat exposes them for no reason, because chat output gets logged, exported and sometimes shared.

### The leak usually arrives sideways, not from a deliberate `echo`

Nobody sets out to print a credential. The rule above is easy to follow for *intentional* output and does nothing against the indirect paths. **Never run any of these against a script that sources an env file** (`. ~/.env`, `source .env`, `set -a; . <file>`):

| Never | Why it leaks | Instead |
|---|---|---|
| `bash -x script.sh` / `set -x` | xtrace prints **every expansion**, so `. ~/.env` dumps the whole file, variable by variable, with values | `bash -n` for syntax; add explicit `echo` checkpoints; trace only the section after unsetting secrets |
| `set -v` | Prints each line as it is read, including the sourced file | Same as above |
| `env` / `printenv` / `declare -p` / `set` with no args | Dumps the entire environment after sourcing | `printenv VAR_NAME >/dev/null; echo "VAR_NAME set: $?"` |
| `caller \|& tee log` on a sourcing script | The trace lands in a file that later gets read back into context | Redirect the trace to a file you never `cat` |
| Any command that renders config: `docker compose config`, `kubectl get -o yaml`, `pm2 env <id>`, `systemctl show`, `terraform plan` | Resolves and prints every variable it was given, including the ones interpolated from `.env` | Assert presence, never render (see below) |

Lesson: one debug run of `bash -x` on a script whose second line was `set -a; . ~/.env; set +a` can print every credential in the file into a session transcript, even when the bug being debugged is somewhere else. The cost is a full rotation cycle, plus secrets sitting in transcript files that any indexer or exporter would later ingest.

### A secret in a command's argv is world-readable, so never put one there

A process's argument vector is not private. On Linux any user can read `/proc/<pid>/cmdline`, and `ps -ef`, `pgrep -af`, `top -c` and `htop` all show the full command line. Once a secret appears as a command *argument*, every process on the machine can see it for as long as that process runs. A later `ps` or `pgrep -af` also **prints it straight into the transcript**, which is a second leak on top of the first. This happens through paths that look nothing like `echo`:

| Never | Why it leaks | Instead |
|---|---|---|
| `curl -H "X-Secret: $TOKEN" ...` | The header value is in curl's argv | `curl -H @headerfile`, `curl --config <file>` or `--netrc`, so the credential lives in a file or fd, not in argv |
| `some-cli --token=$SECRET` / `--password $PW` | The flag value is in argv | Use the tool's env var (`TOKEN=$SECRET some-cli`) or its stdin / `--password-stdin` |
| `bash -c "... SEC=$SECRET; curl -H \"X: $SEC\" ..."` | The whole expanded string is one process's argv | Have a child process **read the secret itself** from env or a file (a 5-line node or python script that reads `process.env` / `os.environ`), so the value never passes through argv |
| `ps -f` / `pgrep -af` / `pgrep -a` while a secret-bearing process is alive | Prints that process's full argv, secret included, into your output | Match by PID or by a **non-secret** substring, and use plain `pgrep` (no `-a`/`-f`, which echo the line) |

**Rule of thumb:** a secret may reach the process that uses it through **environment variables, stdin, or a file/fd**. It must never go through argv or a query string. The safe approach is almost always to let the program that needs the secret load it directly from `.env` or the environment, rather than having the shell interpolate it into a command.

Lesson: when testing an authenticated endpoint, interpolating a shared secret into a `nohup bash -c '...'` string left the secret in the process table for minutes, and a follow-up `pgrep -af` printed part of it into the session. The fix was a small dependency-free script that reads the secret from the app's `.env` through `process.env`, builds the auth header in-process, and logs only the secret's length. Keep one such helper per service that uses a shared-secret header.

No library can stop a secret from reaching argv, because argv is always observable. Keeping secrets out of it is a convention. The tools that *enforce* that convention are secret **injectors** that pass credentials to a child process as environment variables (1Password `op run -- <cmd>`, `chamber exec`, `direnv`, `sops exec-env`, Vault `envconsul`). For HTTP specifically, `curl --config`, `-H @file` and `--netrc` keep credentials out of argv. For a small single-operator setup based on `.env` files, a full injector is usually not worth it: it would not have stopped an ad-hoc inline command, and it adds a migration plus a new auth dependency. The convention plus helper scripts is enough.

### Never redact on the way out; assert presence instead

A redaction filter is a **guess about output you have not seen yet**. When the guess is wrong, it fails silently and stays open: the value prints, the pipeline exits 0, and nothing flags the failure.

```bash
# WRONG: the sed is a guess about the output format
docker compose config | sed -E 's/(SHARED_SECRET=).*/\1<redacted>/'
```

`docker compose config` emits YAML (`SHARED_SECRET: value`), not dotenv (`KEY=value`). The pattern matches nothing, the substitution does nothing, and the full secret prints into the transcript.

The problem is not this particular regex. It is the approach: **you can only learn the format by running the command, and by then it has already printed.** Any "print it but hide the value" approach has this flaw.

**The rule: never ask "what does this value look like". Ask "is it there".** A presence check does not depend on the format, so it cannot fail this way:

```bash
# GOOD: proves it is set, and cannot print it even if the format changes
docker exec <container> sh -c '[ -n "$SHARED_SECRET" ] && echo "set (len ${#SHARED_SECRET})"'

# GOOD: same idea for a compose file, checks resolution without rendering values
docker compose config --quiet && echo "compose resolves, no unset vars"

# GOOD: confirm a specific key exists in a rendered config without showing it
docker compose config | grep -c '^\s*SHARED_SECRET:' # expect 1

# GOOD: length and fingerprint are safe to show and are usually what you actually wanted
printenv API_KEY | wc -c
printenv API_KEY | sha256sum | cut -c1-8   # compare across hosts without revealing
```

A length, a boolean, a count or a short hash answers nearly every real question ("is it set", "is it the same on both hosts", "did the rebuild keep it") without showing the value. If you really need the value, it is already in the file. It does not need to be in a transcript.

### Never interpolate a credential into a log line, even to report presence

`${VAR:+yes}${VAR:-no}` looks like a boolean, but it is not:

- `${VAR:+yes}` gives `yes` when the variable is set
- `${VAR:-no}` gives **the value of VAR** when it is set, and `no` only when it is UNSET

So when the variable IS set, the pair prints `yes<THE ACTUAL VALUE>`. A line written to report "is this configured?" prints the secret instead. In a cron wrapper, the same line also writes the secret into a persistent log file.

```bash
# WRONG: prints the value when set
log "key: ${API_KEY:+yes}${API_KEY:-no}"

# RIGHT: compute the boolean first
have() { [ -n "${1:-}" ] && echo yes || echo no; }
log "key: $(have "${API_KEY:-}")"
```

**Verify with a sentinel, not by eye.** The bug is invisible on a line that reads correctly:

```bash
API_KEY="SENTINEL123" ; <the log line> | grep -q SENTINEL123 && echo "LEAKS"
```

The general rule: presence is a boolean, so compute the boolean and log that. A credential variable should never appear inside a format string.

### If it happens anyway

1. Stop the process.
2. Do NOT repeat the values in any response.
3. Tell the user immediately, giving the *names* of what leaked.
4. Do not rotate on your own. Rotation breaks live services and is the user's decision.
5. **Pause any indexer or exporter that would ingest the transcript** (session recall indexers, chat-log exports, auto-published posts) until the user decides what to do.

## Where Secrets Go

Secrets live in **external .env files** outside the repository:

```
~/.config/<project-name>/.env    # per-project secrets
~/.cache/<tool>-token            # cached credentials
```

Never in:
- `config.yaml`, `config.json` or any committed config file
- Shell scripts (no hardcoded `ssh user@1.2.3.4` commands)
- Documentation or READMEs
- Inline defaults in code (for example `HOST="${VAR:-1.2.3.4}"`)

## How to Reference Secrets in Code

```bash
# GOOD: Source from external file, fail loudly if missing
ENV_FILE="${MY_ENV_FILE:-$HOME/.config/myproject/.env}"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
HOST="${MY_HOST:?MY_HOST not set, see .env.example}"

# GOOD: Read from cache, no SSH fallback that reveals paths
get_token() {
  [ -n "${MY_TOKEN:-}" ] && echo "$MY_TOKEN" && return
  [ -f "$HOME/.cache/my-token" ] && cat "$HOME/.cache/my-token" && return
  return 1
}

# BAD: Hardcoded IP
HOST="35.x.x.x"

# BAD: SSH command revealing internal structure
token=$(ssh myhost 'grep TOKEN /path/to/.env')
```

## Every Repo Must Have

1. **`.gitignore`** that includes `.env`, `.env.local`, `*.pem`, `credentials.json` and `.claude/`
2. **`.env.example`** that documents the required variables with placeholder values
3. **No inline defaults that leak specifics.** Use `YOUR_VALUE` or `:?` to require the variable.

**Why `.claude/`?** `.claude/settings.json` holds agent hook configuration (curl-pipe-bash patterns, remote-exec URLs). In a public repo it reveals internal architecture and is a supply-chain risk. This tends to be systemic: once one repo commits it, many repos usually do, so audit the whole portfolio. Any config file with infrastructure details (repo lists, port maps, process names) should likewise be a gitignored file with a committed `.example` template.

## Sensitive Identifiers (Non-Secret Leaks)

Not every leak is a credential. Usernames, private repo names, internal hostnames and home directory paths also reveal your infrastructure. Keep them out of public repos, including test fixtures, JSDoc examples and documentation.

Before you make a repo public or write example code in a public repo:
1. Check your **private reference list** of identifiers that must be sanitized.
2. Replace real usernames, paths and private project names with generic alternatives.
3. Verify that any repo named in tests or docs is actually public.

Keep that reference list in your private context repo, with each known private identifier and its safe replacement. If you don't have one, use generic placeholders: `/home/user/`, `myProject`, `example.com`.

### A passing scan is not a publication decision

An identifier scan matches a **fixed list of known strings**. It is necessary but far from sufficient. It cannot see:

- **A file that is entirely about one specific system.** A deployment runbook for one particular host may not match a single pattern and still be unpublishable: it documents your infrastructure and is useless to anyone else.
- **A name the list does not have.** Hooks can hardcode the operator's name in their matching regexes, and header comments can describe a past leak by naming the community and employers involved. Each such file passes the scan as "clean".
- **A new private noun.** The list lags behind: it contains what has leaked before, not what is about to leak.

So run the scan, and then **read what you are about to publish**. Plan time for reading, not just scanning. A curated set of files that a person has read is better than a large set that only a regex has cleared. Treat a scan result as exactly what it is, "no known-bad strings found", and never as "safe to publish".

Two practices to build in:

- **Make the operator's name a variable, never a literal**, in any tool that ships to a public repo. A gate that hardcodes who it protects leaks that person just by existing.
- **Give every gate an exemption path.** Repos legitimately contain strings that look like secrets: placeholder credentials in docs, a vendor's published example key, a scanner's own test fixtures. Without a narrow allowlist, the gate fires on every run, and a warning nobody can act on trains people to ignore the gate. Exempt the specific line, never the pattern. Make the gate's self-test **ignore the allowlist**, so that exempting a fixture cannot quietly turn the gate into a no-op.

### Personal source material is its own leak class

A public tool's *input data* is published as widely as its code. The usual failure is that the data gets committed because the repo's data directory is tracked by default. A typical example is a public eval harness that ships, as committed task definitions, the personal material its tasks consume: voice-matching samples taken from real correspondence, job application material, personal profile context. None of it is a credential, so no secret scan or identifier list catches it. It is content, not a key.

Rules that follow:

- **Voice samples, resume and application text, fixtures from your own projects, and personal profile or purchasing context belong in the private repo**, even when a public tool needs to read them. Symlink them into the public checkout; the tool cannot tell the difference.
- **When a public repo has a directory of authored data (tasks, fixtures, corpora), deny it by default in `.gitignore` and allowlist the public entries by name** (`tasks/*` then `!tasks/<public-example>`). A new entry then stays invisible to git until someone deliberately publishes it. Data leaks under tracked-by-default because nobody decides to publish it; it just lands where everything else lands.
- **Deleting the files does not unpublish them.** They stay in git history on the remote. Removing them needs a history rewrite (see "History Rewriting" below), which is a separate decision that needs explicit approval.

## Public repo commits are anonymous; the private repo carries the attribution

**A commit message is published as widely as the diff.** It appears on the commits page, in the Atom feed, in the search index and in every `git log` a cloner runs. Writing one is an act of publishing. The habit of reading every line of `git diff --staged` has to cover the message too.

The split, which applies to guidance files and commit messages alike:

| Public repo | Private repo |
|---|---|
| The rule, stated impersonally | Who asked for it, and their exact words |
| The failure mode and how it was detected | The people, employers and rooms involved |
| The mechanism (API call, exit code, flag) | The account, sheet, channel, req id, message link |
| "A tracking sheet's source column" | Which sheet, which column |

Public text names **roles and shapes**, not **identities**: `a poster`, `one employer`, `a private community`, `<community> #<channel> (<poster>)`. That is enough for anyone to follow the rule. The private file provides the lookup when *your* environment needs to act on it. Link the two so neither is orphaned: the public section points to the private file, and the private file names its public counterpart.

**What must never reach a public commit (message or diff):**
- A quoted, attributed directive: `<name>, <date>: "<what they said>"`. State the rule the directive produced instead. Attribution is what turns an ordinary preference into a published statement about a person.
- Names of individuals other than the repo owner: posters, recruiters, hiring managers, referrers, interviewers. Third parties did not agree to appear in the commit log.
- Private community and channel names, and message permalinks. A workspace name plus a channel name identifies a membership list.
- Employers the owner has applied to or interviewed with, and ATS req ids. A job search is private, and a commit log that names targets reconstructs it in date order.

### Every publish path, not just the commit

A repo publishes through more surfaces than `git push`. Each one is a separate write path and needs the same rule:

| Path | Gate |
|---|---|
| Staged file content | pre-commit hook |
| Commit message | commit-msg hook |
| Pushed diff | pre-push hook |
| PR/issue/release title and body, comments | a PreToolUse guard on `gh` commands |
| Already-published history | a retroactive exposure sweep script |

`gh pr create --body "..."` posts straight to the GitHub API. No commit happens, so no commit gate ever sees it. Any agent that opens PRs on a public repo needs the PreToolUse guard. Put the shared checks in one library that every gate sources, so they all enforce one definition instead of several drifting copies. Copies drift: two hooks that each carried an inline copy of the shared lookup and wording ended up detecting a repo's visibility correctly and then printing the opposite conclusion. When a gate reports the wrong category, read the whole path that emits the message before you debug the detection. The fix is to delete the copies, not to correct each one.

**A gate that cannot find its own library must say so.** Gates should fail open when their shared library or scanner is missing, because breaking every commit on the machine is worse than missing one check. But they must print a warning when they do. A silent fail-open looks exactly like a pass. A hook that resolves its library by absolute path will fail open silently when run from a git worktree, and the test suite will report green.

### Employer and person names: why there is no pattern for them

Third-party names, employers under application and req ids are forbidden in public repos, but they are deliberately **not** in the blocked-identifier list. Many company names are also product names, engine names or public repo names that appear legitimately in ordinary content. Global patterns for them give you a gate that constantly fires on nothing, and people learn to bypass a gate like that, so it protects nothing.

What can be enumerated gets blocked: private community names, message permalinks, private repo names. What cannot be enumerated gets three weaker defences that add up:

- **Generalise at write time.** This is the rule above, and it is the one that actually works.
- **A shape check with no name list.** Match the *grammar* of an attributed directive, not who is named in it, so new people are caught automatically.
- **Corporate email domains.** These are unambiguous: `someone@<employer>.com` in a public repo is always a finding. A retroactive sweep for them can find things like a follow-up email with employees' work addresses that has sat in a public portfolio repo for months.

**Enforcement and its limits.** Scope the commit-msg checks differently. Run the identifier-pattern check on every repo regardless of visibility, since a message is a write path where enumerable identifiers should always be caught. Run the quoted-directive attribution check on public repos only, because attribution is exactly what private repos are *for*. Neither check can enumerate people and employers: those change weekly, and a pattern list will always lag behind. The gate is a backstop for cases someone already thought of. It does not replace deciding what a sentence is allowed to say.

## AI Chat Export Files

AI chat exports (from any assistant) are a high-risk source of PII. Export files routinely contain:
- **Sidebar chat titles** on sensitive topics (medical records, financial details, legal matters)
- **Email addresses** embedded in conversation metadata
- **Personal names and identifiers** from earlier conversations

Never commit raw AI chat exports to any repository. If you need reference material from an AI conversation:
1. Extract only the relevant content into a new file.
2. Scrub any sidebar or metadata content before committing.
3. Add the export directory to `.gitignore` (for example `Reference Files/`).
4. If an agent needs the full export, store it in your private context repo.

Lesson: exports whose sidebar titles reveal medical history can easily be committed to a public repo as "reference files", and then need emergency removal plus a history rewrite.

## Automated Security Hooks (Pre-Commit + Pre-Push)

Every public repo MUST have both pre-commit and pre-push hooks installed. They scan for sensitive identifiers before code reaches the remote.

### How they work

- **Pre-commit:** pipes `git diff --cached` through your identifier scanner and blocks the commit if anything matches.
- **Pre-push:** works out the commit range being pushed, checks whether the repo is public (`gh repo view --json isPrivate`), and scans the full diff. This catches amended commits, rebases and cherry-picks that bypassed pre-commit.
- **Commit-msg:** scans the message itself (see above).

Without a pre-push hook on every public repo, hardcoded credentials can survive in a public repo for months, because a pre-commit hook on one repo protects only that repo.

### Installation and distribution

Hooks are **copies** in each repo's `.git/hooks`. Use a global template so new clones get them automatically:

```bash
mkdir -p ~/.git-templates/hooks
cp hooks/git-pre-commit ~/.git-templates/hooks/pre-commit
cp hooks/git-pre-push ~/.git-templates/hooks/pre-push
cp hooks/git-commit-msg ~/.git-templates/hooks/commit-msg
chmod +x ~/.git-templates/hooks/*
git config --global init.templateDir ~/.git-templates
```

When you create a new public repo, or clone one that has no hooks yet, install them into that repo explicitly.

**Editing the hook source changes nothing on its own.** Every existing clone, and the global template, keeps running the old copy. An installer that only targets public repos also skips the private repos that may show the bug. After any hook edit, reinstall to every local clone and to the template, then verify by grepping the **installed** copies for a marker from the new code. Do not verify by reading the source.

**Test hooks properly.** Stub external binaries such as `gh`. Restricting `PATH` to simulate a missing tool often fails because the tool lives in `/usr/bin`, and calling the real API makes the suite flaky. Confirm that every new assertion FAILS against the pre-fix code; a test that passes on both versions proves nothing.

### Never cache the value that decides whether a gate runs

If a gate blocks only when a repo is PUBLIC, caching the visibility forever is dangerous: a repo that flips from private to public keeps a stale PRIVATE entry, and the gate silently switches off. Give the cache an expiry. If a lookup fails, fall back to the last known value rather than UNKNOWN, and do NOT refresh the cache timestamp. Otherwise one transient failure marks a stale entry as fresh for another full TTL.

### A private-repo local-hook exemption does not extend to CI

Local hooks may exempt private repos, but a CI identifier-scan workflow often runs on every push regardless of visibility. If you push straight to `main` on a private repo, the local hook passes silently and CI fails seconds later, leaving the violating content live on the default branch until someone notices.

**How to apply:** even on a private repo where the local hook won't block you, send edits through a branch and PR rather than pushing straight to `main`. That way CI fails *before* merge. When you write any recipe that touches infrastructure identifiers (SSH users, VM hostnames, `chown` targets), use the generic replacement terms from your reference list (for example `deploy` for a server user) even in a file that is currently private. Those identifiers are exactly what trips the scan, and files tend to get published over time.

### The redaction catch-22

The hooks scan the full `git diff`, including removed lines. When you *remove* a sensitive identifier, the removed line still contains it and triggers the hook, so the hook blocks the very commit that fixes the problem.

**`--no-verify` is acceptable** only when all of these are true:
1. The commit is purely a security redaction (removing or replacing sensitive identifiers).
2. The removed lines are the only hook violations (no new identifiers are being added).
3. The commit message states the reason for the bypass (for example "Security remediation: --no-verify used because pre-commit hook flags the removal lines").

### A blocking gate needs a write-time counterpart

A secret or identifier gate that only BLOCKS, with nothing that REDACTS at write time, does not prevent leaks. It turns them into a growing pile of files that can never be committed, while the generator keeps producing more. Three failure modes have to be fixed together:

1. **No redactor.** The scanner decides what is blocked, but nothing decides what to replace it WITH. Fix: build a redactor that reads the same identifier list as the scanner, so the two cannot drift apart into "redacted but still blocked". Test this invariant: every blocked pattern has a replacement entry.
2. **Swallowed failure.** `git commit ... 2>/dev/null || true` throws away every gate rejection, so the backlog grows without anyone seeing it. A gated write must log its rejection somewhere a person or agent will see it.
3. **Shared index.** `git add` followed by a bare `git commit` lets one dirty file block every other session committing in the same checkout. Fix: `git add -- <path>` then `git commit -- <path>`. A path-limited commit builds a temporary index, so the pre-commit hook sees only that path, and another session's work is neither swept in nor blocking.

Two related points:
- An allowlist file (such as `.security-scan-allow`) is itself scanned. If you explain an exemption by naming the other blocked identifiers, the allowlist becomes impossible to commit. Describe them ("its hostname, IP and deploy paths"); do not name them.
- People read redaction replacement values in published prose. Use realistic generic values such as `/var/www/app`, not an internal note like "(see private repo)".

## Pre-Commit Checklist (Manual Fallback)

When the automated hook isn't installed, check these before committing to any public repo:

1. `grep -rn 'ssh.*@\|BEGIN.*KEY\|api.key\|webhook' .`: no secrets in staged files
2. No IP addresses in code: `grep -rn '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' .`
3. No absolute paths to home directories
4. No private repo names or usernames in test fixtures, docs or comments (check against your private reference list)
5. `.gitignore` covers `.env*` files
6. Config files use environment variables, not hardcoded values
7. `git remote -v` shows no credentials embedded in remote URLs (see below)
8. `git diff --staged` and the commit message have been read line by line

## Credentials in Git Remote URLs

An HTTPS remote with an embedded PAT (`https://<token>@github.com/user/repo.git`) stores the token in plaintext in `.git/config`. It is visible in `git remote -v`, in shell history and to any process that reads the config.

**Correct approaches:**
- Use SSH remotes: `git remote set-url origin git@github.com:user/repo.git`
- Or use a git credential helper, with no token in the URL

**If one is already set:** rotate the PAT immediately, because it has already been exposed. Then reset the remote: `git remote set-url origin git@github.com:user/repo.git`

**How it happens:** `git clone https://<token>@github.com/...` writes the token into `.git/config`, and automation that sets remotes directly does the same, often on servers where nobody looks. Check every remote with `git remote -v` on every machine before you consider a repo clean.

## Architecture Documentation

When documenting internal systems in a public repo:
- Describe the **pattern** (for example "reverse SSH tunnel to local machine"), not the **specifics** (for example "ssh -p 2222 user@1.2.3.4").
- Use generic terms such as "cloud VM", "local machine" and "the bot", not hostnames or IPs.
- Keep incident write-ups focused on the **lesson**, not the infrastructure layout.
- If you need specifics, put them in a private repo or local notes.

## Infrastructure Overshare in Context Files

`context.md`, `CLAUDE.md` and deploy scripts in public repos must NOT include:
- **Server filesystem paths** (`/var/www/...`, `/opt/...`, `/home/deploy/...`)
- **Process manager names and port assignments** (these map your whole service architecture)
- **Internal API endpoint URLs** (for example `https://domain/api/internal-service/`)
- **SSH aliases or connection patterns** (for example `ssh myvm 'grep TOKEN ...'`)
- **Production health check URLs** with the full domain and path
- **References to private companion repos** by name
- **Process-to-repo mappings** (these reveal which repos power which services)

**Instead:** use a pointer such as "deploy details: see your private context repo". For scripts that need these values at runtime, use environment variables with `:?` guards (fail loudly if unset), or source them from files in your private context repo.

**Common violations in deploy scripts:**
```bash
# BAD: Hardcoded paths and health check URLs
cd /opt/myservice
curl -sf https://mydomain.com/myservice/ > /dev/null

# GOOD: Externalized via env vars
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$DEPLOY_DIR"
HEALTH_URL="${HEALTH_URL:-${APP_URL:-http://localhost:8080}/}"
curl -sf "$HEALTH_URL" > /dev/null
```

**Common violations in context.md:**
```markdown
# BAD:
- Deploy: example.com/myapp via Apache ProxyPass to localhost:8080
- Process: myapp (id 4)
- Port: 8080 (production), 5000 (dev)

# GOOD:
- Deploy details: see private context repo (myapp row)
```

## History Rewriting: Techniques and Collateral Damage

### Installation: git-filter-repo path gotcha

`git-filter-repo` installed with `pip install --user` does **not** register as a git subcommand unless its binary is on `$PATH`. In that case `git filter-repo` fails with "not a git command". It usually lands in `~/.local/bin/`. Either add that directory to `PATH` or call the binary directly:

```bash
which git-filter-repo || ls ~/.local/bin/git-filter-repo
~/.local/bin/git-filter-repo --invert-paths --path <file> --force
```

### Email-only rewrites with mailmap

To change commit author and committer emails without touching file content (for example, removing personal emails from a public repo's history), use `--mailmap`:

```bash
# 1. Unshallow first: filter-repo refuses to run on shallow clones
git fetch --unshallow 2>/dev/null || true

# 2. Create a mailmap file
echo "Name <new@email.com> <old@email.com>" > /tmp/mailmap

# 3. Rewrite history (changes metadata only, not file content)
git filter-repo --mailmap /tmp/mailmap --force
```

This changes metadata only, so the risk of collateral damage is minimal compared with `--replace-text`.

### Collateral damage from content rewrites

`git filter-repo` replaces strings across **all commits, including the current working tree**. A replacement that is too broad causes collateral damage:

- A replacement for `/var/www/html` also hits `.env.example` defaults, inline comments and config fallbacks, even though that path is a standard Apache default and not a secret.
- A replacement for a username inside paths (for example `/home/someuser/`) breaks any script that references that path, even scripts that were otherwise fine.

**After any history rewrite:**
1. Diff the working tree against what you expect. `git diff HEAD` should be empty, but also look for `REDACTED_` artifacts in places that held no secret.
2. Run every script that changed. Syntax checks (`bash -n`) catch parse errors, not broken runtime behavior.
3. Check that gitignored files (`.env`, caches, state files) survived. `git reset --hard` and `git filter-repo` can both wipe untracked or ignored files; restore them.
4. Verify on every machine the repo is cloned to (local and server). A hard reset on a server to match the rewritten remote also wipes the gitignored `.env` files there.

**Scope replacements narrowly.** Replace the full string (for example the complete webhook URL), not substrings that also appear in innocent places (for example a username that is part of standard paths).

## Push-Forbidden Archive Repos

Some repos on disk are deliberately local-only archives: backups taken before sanitization, forensic copies, or experimental trees whose history must never reach a remote. They often have a `CLAUDE.md` note such as "NEVER PUSH" or "local-only archive", yet the `origin` remote may still point at a live GitHub repo.

**The trap:** a task that says "fix all copies of this file" gets applied to every checkout, including the archive, and a push from the archive would send unsanitized history to the public repo. Only luck (such as a branch-name collision) stands in the way; no safety mechanism does.

**Required when you designate a repo as push-forbidden:**
```bash
# Immediately after writing "NEVER PUSH" in CLAUDE.md:
git remote remove origin
# Verify; this should produce no output:
git remote -v
```

**Before touching any unfamiliar repo:**
```bash
grep -i "never push\|push.forbidden\|archive\|local.only" CLAUDE.md
# If anything matches: do NOT push from this repo under any circumstances
```

Disabling the remote but keeping its name is not enough, because a remote still listed in `git remote -v` gives false confidence. Remove it entirely, so an accidental push fails immediately with "no remote configured" instead of landing on a live repo.

## When a Secret Is Accidentally Committed

1. **Rotate immediately.** The secret is compromised the moment it is pushed.
2. **Rewrite history** with `git filter-repo` to remove it from all commits.
3. **Force-push** to update the remote.
4. **Verify the rewrite:** `git log --all -p | grep <secret>` should return 0 matches.
5. **Check PR refs** (see below).
6. **Check for collateral damage:** grep for `REDACTED_` in the working tree and fix any unintended replacements.
7. **Restore gitignored files.** History rewrites and hard resets wipe `.env` files, caches and state files; put them back on every machine.
8. **Re-verify functionality.** Run every affected script on every machine. Don't trust syntax checks alone.
9. **Check other GitHub surfaces:** issues, PR descriptions and comments, and cached pages may still show the secret.

### A force-push does not purge GitHub: PRs keep the old history fetchable

This is not a cache that clears on its own. It is server-side storage that you, the repo owner, cannot delete. GitHub keeps every PR's commits reachable through its own `refs/pull/<N>/head` refs, no matter what happens to the branch they came from. `git filter-repo` plus a force-push rewrites `refs/heads/*`, but every `refs/pull/*` ref still points at the pre-rewrite commits, and GitHub serves them to anyone who fetches by SHA or ref, indefinitely. On a repo that was scrubbed and force-pushed, `git fetch origin 'refs/pull/*/head'` still retrieves the pre-scrub commits weeks later.

**Owners cannot delete PR refs themselves.** There is no git command or repo setting for it. The only two remedies are a GitHub Support sensitive-data removal request, or deleting and recreating the repository (which purges every `refs/pull/*` and leaves only the current branch refs). Recreating loses PR and issue metadata and numbering, plus any stars, forks, watchers and webhooks. Restore the description, topics and homepage afterwards, since those are repo metadata, not git history.

**How to apply:** after any history rewrite meant to remove a secret, run `git ls-remote origin 'refs/pull/*/head'` (or `git fetch origin 'refs/pull/*/head' && git log --all -p | grep <secret>`) to check whether any PR ever carried the sensitive commit. If none did, the force-push is enough. If one did, the force-push alone does not fix it. Decide up front whether the metadata loss from delete-and-recreate is acceptable, rather than discovering the leftover exposure later.

## A Publish/Mirror Pipeline Must Use an Allowlist, Not a Denylist

Any script that mirrors a subset of a private repo's files to a public one (a public docs sync, a sanitised export, a public mirror of guidance files) must decide what to include using an explicit allowlist of file paths, checked before any content screening runs. A denylist ("publish everything except these") makes every new private file public by default and depends on someone remembering to add the exclusion. An allowlist keeps every new file private until someone deliberately opts it in. The direction of failure matters: a denylist fails by leaking, while an allowlist fails by leaving out a file that should have been published. The second is fixed on the next run; the first cannot be undone.

The final pre-push screen should walk every file actually on disk in the publish target, rather than trusting a list of git-tracked files. That way a file added through the allowlist still gets screened even if an earlier step forgot to stage it.

A public mirror is also not a substitute for the private source. If a fetch of the private repo starts failing (for example after a visibility flip) and you repoint it at the public mirror, it returns HTTP 200 and passes a smoke test, but it serves the sanitized subset, not the full content. Check *what* you fetched, not just the status code. Never let a "continue silently if the fetch fails" clause hide the total loss of a ruleset.

## Repo Description, Topics and Homepage Bypass Every Commit Gate

A repo's GitHub description, topics and homepage are published text that never passes through git. All three commit gates miss them: pre-commit scans content, commit-msg scans the message, pre-push scans the diff, and none of them sees a field set through the API or the web UI. A metadata guard on `gh` commands checks anonymity, not accuracy, and only for commands a session actually runs.

When a repo's **shape** changes (rebuild, scope change, rename, public/private flip), treat the description as a separate artifact to update, because no gate will remind you. Otherwise a rebuilt repo keeps describing the design it replaced, in the first line visitors read and in the meta description that search engines index. Check with:

```bash
gh repo view --json description,homepageUrl,repositoryTopics
```

To confirm a change landed, fetch the anonymous page's meta description, not just the API.

Related: making a repo private silently breaks every public link to it. To catch this, run a visibility sweep (`gh repo view --json isPrivate` over everything you link to), not a liveness sweep. A private repo returns a real 404, which a liveness checker correctly reports as dead without telling you that it used to work.
