<!-- Load when: secret rotation, history rewrite, detection patterns -->
# Secrets Hygiene

Rules for handling secrets, credentials, and infrastructure details in code, especially in public repositories.

## The Core Rule

**Never commit secrets, infrastructure specifics, or internal paths to a repository that is (or could become) public.** This includes:
- API keys, tokens, webhook URLs
- IP addresses, hostnames, SSH aliases
- Internal directory paths (home directories, deploy paths)
- SSH commands that reveal server structure
- Architecture docs with specific IPs, ports, or usernames

## Never Echo Secrets to Conversation Output

When you read credential files (your private context repo, `.env`, etc.), confirm you found them by name but **never include actual values in your response text**. Refer to credentials by variable name only (e.g., "Got the API credentials from the env file"). The user already knows the values, and echoing them to chat exposes them in conversation logs and exports for no reason.

**Why:** Credentials should stay in files and env vars. Chat output gets logged, exported, and sometimes shared. Treat this as a habit, not a theoretical concern.

### The leak usually arrives sideways, not from a deliberate `echo`

Nobody sets out to print a credential. The rule above is easy to follow for *intentional* output and useless against the indirect paths. **Never run any of these against a script that sources an env file** (`. ~/.env`, `source .env`, `set -a; . <file>`):

| Never | Why it leaks | Instead |
|---|---|---|
| `bash -x script.sh` / `set -x` | xtrace prints **every expansion**, so `. ~/.env` dumps the whole file, variable by variable, with values | `bash -n` for syntax; add explicit `echo` checkpoints; trace only the section after unsetting secrets |
| `set -v` | Prints each line as read, including the sourced file | same |
| `env` / `printenv` / `declare -p` / `set` with no args | Dumps the entire environment after sourcing | `printenv VAR_NAME >/dev/null; echo "VAR_NAME set: $?"` |
| `caller \|& tee log` on a sourcing script | Trace lands in a file that later gets read back into context | Redirect trace to a file you never `cat` |
| Any command that renders config: `docker compose config`, `kubectl get -o yaml`, `pm2 env <id>`, `systemctl show`, `terraform plan` | Resolves and prints every variable it was given, including the ones interpolated from `.env` | Assert presence, never render: see the rule below |

Lesson behind this table: a debug run of `bash -x` on a script whose second line was `set -a; . ~/.env; set +a` printed a whole env file of credentials into a session transcript. The script was not even the thing that was broken. The cost was a full rotation cycle, plus secrets sitting in a transcript that an indexer would otherwise have ingested.

### A secret in a command's argv is world-readable: never put one there

A process's argument vector is not private. On Linux any user can read `/proc/<pid>/cmdline`, and `ps -ef` / `pgrep -af` / `top -c` / `htop` all render the full command line. The moment a secret appears as a command *argument*, it is exposed to every process on the box for the life of that process, and a later `ps` or `pgrep -af` **prints it straight into the transcript**, a second leak on top of the first. This bites through paths that look nothing like `echo`:

| Never | Why it leaks | Instead |
|---|---|---|
| `curl -H "X-Secret: $TOKEN" …` | The header value is in curl's argv | `curl -H @headerfile`, `curl --config <file>`, or `--netrc`: the credential lives in a file/fd, not argv |
| `some-cli --token=$SECRET` / `--password $PW` | Flag value is in argv | Use the tool's env var (`TOKEN=$SECRET some-cli`) or its stdin/`--password-stdin` |
| `bash -c "... SEC=$SECRET; curl -H \"X: $SEC\" ..."` | The whole expanded string is one process's argv | Have a child **read the secret itself** from env or a file (a 5-line node/python script that reads `process.env`/`os.environ`), so the value never transits argv |
| `ps -f` / `pgrep -af` / `pgrep -a` while a secret-bearing process is alive | Prints that process's full argv, secret included, into your output | Match by PID or a **non-secret** substring, and use plain `pgrep` (no `-a`/`-f` that echoes the line) |

**Rule of thumb:** a secret may pass through **environment variables, stdin, or a file/fd** to the process that consumes it; never through argv, and never through a query string. The safe shape is almost always "let the program that needs the secret load it directly from `.env`/env," not "have the shell interpolate it into a command."

Lesson behind this table: while testing an authenticated internal endpoint, a shared secret was interpolated into a `nohup bash -c '…'` string, so it sat in the process table for minutes, and a follow-up `pgrep -af` printed part of it into the session. The fix was a small dependency-free script that reads the secret from the app's `.env` via `process.env`, builds the auth header in-process, and logs only the secret's length. If several of your services share the same auth pattern, give each one such a helper rather than improvising curl commands.

There is **no library that prevents a secret from reaching argv**. argv is inherently observable, so this is a convention, not a dependency. Tools that *enforce* the convention are secret **injectors** that hand credentials to a child as environment variables (1Password `op run -- <cmd>`, `chamber exec`, `direnv`, `sops exec-env`, Vault `envconsul`); for HTTP specifically, `curl --config`/`-H @file`/`--netrc` keep them out of argv. For a single-operator setup with `.env` files, an injector is usually not worth the migration and the new auth dependency: it would not stop an ad-hoc inline interpolation anyway. The convention is what matters. (Commit-time leakage is a different vector, covered by the push gate below.)

### Never redact on the way out; assert presence instead

A redaction filter is a **guess about output you have not seen yet**, and when the guess is wrong it fails silently and open. The value prints, the pipeline exits 0, and nothing marks the failure.

Example of the failure: to verify a container would get its shared secret after a rebuild, the check was written as:

```bash
# WRONG: the sed is a guess about the output format
docker compose config | sed -E 's/(API_SECRET=).*/\1<redacted>/'
```

`docker compose config` emits YAML (`API_SECRET: value`), not dotenv (`KEY=value`). The pattern matched nothing, the substitution was a no-op, and a production secret printed in full into a transcript that was forwarded to a notification channel.

The bug is not the specific regex. It is the shape: **the only way to know the format is to run the command, and by then it has already printed.** Any "print it but hide the value" approach has this property.

**The rule: never ask "what does this value look like". Ask "is it there".** A presence check is format-independent, so it cannot fail this way:

```bash
# GOOD: proves it is set, and cannot print it even if the format changes
docker exec <container> sh -c '[ -n "$API_SECRET" ] && echo "set (len ${#API_SECRET})"'

# GOOD: same idea for a compose file, checks resolution without rendering values
docker compose config --quiet && echo "compose resolves, no unset vars"

# GOOD: confirm a specific key exists in a rendered config without showing it
docker compose config | grep -c '^\s*API_SECRET:' # expect 1

# GOOD: length and fingerprint are safe to show and are usually what you actually wanted
printenv API_KEY | wc -c
printenv API_KEY | sha256sum | cut -c1-8   # compare across hosts without revealing
```

A length, a boolean, a count, or a short hash answers essentially every real question ("is it set", "is it the same on both hosts", "did the rebuild keep it") without the value. If you genuinely need the value, you already have it in the file; you do not need it in a transcript.

**If it happens anyway:** stop the process, do NOT repeat the values in any response, tell the user immediately with the *names* of what leaked, do not rotate unilaterally (it breaks live services and is the user's call), and **hold off on any indexer or exporter that would ingest the transcript** (session search indexes, chat-log exports, auto-published posts) until they decide.

## Never interpolate a credential into a log line, even to report presence

`${VAR:+yes}${VAR:-no}` looks like a boolean and is not:

- `${VAR:+yes}` → `yes` when set
- `${VAR:-no}` → **the value of VAR** when set; `no` only when UNSET

So when the variable IS set, the pair prints `yes<THE ACTUAL VALUE>`. Written to report "is this configured?", it prints the secret, into the transcript and into any persistent log file the line writes to.

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

This generalises: presence is a boolean, so compute the boolean and log that. A credential variable should never appear inside a format string at all.

## Where Secrets Go

Secrets live in **external .env files** outside the repository:

```
~/.config/<project-name>/.env    # per-project secrets
~/.cache/<tool>-token            # cached credentials
```

Never in:
- `config.yaml`, `config.json`, or any committed config file
- Shell scripts (no hardcoded `ssh user@1.2.3.4` commands)
- Documentation or READMEs
- Inline defaults in code (e.g., `HOST="${VAR:-1.2.3.4}"`)

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
HOST="203.0.113.10"

# BAD: SSH command revealing internal structure
token=$(ssh myhost 'grep TOKEN /path/to/.env')
```

## Every Repo Must Have

1. **`.gitignore`** that includes `.env`, `.env.local`, `*.pem`, `credentials.json`, `.claude/`
2. **`.env.example`** documenting required variables with placeholder values
3. **No inline defaults that leak specifics**: use `YOUR_VALUE` or `:?` to require the var

**Why `.claude/`?** `.claude/settings.json` contains agent hook configurations (curl-pipe-bash patterns, remote-exec URLs) that reveal internal architecture and represent a supply-chain risk in public repos. This tends to be systemic across a portfolio once it happens in one repo, so audit all of them. Any config file containing infrastructure details (repo lists, port maps, process names) should also be gitignored with an `.example` template committed instead.

## Sensitive Identifiers (Non-Secret Leaks)

Not all leaks are credentials. Usernames, private repo names, internal hostnames, and home directory paths also reveal infrastructure layout and should not appear in public repos, including in test fixtures, JSDoc examples, and documentation.

Before making a repo public or writing example code in a public repo:
1. Check your **private reference list** of identifiers that must be sanitized (keep one in your private context repo, with a safe replacement for each)
2. Replace real usernames, paths, and private project names with generic alternatives
3. Verify that repo names referenced in tests/docs are actually public

If you don't have a reference list, use generic placeholders: `/home/user/`, `myProject`, `example.com`. Use the same replacement terms (e.g., `deploy` for a server user) even in currently-private files: files move into public sets over time, and those literals are exactly what trips a scan later.

### A passing scan is not a publication decision

An identifier scan matches a **fixed list of known strings**. That makes it necessary and nowhere near sufficient. It cannot see:

- **A file that is entirely about one specific system.** Nothing in a deployment runbook for one particular host need match a single pattern, and it is still unpublishable: it documents your infrastructure and is useless to anyone else.
- **A name the list does not carry.** A scan can pass every file while hooks hardcode the operator's name in their matching regexes, or a header comment describes a past leak by naming a private community and employers. Every one of those files is "clean" to the scan.
- **A private noun that is new.** The list is a lagging indicator: it contains what has leaked before, not what is about to.

So run the scan, and then **read what you are about to publish**. Budget for reading, not just scanning; a curated set of files a human has read beats a large set only a regex has cleared. Treat a scan result as "no known-bad strings found", which is exactly what it is, never as "safe to publish".

Two mechanical consequences worth building in:

- **Make the operator's name a variable, never a literal**, in any tool that ships to a public repo. A gate that hardcodes who it is protecting leaks that person by existing.
- **A gate needs an exemption path.** Repos legitimately contain secret-shaped strings: placeholder credentials in docs, a vendor's published example key, a scanner's own test fixture. Without a narrow allowlist those fire every run, and a warning nobody can act on trains people to ignore the gate. Exempt the specific line, never the pattern, and make the self-test **ignore the allowlist** so exempting a fixture cannot silently turn the gate into a no-op.

An allowlist file is itself scanned. Explaining an exemption by naming the other blocked identifiers makes the allowlist uncommittable: describe them ("its hostname, IP and deploy paths"), do not name them.

### Personal source material is its own leak class

A public tool's *input data* is published exactly as widely as its code, and the failure mode is committing that data because the repo's data directory is tracked by default. A public eval harness can end up carrying, as committed task definitions, the personal material its tasks consume: voice-matching samples from real correspondence, application material, personal profile context. None of it is a credential; no secret scan or identifier list fires on any of it, because it is content, not a key.

Rules that follow:

- **Voice samples, resume/application text, own-project fixtures, and personal profile or purchasing context live in the private repo**, even when a public tool needs to read them. Symlink them into the public checkout; the tool cannot tell the difference.
- **When a public repo has a directory of authored data (tasks, fixtures, corpora), default-deny it in `.gitignore` and allowlist the public entries by name** (`tasks/*` then `!tasks/<public-example>`). A new entry is then invisible to git until publishing it is a deliberate act. Tracked-by-default is how the data leaks: nobody decides to publish it, it just lands where everything else lands.
- **Deleting the files does not unpublish them.** They remain in git history on the remote; removal needs a history rewrite (see "History Rewriting" below), and that is a separate, explicitly approved decision.

## Public repo commits are anonymous; the private repo carries the attribution

**A commit message is published exactly as widely as the diff.** It is on the commits page, in the Atom feed, in the search index, and in every `git log` a cloner runs. Writing one is a publishing act, and the audit habit ("read every line of `git diff --staged`") has to cover the message too.

The split, which applies to guidance files and commit messages alike:

| Public repo | Your private context repo |
|---|---|
| The rule, stated impersonally | Who asked for it, and their exact words |
| The failure mode and how it was detected | The people, employers, and rooms involved |
| The mechanism (API call, exit code, flag) | The account, sheet, channel, req id, message link |
| "A tracking sheet's source column" | Which sheet, which column |

Public text names **roles and shapes**, not **identities**: `a poster`, `one employer`, `a private community`, `<community> #<channel> (<poster>)`. That is enough for the rule to be followable by anyone; the private file supplies the lookup when your environment needs to act on it. Link the two so neither is orphaned.

**What must never reach a public commit (message or diff):**
- A directive quoted and attributed: `<name>, <date>: "<what they said>"`. State the rule the directive produced. Attribution is what turns an ordinary preference into a published statement about a person.
- Names of individuals who are not the repo owner: posters, recruiters, hiring managers, referrers, interviewers. Third parties did not opt into the commit log.
- Private community and channel names, and message permalinks. A workspace name plus a channel identifies a membership list.
- Employers the owner has applied to or interviewed with, and ATS req ids. A job search is private; a commit log that names targets reconstructs it in date order.

### Gate every publish path, not just the commit

A repo publishes through more surfaces than `git push`, and each one is a separate write path that needs the same rule:

| Path | Gate |
|---|---|
| Staged file content | pre-commit hook |
| Commit message | commit-msg hook |
| Pushed diff | pre-push hook |
| PR/issue/release title and body, comments | an agent PreToolUse hook on shell commands that inspects `gh` writes (public repos only) |
| Repo description, topics, homepage | nothing automatic: see below |
| Already-published history | a periodic retroactive sweep script |

`gh pr create --body "…"` posts straight to the GitHub API. No commit happens, so no commit gate ever sees it, and an automated agent that opens PRs on a public repo does so on every run. Put the shared checks in one library that all gates source, so they enforce one definition rather than several drifting copies.

**A gate that cannot find its own library must say so.** Gates should fail open when their shared library or scan script is missing, because breaking every commit on the machine is worse than missing one check, but they must print a warning. A silent fail-open is indistinguishable from a pass. A classic trigger: a hook that resolves its library by absolute path takes the fail-open branch when run from a worktree, so every gate passes everything and the test suite reports green.

**Repo metadata never passes through git.** A GitHub description, topics and homepage are published text that no commit gate can see, and a metadata hook only checks commands a session actually runs. When a repo's *shape* changes (rebuild, scope change, rename, public/private flip), treat the description as a separate artifact to update; it is the first line a visitor reads and what search engines index. Check with `gh repo view --json description,homepageUrl,repositoryTopics`, and verify a change landed by fetching the anonymous page's meta description, not just the API.

Sibling problem: a repo going private silently breaks every public link to it. The check is a visibility sweep (`gh repo view --json isPrivate` over everything linked), not a liveness sweep, because a private repo returns a real 404 that a liveness checker correctly calls dead without telling you it used to work.

### Employer and person names: why there is no pattern for them

Third-party names, employers under application, and req ids are forbidden in public repos but should **not** go in the blocked-identifier list. Many company names are also product names, common words, or names of public repos you legitimately reference. Global patterns for them produce a gate that fires constantly on nothing, and a gate people learn to bypass protects nothing.

What is enumerable gets blocked: private community names, message permalinks, private repo names. What is not enumerable gets three weaker defences that add up:

- **Write-time generalisation.** The rule above. This is the one that actually works.
- **A shape check with no name list**: match the *grammar* of an attributed directive (name, date, quoted instruction), not who is named in it, so it catches new people automatically.
- **Corporate email domains**, which have no ambiguity: `someone@<employer>.com` in a public repo is always a finding. Retroactive sweeps for these find real exposures months after commit, such as a pasted follow-up email carrying employees' work addresses in a public portfolio repo.

**Enforcement, and its limit.** The commit-msg hook blocks the enumerable half (identifier patterns plus the quoted-directive shape) on public repos only, since attribution is exactly what private repos are *for*. It cannot enumerate people and employers: those change weekly and a pattern list will always trail them. **Generalise at write time.** The gate is a backstop for the cases someone already thought of, not a substitute for deciding what the sentence is allowed to say.

### A blocking gate with no write-time counterpart guarantees a backlog of unpublishable files

A secret/identifier gate that only BLOCKS, with nothing that REDACTS at write time, does not prevent leaks: it converts them into a growing pile of files that can never be committed, and a generator keeps adding more every run. Three failure modes, all of which must be fixed together:

1. **No redactor.** The scan decides what is blocked, but nothing decides what content should replace it. Fix: a redaction script that reads the *same* identifier list as the gate, so the two cannot drift into "redacted but still blocked". Invariant worth testing: every blocked pattern has a replacement entry. Replacement values are read by humans in published prose, so use realistic generics (`/var/www/app`), not "(see private notes)".
2. **Swallowed failure.** `git commit ... 2>/dev/null || true` discards every gate rejection, so the backlog grows invisibly for days. A gated write must log its rejection somewhere a human or agent will see it.
3. **Shared index.** `git add` followed by a bare `git commit` means one dirty file blocks every other session committing in the same checkout. Fix: `git add -- <path>` then `git commit -- <path>`. A path-limited commit builds a temporary index, so the pre-commit hook sees only that path, and a peer's staged work is neither swept in nor blocking.

### A publish/mirror pipeline must gate files through an allowlist, not a denylist

Any script that mirrors a subset of a private repo's files to a public one (a public-docs sync, a sanitised export) must decide inclusion by an explicit allowlist of file paths, checked before any content screening runs. A denylist ("publish everything except these") makes every new private file public by default and relies on someone remembering to add the exclusion; an allowlist makes every new file private until someone deliberately opts it in. The failure direction matters: a denylist fails as a leak, an allowlist fails as a file that didn't publish, which is recoverable next run.

Make the final pre-push screen walk every file actually on disk in the publish target, rather than trusting a git-tracked-files listing, so a newly allowlisted file still gets content-screened even if an earlier step forgot to stage it.

## AI Chat Export Files

AI chat exports (Gemini, ChatGPT, Claude) are a high-risk PII vector. Export files routinely contain:
- **Sidebar chat titles** with sensitive topics (medical records, financial details, legal matters)
- **Email addresses** embedded in conversation metadata
- **Personal names and identifiers** from prior conversations

Never commit raw AI chat exports to any repository. If reference material from an AI conversation is needed:
1. Extract only the relevant content into a new file
2. Scrub any sidebar/metadata content before committing
3. Add the export directory to `.gitignore` (e.g., `Reference Files/`)
4. If the full export is needed for agent access, store it in your private context repo

Exports whose sidebar listed medical and psychiatric chat titles have been committed to public repos and required emergency removal; the content of the conversation was not the problem, the metadata was.

## Automated Security Hooks (Pre-Commit + Pre-Push)

All public repos MUST have both pre-commit and pre-push hooks installed. These scan for sensitive identifiers before code reaches the remote.

### How They Work

- **Pre-commit:** pipes `git diff --cached` through your identifier scan script. Blocks if any sensitive identifier is found.
- **Pre-push:** determines the commit range being pushed, checks whether the repo is public (via `gh repo view --json visibility`), and scans the full diff. Catches amended commits, rebases, and cherry-picks that bypassed pre-commit.

Hardcoded server credentials can survive in a public repo for months when only one repo has a pre-commit hook. A pre-push hook on every public repo catches that at push time regardless of which repo it happens in.

### Installation

Hooks live in each repo's `.git/hooks` as **copies**. Install them into every existing clone, and set a global template so new clones get them:

```bash
mkdir -p ~/.git-templates/hooks
cp hooks/git-pre-commit ~/.git-templates/hooks/pre-commit
cp hooks/git-pre-push   ~/.git-templates/hooks/pre-push
chmod +x ~/.git-templates/hooks/*
git config --global init.templateDir ~/.git-templates
```

When creating a new public repo, or cloning one that has no hooks yet, install them before the first commit.

### Hook maintenance lessons

- **Distribution is part of the fix.** Editing the hook source changes nothing in existing clones or the global template. After any hook edit, reinstall to all local repos (private ones too, if they can go public) and verify by grepping the INSTALLED copies for a marker from the new code, not by reading the source.
- **Read the whole message path before debugging detection.** A gate can compute visibility correctly and still print the opposite conclusion from a hardcoded message further down. The usual root cause is hooks carrying inline copies of logic a shared library already provides; delete the copies rather than fixing them in parallel.
- **Never cache the value that decides whether a gate runs without an expiry.** If visibility is cached forever, a repo flipped private to public keeps a stale PRIVATE entry and every public-only gate silently switches off. On lookup failure, fall back to the last known value rather than UNKNOWN, and do NOT refresh the cache mtime, or one transient failure marks a stale entry fresh for another full TTL.
- **Test the gate properly.** Stub external binaries like `gh` instead of trimming `PATH` (which may not actually hide them) or calling the real API (flaky on transient 5xx). Confirm every new assertion FAILS against the pre-fix code; a test that passes on both versions proves nothing.

### A private-repo local-hook exemption does not extend to CI

If local hooks are exempt on private repos but a CI identifier-scan workflow runs on every push, a direct push to `main` passes locally and then leaves the violation live on the default branch with a red check, until someone notices and fixes forward.

**How to apply:** even on a private repo where the local hook won't block you, route edits through a branch + PR rather than pushing straight to `main`, so CI fails *before* merge. Check `gh run list --branch main` after any direct push you could not avoid.

### The redaction catch-22 and `--no-verify`

The hooks scan the full `git diff`, including removed lines. When you are *removing* a sensitive identifier, the removed line still contains it and triggers the hook: the hook blocks the very commit that fixes the problem.

**`--no-verify` is acceptable** only when all of these are true:
1. The commit is purely a security redaction (removing or replacing sensitive identifiers)
2. The removed lines are the only hook violations (no new identifiers being added)
3. The commit message explicitly states the bypass reason (e.g., "Security remediation: --no-verify used because pre-commit hook flags the removal lines")

## Pre-Commit Checklist (Manual Fallback)

When the automated hook isn't installed, verify before committing to any public repo:

1. `grep -rn 'ssh.*@\|BEGIN.*KEY\|api.key\|webhook' .`: no secrets in staged files
2. No IP addresses in code (check: `grep -rn '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' .`)
3. No absolute paths to home directories
4. No private repo names or usernames in test fixtures, docs, or comments (check against your private reference list)
5. `.gitignore` covers `.env*` files
6. Config files use environment variables, not hardcoded values
7. `git remote -v`: no credentials embedded in remote URLs (see below)
8. The commit message follows the same rules as the diff

## Credentials in Git Remote URLs

An HTTPS remote with an embedded PAT (`https://<token>@github.com/user/repo.git`) stores the token in `.git/config` in plaintext, visible in `git remote -v`, shell history, and any process that reads the config.

**Correct approaches:**
- Use SSH remotes: `git remote set-url origin git@github.com:user/repo.git`
- Or use a git credential helper, with no token in the URL

**If already set:** rotate the PAT immediately (it was already exposed), then re-set the remote: `git remote set-url origin git@github.com:user/repo.git`

**How it happens:** `git clone https://<token>@github.com/...` bakes the token into `.git/config`; automation that sets remotes directly does the same, often on servers nobody inspects. Check all remotes with `git remote -v` on every machine before considering a repo "clean."

## Architecture Documentation

When documenting internal systems in a public repo:
- Describe the **pattern** (e.g., "reverse SSH tunnel to local machine"), not the **specifics** (e.g., "ssh -p 2222 user@1.2.3.4")
- Use generic terms: "cloud VM", "local machine", "the bot", not hostnames or IPs
- Keep incident details focused on the **lesson**, not the infrastructure layout
- If specifics are needed, put them in a private repo or local notes

## Infrastructure Overshare in Context Files

`context.md`, `CLAUDE.md`, and deploy scripts in public repos must NOT include:
- **Server filesystem paths** (`/var/www/...`, `/opt/...`, `/home/deploy/...`)
- **Process manager names and port assignments** (maps the full service architecture)
- **Internal API endpoint URLs** (e.g., `https://domain/api/internal-service/`)
- **SSH aliases or server connection patterns** (e.g., `ssh myvm 'grep TOKEN ...'`)
- **Production health check URLs** with full domain and path
- **References to private companion repos** by name
- **Process-to-repo mappings** (reveals which repos power which services)

**Instead:** point to an infrastructure file in your private context repo. For scripts that need these values at runtime, use environment variables with `:?` guards (fail loudly if unset) or source them from private files.

**Common violation patterns in deploy scripts:**
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

**Common violation patterns in context.md:**
```markdown
# BAD:
- Deploy: example.com/myapp via Apache ProxyPass to localhost:8080
- PM2 process: myapp (id 4)
- Port: 8080 (production), 5000 (dev)

# GOOD:
- Deploy details: see the infrastructure file in the private context repo (myapp row)
```

## History Rewriting: Techniques and Collateral Damage

### Installation: git-filter-repo path gotcha

`git-filter-repo` installed via pip may not register as a git subcommand. `git filter-repo` then fails with "not a git command" unless the binary is on `$PATH`. It commonly lands in `~/.local/bin/`; invoke it directly:

```bash
~/.local/bin/git-filter-repo --invert-paths --path <file> --force
```

To check: `which git-filter-repo || ls ~/.local/bin/git-filter-repo`

### Email-only rewrites with mailmap

To change commit author/committer emails without touching file content (e.g., removing personal emails from public repo history), use `--mailmap`:

```bash
# 1. Unshallow first: filter-repo refuses to run on shallow clones
git fetch --unshallow 2>/dev/null || true

# 2. Create a mailmap file
echo "Name <new@email.com> <old@email.com>" > /tmp/mailmap

# 3. Rewrite history (changes metadata only, not file content)
git filter-repo --mailmap /tmp/mailmap --force
```

This is the right tool when security scans flag personal emails in commit metadata. It does not touch file content, so collateral damage risk is minimal compared to `--replace-text`.

### Collateral damage from content rewrites

`git filter-repo` replaces strings across **all commits, including the current working tree**. This causes collateral damage when the replacement is too broad:

- A replacement for `/var/www/html` also hits `.env.example` defaults, inline comments, and config fallbacks, even though that path is a standard Apache default and not a secret.
- A replacement for a username inside paths (e.g., `/home/someuser/`) breaks any fallback or token-fetch command that references that path, even in scripts that are otherwise fine.

**After any history rewrite:**
1. Diff the working tree against what you expect: `git diff HEAD` should be empty, but check for `REDACTED_` artifacts in non-secret locations.
2. Run every script that changed. Syntax checks (`bash -n`) catch parse errors but not broken runtime behavior.
3. Check that gitignored files (`.env`, caches, state files) survived: `git reset --hard` and `git filter-repo` both wipe untracked/ignored files. Re-deploy them.
4. Verify on every machine the repo is cloned to (local and servers). A hard reset on a server to match the rewritten remote wipes gitignored `.env` files there too.

**Scope replacements narrowly.** Replace the full string (e.g., the complete webhook URL) rather than substrings that appear in innocent contexts (e.g., a username that is also part of standard paths).

## Push-Forbidden Archive Repos

Some repos on disk are deliberately local-only archives: pre-sanitization backups, forensic copies, or experimental trees whose history must never reach a remote. They often carry `CLAUDE.md` annotations like "NEVER PUSH" or "local-only archive", but the `origin` remote may still point at a live GitHub repo.

**The trap:** a session asked to fix "every copy of a file" applies the fix to the archive too and pushes. If the push succeeds, the archive's unsanitized history lands on the public remote. A text annotation is not a safety mechanism; only a coincidental rejection would stop it.

**Required when designating a repo as push-forbidden:**
```bash
# Immediately after writing "NEVER PUSH" in CLAUDE.md:
git remote remove origin
# Verify: should produce no output
git remote -v
```

**Before touching any unfamiliar repo:**
```bash
grep -i "never push\|push.forbidden\|archive\|local.only" CLAUDE.md
# If any match: do NOT push from this repo under any circumstances
```

Disconnecting but keeping the remote name is not sufficient: a remote still listed in `git remote -v` creates false confidence. Remove it entirely so any accidental push fails immediately with "no remote configured" rather than silently landing on a live repo.

## When a Secret is Accidentally Committed

1. **Rotate immediately**: the secret is compromised the moment it's pushed
2. **Rewrite history**: `git filter-repo` to remove it from all commits
3. **Force-push**: update the remote
4. **Verify the rewrite**: `git log --all -p | grep <secret>` should return 0 matches
5. **Check PR refs**: `git ls-remote origin 'refs/pull/*/head'` (see below)
6. **Check for collateral**: grep for `REDACTED_` in the working tree; fix any unintended replacements
7. **Restore gitignored files**: `.env` files, caches, and state files are wiped by history rewrites and hard resets; re-deploy them to all machines
8. **Re-verify functionality**: run every affected script on every machine; don't trust syntax checks alone
9. **Check GitHub cache**: PRs, issues, and cached pages may still show the secret

### A force-push does not purge GitHub: PRs keep the old history fetchable

This is not a caching artifact that clears on its own; it is server-side storage the repo owner cannot delete. GitHub keeps every PR's commits reachable via `refs/pull/<N>/head`, regardless of what happens to the branch that fed them. `git filter-repo` plus force-push rewrites `refs/heads/*`, but every `refs/pull/*` ref still points at the pre-rewrite commits, and GitHub serves them to anyone who fetches by SHA or ref, indefinitely. `git fetch origin 'refs/pull/*/head'` on a scrubbed, force-pushed repo will still pull down the pre-scrub commits.

**Owners cannot delete PR refs themselves**: there is no git command or repo setting for it. The only two remedies are a GitHub Support sensitive-data-removal request, or deleting and recreating the repository (which purges every `refs/pull/*`). Recreating loses PR/issue history and numbering, plus stars, forks, watchers, and webhooks; restore the description, topics, and homepage afterward, since those live in repo metadata, not git history.

**How to apply:** after verifying the rewrite, run `git ls-remote origin 'refs/pull/*/head'` (or `git fetch origin 'refs/pull/*/head' && git log --all -p | grep <secret>`) to check whether any PR ever carried the sensitive commit. If none did, force-push alone is sufficient. If one did, decide up front whether the loss from delete and recreate is acceptable, rather than discovering the residual exposure later.
