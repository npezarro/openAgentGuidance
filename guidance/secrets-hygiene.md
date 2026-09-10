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

When reading credential files (your private context repo, `.env`, etc.), confirm you found them by name but **never include actual values in your response text**. Reference credentials by variable name only ("got the API credentials from the private context repo"); the user already knows the values, and echoing them to chat creates unnecessary exposure in conversation logs and exports.

**Why:** Credentials should stay in files and env vars. Chat output gets logged, exported, and sometimes shared. This is a habit violation, not a theoretical concern.

### The leak usually arrives sideways, not from a deliberate `echo`

Nobody sets out to print a credential. The rule above is easy to follow for *intentional* output and useless against the indirect paths. **Never run any of these against a script that sources an env file** (`. ~/.env`, `source .env`, `set -a; . <file>`):

| Never | Why it leaks | Instead |
|---|---|---|
| `bash -x script.sh` / `set -x` | xtrace prints **every expansion**, so `. ~/.env` dumps the whole file, variable by variable, with values | `bash -n` for syntax; add explicit `echo` checkpoints; trace only the section after unsetting secrets |
| `set -v` | Prints each line as read, including the sourced file | same |
| `env` / `printenv` / `declare -p` / `set` with no args | Dumps the entire environment after sourcing | `printenv VAR_NAME >/dev/null; echo "VAR_NAME set: $?"` |
| `caller \|& tee log` on a sourcing script | Trace lands in a file that later gets read back into context | Redirect trace to a file you never `cat` |
| Any command that renders config: `docker compose config`, `kubectl get -o yaml`, `systemctl show`, `terraform plan`, a process manager's `env` subcommand | Resolves and prints every variable it was given, including the ones interpolated from `.env` | Assert presence, never render: see the rule below |

A debug run of `bash -x` on a script whose second line was `set -a; . ~/.env; set +a` once printed roughly twenty credentials straight into a session transcript. The script was not even broken; the failure being debugged was elsewhere. Cost: a full rotation cycle, plus secrets sitting in a session log that any indexer would ingest on its next run.

### A secret in a command's argv is world-readable, so never put one there

A process's argument vector is not private. On Linux any user can read `/proc/<pid>/cmdline`, and `ps -ef` / `pgrep -af` / `top -c` / `htop` all render the full command line. So the moment a secret appears as a command *argument* it is exposed to every process on the box for the life of that process, and a later `ps`/`pgrep -af` **prints it straight into the transcript**, which is a second leak on top of the first. This bites through paths that look nothing like `echo`:

| Never | Why it leaks | Instead |
|---|---|---|
| `curl -H "X-Secret: $TOKEN" …` | The header value is in curl's argv | `curl -H @headerfile`, `curl --config <file>`, or `--netrc`; the credential lives in a file/fd, not argv |
| `some-cli --token=$SECRET` / `--password $PW` | Flag value is in argv | Use the tool's env var (`TOKEN=$SECRET some-cli`) or its stdin/`--password-stdin` |
| `bash -c "... SEC=$SECRET; curl -H \"X: $SEC\" ..."` | The whole expanded string is one process's argv | Have a child **read the secret itself** from env or a file (a 5-line node/python that reads `process.env`/`os.environ`), so the value never transits argv |
| `ps -f` / `pgrep -af` / `pgrep -a` while a secret-bearing process is alive | Prints that process's full argv, secret included, into your output | Match by PID or a **non-secret** substring, and use plain `pgrep` (no `-a`/`-f` that echoes the line) |

**Rule of thumb:** a secret may pass through **environment variables, stdin, or a file/fd** to the process that consumes it; never through argv, and never through a query string. The safe shape is almost always "let the program that needs the secret load it directly from `.env`/env," not "have the shell interpolate it into a command."

In a real case, a 64-character shared secret was interpolated into a `nohup bash -c '…'` string while validating an HTTP endpoint, so it sat in the process table for several minutes, and a follow-up `pgrep -af` printed a prefix of it into the session. The fix was the safe shape above: a small node script that reads the secret from the app's `.env` via `process.env` and issues the request, so the value is never an argument to anything. There is **no library that prevents a secret from reaching argv**; argv is inherently observable, so this is a convention, not a dependency. The tools that *enforce* the convention are secret **injectors** that hand credentials to a child as environment variables (1Password `op run -- <cmd>`, `chamber exec`, `direnv`, `sops exec-env`, Vault `envconsul`); for HTTP specifically, `curl --config`/`-H @file`/`--netrc` keep them out of argv. For a single-operator `.env`-based setup, a full injector is usually not warranted: it would not have prevented an ad-hoc inline anyway, and it adds migration plus a new auth dependency. (Commit-time leakage is a different vector, covered by the push gate below.)

### Never redact on the way out; assert presence instead

A redaction filter is a **guess about output you have not seen yet**, and when the guess is wrong it fails silently and open. The value prints, the pipeline exits 0, and nothing marks the failure.

A real case: verifying that a container would get its shared secret after a rebuild, the check was written as

```bash
# WRONG: the sed is a guess about the output format
docker compose config | sed -E 's/(APP_SECRET=).*/\1<redacted>/'
```

`docker compose config` emits YAML (`APP_SECRET: value`), not dotenv (`KEY=value`). The pattern matched nothing, the substitution was a no-op, and a 64-character production secret printed in full into a transcript that was itself forwarded to a notification channel.

The bug is not the specific regex. It is the shape: **the only way to know the format is to run the command, and by then it has already printed.** Any "print it but hide the value" approach has this property.

**The rule: never ask "what does this value look like". Ask "is it there".** A presence check is format-independent, so it cannot fail this way:

```bash
# GOOD: proves it is set, and cannot print it even if the format changes
docker exec <container> sh -c '[ -n "$APP_SECRET" ] && echo "set (len ${#APP_SECRET})"'

# GOOD: same idea for a compose file, checks resolution without rendering values
docker compose config --quiet && echo "compose resolves, no unset vars"

# GOOD: confirm a specific key exists in a rendered config without showing it
docker compose config | grep -c '^\s*APP_SECRET:' # expect 1

# GOOD: length and fingerprint are safe to show and are usually what you actually wanted
printenv API_KEY | wc -c
printenv API_KEY | sha256sum | cut -c1-8   # compare across hosts without revealing
```

A length, a boolean, a count, or a short hash answers essentially every real question ("is it set", "is it the same on both hosts", "did the rebuild keep it") without the value. If you genuinely need the value, you already have it in the file; you do not need it in a transcript.

**If it happens anyway:** stop the process, do NOT repeat the values in any response, tell the user immediately with the *names* of what leaked, do not rotate unilaterally (it breaks live services and is the user's call), and **hold off on any indexer/exporter that would ingest the transcript** (recall reindexers, chat-log exports, blog/wiki publishers) until they decide.

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

**Why `.claude/`?** A `.claude/settings.json` file contains agent hook configurations (curl-pipe-bash patterns, remote-exec URLs) that reveal internal architecture and represent a supply-chain risk in public repos. A portfolio-wide audit found this was systemic across 10+ repos. Any config files containing infrastructure details (repo lists, port maps, process names) should also use gitignored files with `.example` templates.

## Sensitive Identifiers (Non-Secret Leaks)

Not all leaks are credentials. Usernames, private repo names, internal hostnames, and home directory paths also reveal infrastructure layout and should not appear in public repos, including in test fixtures, JSDoc examples, and documentation.

Before making a repo public or writing example code in a public repo:
1. Check your **private identifier reference list** for identifiers that must be sanitized
2. Replace real usernames, paths, and private project names with generic alternatives
3. Verify that repo names referenced in tests/docs are actually public

That reference list maps every known private identifier to its safe replacement. If you don't have one, use generic placeholders: `/home/user/`, `myProject`, `example.com`.

### A passing scan is not a publication decision

An identifier scan matches a **fixed list of known strings**. That makes it necessary and nowhere near sufficient. It cannot see:

- **A file that is entirely about one specific system.** Nothing in a deployment runbook for one particular host need match a single pattern, and it is still unpublishable: it documents your infrastructure and is useless to anyone else.
- **A name the list does not carry.** In one review the scan passed all 48 guidance files; reading them then found hooks that hardcoded the operator's name in their matching regexes, plus a header comment describing a real leak by naming a private community and two employers. Every one of those files was "clean".
- **A private noun that is new.** The list is a lagging indicator: it contains what has leaked before, not what is about to.

So run the scan, and then **read what you are about to publish**. Budget for reading, not just scanning; a curated set of files that a human has read beats a large set that only a regex has cleared. Treat a scan result as "no known-bad strings found", which is exactly what it is, and never as "safe to publish".

Two mechanical consequences worth building in:

- **Make the operator's name a variable, never a literal**, in any tool that ships to a public repo. A gate that hardcodes who it is protecting leaks that person by existing.
- **A gate needs an exemption path.** Repos legitimately contain secret-shaped strings: placeholder credentials in docs, a vendor's published example key, a scanner's own test fixture. Without a narrow allowlist those fire every run, and a warning nobody can act on trains people to ignore the gate. Exempt the specific line, never the pattern, and make the self-test **ignore the allowlist** so that exempting a fixture cannot silently turn the gate into a no-op.

### Personal source material is its own leak class

A public tool's *input data* is published exactly as widely as its code, and the failure mode is committing that data because the repo's data directory defaults to tracked. One audit found a public eval harness carrying, as committed task definitions, the personal source material its tasks consumed: writing samples drawn from real correspondence, application material, personal profile context. None of it is a credential; no secret scan or identifier list fires on any of it, because it is content, not a key.

Rules that follow:

- **Writing samples, resume/application text, own-project fixtures, and personal profile or purchasing context live in your private context repo, full stop**, even when a public tool needs to read them. Symlink them into the public checkout; the tool cannot tell the difference.
- **When a public repo has a directory whose entries are authored data (tasks, fixtures, corpora), default-deny it in `.gitignore` and allowlist the public entries by name** (`tasks/*` then `!tasks/<public-example>`). A new entry is then invisible to git until publishing it is a deliberate act. Tracked-by-default is how the data leaked: nobody decided to publish it, it just landed where everything else landed.
- **Deleting the files does not unpublish them.** They remain in git history on the remote; removal needs a history rewrite (see "History Rewriting" below) and that is a separate, explicitly-approved decision.

## Public repo commits are anonymous; the private repo carries the attribution

**A commit message is published exactly as widely as the diff.** It is on the commits page, in the Atom feed, in the search index, and in every `git log` a cloner runs. Writing one is a publishing act, and the audit habit ("read every line of `git diff --staged`") has to cover the message too.

The split, which applies to guidance files and commit messages alike:

| Public repo | Private context repo |
|---|---|
| The rule, stated impersonally | Who asked for it, and their exact words |
| The failure mode and how it was detected | The people, employers, and rooms involved |
| The mechanism (API call, exit code, flag) | The account, sheet, channel, req id, message link |
| "A tracking sheet's source column" | Which sheet, which column |

Public text names **roles and shapes**, not **identities**: `a poster`, `one employer`, `a private community`, `<community> #<channel> (<poster>)`. That is enough for the rule to be followable by anyone; the private file supplies the lookup when *your* environment needs to act on it. Link the two so neither is orphaned: the public section ends with a pointer to the private file, and the private file names its public counterpart.

**What must never reach a public commit (message or diff):**
- A directive quoted and attributed: `<name>, <date>: "<what they said>"`. State the rule the directive produced. Attribution is what makes an ordinary preference into a published statement about a person.
- Names of individuals who are not the repo owner: posters, recruiters, hiring managers, referrers, interviewers. Third parties did not opt into the commit log.
- Private community and channel names, and message permalinks. A workspace name plus a channel identifies a membership list.
- Employers the operator has applied to or interviewed with, and ATS req ids. A job search is private; a commit log that names targets reconstructs it in date order.

### Every publish path, not just the commit

A repo publishes through more surfaces than `git push`, and each one is a separate write path that needs the same rule:

| Path | Gate |
|---|---|
| Staged file content | pre-commit hook |
| Commit message | commit-msg hook |
| Pushed diff | pre-push hook |
| PR/issue/release title and body, comments | a PreToolUse guard on Bash that inspects `gh` write commands |
| Already-published history | a retroactive exposure sweep script |

`gh pr create --body "…"` posts straight to the GitHub API. No commit happens, so no commit gate ever sees it, and any automation that opens PRs on a public repo hits this path on every run. Keep the shared checks in one library that all of these source, rather than three drifting copies.

**A gate that cannot find its own library must say so.** These gates should fail open when the shared library is missing, because breaking every commit on the machine is worse than missing one check, but they must print a warning when they do. A silent fail-open is indistinguishable from a pass, and a refactor of one hook disabled two gates for exactly that reason before the warning existed.

### Employer and person names: why there is no pattern for them

Third-party names, employers under application, and req ids are forbidden in public repos but should **not** go in the blocked-identifier list, and that is deliberate. Common company names are also product names, repo names, and ordinary English. Adding them as global patterns produces a gate that fires constantly on nothing, and a gate people learn to bypass protects nothing.

What is enumerable is blocked: private community names, message permalinks, private repo names. What is not enumerable gets three weaker defences that add up:

- **Write-time generalisation.** The rule above. This is the one that actually works.
- **A shape check with no name list.** Match the *grammar* of an attributed directive, not who is named in it, so it catches new people automatically.
- **Corporate email domains**, which have no ambiguity: `someone@<employer>.com` in a public repo is always a finding. A retroactive sweep on this check found a follow-up email containing two employees' work addresses sitting in a public portfolio repo, three months after it was committed.

**Enforcement, and its limit.** A commit-msg hook can block the enumerable half (identifier patterns plus the quoted-directive shape) on public repos only, since attribution is exactly what private repos are *for*. It cannot enumerate people and employers: those change weekly and a pattern list will always trail them. **Generalise at write time.** The gate is a backstop for the cases someone already thought of, not a substitute for deciding what the sentence is allowed to say.

This section exists because a single public commit once put a quoted directive, a private community, a named third party, and two employers on a public commits page, in the message *and* the diff. The content-only pre-commit hook had nothing to say about the message, and the identifier list had no category for people or closed rooms.

## AI Chat Export Files

AI chat exports (any assistant) are a high-risk PII vector. Export files routinely contain:
- **Sidebar chat titles** with sensitive topics (medical records, financial details, legal matters)
- **Email addresses** embedded in conversation metadata
- **Personal names and identifiers** from prior conversations

Never commit raw AI chat exports to any repository. If reference material from an AI conversation is needed:
1. Extract only the relevant content into a new file
2. Scrub any sidebar/metadata content before committing
3. Add the export directory to `.gitignore` (e.g., `Reference Files/`)
4. If the full export is needed for agent access, store it in your private context repo

This pattern caused a real incident: exports whose sidebar carried medical chat titles were committed to a public repo and had to be emergency-removed.

## Automated Security Hooks (Pre-Commit + Pre-Push)

All public repos should have both pre-commit and pre-push hooks installed. These scan for sensitive identifiers before code reaches the remote.

### Hook Files

- a pre-commit hook that scans staged diffs at commit time
- a pre-push hook that scans all commits being pushed (catches amended commits, rebases, cherry-picks that bypassed pre-commit)
- an installer that puts both hooks into one repo or all public repos

### How They Work

- **Pre-commit:** Pipes `git diff --cached` through the identifier scanner. Blocks if any sensitive identifier is found.
- **Pre-push:** Determines the commit range being pushed, checks if the repo is public (via `gh repo view`), and scans the full diff. Only enforces on public repos; private repos pass through.

### Installation

```bash
# Install to all local public repos + set up global git template
bash hooks/install-hooks.sh --all-public

# Install to a single repo
bash hooks/install-hooks.sh ~/repos/<repo>
```

The `--all-public` flag should also configure `~/.git-templates/hooks/` as the global git template directory, so any newly cloned repo automatically gets both hooks.

### For Agents

When creating a new public repo or cloning one that doesn't have hooks yet, install the hooks into it before the first commit.

**Why:** Hardcoded VM credentials once survived in a public repo for months because only pre-commit hooks existed, and only on one repo. Pre-push hooks on all public repos catch this at push time regardless of which repo it happens in.

### Legitimate `--no-verify` for Security Redactions

The hooks scan the full `git diff`, including removed lines. When you're *removing* a sensitive identifier (redacting), the removed line still contains the identifier and triggers the hook. This is a known catch-22: the hook blocks the very commit that fixes the problem.

**`--no-verify` is acceptable** when all of these are true:
1. The commit is purely a security redaction (removing or replacing sensitive identifiers)
2. The removed lines are the only hook violations (no new identifiers being added)
3. The commit message explicitly states the bypass reason ("Security remediation: --no-verify used because the pre-commit hook flags the removal lines")

This pattern was validated across 7+ repos during an infrastructure redaction sweep.

## Pre-Commit Checklist (Manual Fallback)

When the automated hook isn't installed, verify before committing to any public repo:

1. `grep -rn 'ssh.*@\|BEGIN.*KEY\|api.key\|webhook' .`: no secrets in staged files
2. No IP addresses in code (check: `grep -rn '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' .`)
3. No absolute paths to home directories
4. No private repo names or usernames in test fixtures, docs, or comments (check against your private identifier list)
5. `.gitignore` covers `.env*` files
6. Config files use environment variables, not hardcoded values
7. `git remote -v`: no credentials embedded in remote URLs (see below)

## Credentials in Git Remote URLs

Using an HTTPS remote with an embedded PAT (`https://<token>@github.com/user/repo.git`) stores the token in `.git/config` in plaintext, visible in `git remote -v`, shell history, and any process that reads the config.

**Correct approaches:**
- Use SSH remotes: `git remote set-url origin git@github.com:user/repo.git`
- Or use the git credential store / helper, with no token in the URL

**If already set:** Rotate the PAT immediately (it was already exposed), then re-set the remote: `git remote set-url origin git@github.com:user/repo.git`

**How it happens:** `git clone https://<token>@github.com/...` bakes the token into `.git/config`; CI automation that sets remotes directly does the same. In one documented case a server-side checkout carried a live PAT in its remote URL until it was rotated. Check all remotes with `git remote -v` before considering a repo "clean."

## Architecture Documentation

When documenting internal systems in a public repo:
- Describe the **pattern** ("reverse SSH tunnel to a local machine"), not the **specifics** (`ssh -p 2222 user@1.2.3.4`)
- Use generic terms: "cloud VM", "local machine", "the bot"; not hostnames or IPs
- Keep incident details focused on the **lesson**, not the infrastructure layout
- If specifics are needed, put them in a private repo or local notes

## Infrastructure Overshare in Context Files

`context.md`, `CLAUDE.md`, and deploy scripts in public repos must NOT include:
- **VM filesystem paths** (`/var/www/...`, `/opt/...`, `/home/deploy/...`)
- **Process manager process names and port assignments** (maps the full service architecture)
- **Internal API endpoint URLs** (`https://<domain>/api/internal-service/`)
- **SSH aliases or VM connection patterns** (`ssh myvm 'grep TOKEN ...'`)
- **Production health check URLs** with full domain+path
- **References to private companion repos** by name (`project-private/`)
- **Process-to-repo mappings** (reveals which GitHub repos power which services)

**Instead:** Use a pointer such as "see your private context repo's infrastructure notes". Infrastructure details belong in the private repo, which is never public. For scripts that need these values at runtime, use environment variables with `:?` guards (fail loudly if unset) or source them from private files.

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
- Process manager entry: myapp (id 4)
- Port: 8080 (production), 5000 (dev)

# GOOD:
- Deploy details: see private infrastructure notes (myapp row)
```

## History Rewriting: Techniques and Collateral Damage

### Installation: git-filter-repo Path Gotcha

`git-filter-repo` installed via pip does **not** always register as a git subcommand. Running `git filter-repo` will fail with "not a git command" unless the binary is on `$PATH`.

Check with `which git-filter-repo || ls ~/.local/bin/git-filter-repo`, and if it is only in `~/.local/bin`, invoke it directly:

```bash
~/.local/bin/git-filter-repo --invert-paths --path <file> --force
```

### Email-Only Rewrites with Mailmap

To change commit author/committer emails without touching file content (e.g., removing personal emails from public repo history), use `--mailmap`:

```bash
# 1. Unshallow first: filter-repo refuses to run on shallow clones
git fetch --unshallow 2>/dev/null || true

# 2. Create a mailmap file
echo "Name <new@email.com> <old@email.com>" > /tmp/mailmap

# 3. Rewrite history (changes metadata only, not file content)
git filter-repo --mailmap /tmp/mailmap --force
```

This is the right tool when `npm audit` or a security scan flags personal emails in commit metadata. It does not touch file content, so collateral damage risk is minimal compared to `--replace-text`.

### Collateral Damage from Content Rewrites

`git filter-repo` replaces strings across **all commits including the current working tree**. This causes collateral damage when the replacement is too broad:

- A replacement for `/var/www/html` will also hit `.env.example` defaults, inline comments, and config fallbacks, even though the path itself isn't a secret (it's a standard Apache default).
- A replacement for a username in paths (`/home/someuser/`) will break any SSH fallback or token-fetch command that references that path, even in scripts that are otherwise fine.

**After any history rewrite:**
1. Diff the working tree against what you expect. `git diff HEAD` should be empty, but check for `REDACTED_` artifacts in non-secret locations.
2. Run every script that changed. Syntax checks (`bash -n`) catch parse errors but not broken runtime behavior.
3. Check that gitignored files (`.env`, caches, state files) survived. `git reset --hard` and `git filter-repo` both wipe untracked/ignored files. Re-deploy them.
4. Verify on every machine the repo is cloned to (local and remote hosts). A hard reset on a server to match the rewritten remote will wipe gitignored `.env` files there too.

**Scope replacements narrowly.** Replace the full string (the complete webhook URL) rather than substrings that appear in innocent contexts (a username that's also part of standard paths).

## Push-Forbidden Archive Repos

Some repos on disk are deliberately local-only archives: pre-sanitization backups, forensic copies, or experimental trees whose history must never reach a remote. These repos often carry `CLAUDE.md` annotations like "NEVER PUSH" or "local-only archive". But the `origin` remote may still be configured and point at a live GitHub repo.

**The trap:** a session read a suggestion mentioning "3 copies of a file" and applied a fix to all three repos, including a local archive. The push was rejected only because another push from the real checkout had already used the same branch name seconds earlier, a coincidence that prevented the archive's pre-sanitization history (30+ commits with unsanitized secrets) from reaching a public repo. No safety mechanism stopped it.

**Required when designating a repo as push-forbidden:**
```bash
# Immediately after writing "NEVER PUSH" in CLAUDE.md:
git remote remove origin
# Verify: should produce no output:
git remote -v
```

**Before touching any unfamiliar repo:**
```bash
grep -i "never push\|push.forbidden\|archive\|local.only" CLAUDE.md
# If any match: do NOT push from this repo under any circumstances
```

Disconnecting but keeping the remote name is not sufficient: a remote still listed in `git remote -v` creates false confidence. Remove it entirely so any accidental push fails immediately with "no remote configured" rather than silently landing on a live repo.

## When a Secret is Accidentally Committed

1. **Rotate immediately.** The secret is compromised the moment it's pushed.
2. **Rewrite history.** `git filter-repo` to remove it from all commits.
3. **Force-push** to update the remote.
4. **Verify the rewrite.** `git log --all -p | grep <secret>` should return 0 matches.
5. **Check for collateral.** Grep for `REDACTED_` in the working tree; fix any unintended replacements.
6. **Restore gitignored files.** `.env` files, caches, and state files are wiped by history rewrites and hard resets; re-deploy them to all machines.
7. **Re-verify functionality.** Run every affected script on every machine; don't trust syntax checks alone.
8. **Check GitHub-side residue** (see below). PRs, issues, and cached pages may still serve the secret.

### A force-push does not purge GitHub: open or closed PRs keep the whole old history fetchable

Step 8 above understates the problem: it is not a caching artifact that clears on its own, it is server-side storage you as the repo owner cannot delete. GitHub keeps every PR's commits reachable via its own `refs/pull/<N>/head` refs regardless of what happens to the branch that fed them. A `git filter-repo` plus force-push rewrites `refs/heads/*`, but every `refs/pull/*` ref still points at the pre-rewrite commits and GitHub serves them to anyone who fetches by SHA or ref, indefinitely. Verified concretely on a repo that had already been scrubbed and force-pushed: `git fetch origin 'refs/pull/*/head'` still pulled down the pre-scrub commits containing the sensitive content, weeks after the "successful" history rewrite.

**Owners cannot delete PR refs themselves.** There is no git command or repo setting for it. The only two remedies are a GitHub Support sensitive-data-removal request, or deleting and recreating the repository (verified: this purges every `refs/pull/*`, leaving only the current branch refs). Recreating costs the PR/issue metadata and numbering (stars, forks, watchers, and webhooks are also lost if any existed); restore the description, topics, and homepage afterward, since those live in repo metadata, not git history.

**How to apply:** after any history rewrite intended to remove a secret, add a step between "verify the rewrite" (item 4) and calling it done:

```bash
git ls-remote origin 'refs/pull/*/head'
# or, to actually check content:
git fetch origin 'refs/pull/*/head' && git log --all -p | grep <secret>
```

If no PR ever carried the sensitive commit, force-push alone is sufficient. If one did, force-push is not a complete remedy by itself: decide up front whether the metadata loss from delete+recreate is acceptable, rather than discovering the residual later.

## Never interpolate a credential into a log line, even to report presence

`${VAR:+yes}${VAR:-no}` looks like a boolean and is not:

- `${VAR:+yes}` → `yes` when set
- `${VAR:-no}` → **the value of VAR** when set; `no` only when UNSET

So when the variable IS set, the pair prints `yes<THE ACTUAL VALUE>`. Written to report "is this configured?", it prints the secret.

This bit in a cron wrapper: it echoed two API keys into a transcript, and the same line would have written both into a persistent log file on any partial-config run. Both required rotation.

```bash
# WRONG -- prints the value when set
log "key: ${API_KEY:+yes}${API_KEY:-no}"

# RIGHT -- compute the boolean first
have() { [ -n "${1:-}" ] && echo yes || echo no; }
log "key: $(have "${API_KEY:-}")"
```

**Verify with a sentinel, not by eye.** The bug is invisible on a line that reads correctly:

```bash
API_KEY="SENTINEL123" ; <the log line> | grep -q SENTINEL123 && echo "LEAKS"
```

This generalises: presence is a boolean, so compute the boolean and log that. A credential variable should never appear inside a format string at all.

## A blocking gate with no write-time counterpart guarantees a backlog of unpublishable files

A secret/identifier gate that only BLOCKS, with nothing that REDACTS at write time, does not prevent leaks: it converts them into a growing pile of files that can never be committed. One content generator reached 29 stuck posts this way and kept adding more every session.

Three failure modes, all of which have to be fixed together:

1. **No redactor.** The scanner decided what was blocked but nothing decided what content should be replaced WITH. Fix: a redactor that reads the *same* identifier list as the gate, so the two cannot drift into "redacted but still blocked". Invariant worth testing: every pattern in the machine-parseable pattern list has a redaction-replacement entry.

2. **Swallowed failure.** The generator ran `git commit ... 2>/dev/null || true`. Every gate rejection was discarded, so the backlog grew invisibly for days. A gated write must log its rejection somewhere a human or agent will see it.

3. **Shared index.** The hook ran `git add` then a bare `git commit`, so one dirty file blocked every other session committing in the same checkout. Fix: `git add -- <path>` followed by `git commit -- <path>`. A path-limited commit builds a temporary index, so the pre-commit hook sees only that path and a peer's commit is neither swept in nor blocked. Verify this with a test.

Corollary for allowlists: an allowlist file is itself scanned. Explaining an exemption by naming the other blocked identifiers makes the allowlist uncommittable. Describe them ("its hostname, IP and deploy paths"); do not name them.

Corollary for redaction targets: replacement values are read by humans in published prose. Use `/var/www/app`, not a "(see private notes)" pointer lifted out of a docs table.

## A publish/mirror pipeline must gate files through an allowlist, not a denylist

Any script that mirrors a subset of a private repo's files to a public one (a public-docs sync, a sanitised export, a harness mirror) must decide inclusion by an explicit allowlist of file paths, checked before any content screening runs. A denylist ("publish everything except these") makes every new private file public by default and relies on someone remembering to add the exclusion; an allowlist makes every new file private by default until someone deliberately opts it in. The failure direction matters: a denylist's failure mode is a leak, an allowlist's is a false negative (a file that should have published didn't). The second is recoverable next run; the first is not.

The publish script should also verify its own allowlist check can't be silently bypassed by a change elsewhere: have the final pre-push screen walk every file actually on disk in the publish target rather than trusting a git-tracked-files listing, so a brand-new file the allowlist added still gets content-screened even if some earlier step forgot to stage it.

## GitHub repo description/topics/homepage never pass through git, so no commit gate can see them

A repo's GitHub description, topics and homepage are published text that never passes through git. All three commit gates are blind to them: pre-commit scans content, commit-msg scans the message, pre-push scans the diff, and none sees a field set through the API or web UI. A `gh`-write guard gates those commands for anonymity, not accuracy, and only on commands a session actually runs.

Found in practice: a public mirror repo rebuilt two days earlier still described itself as the superseded design that rebuild threw out. That string is the first line a visitor reads and the meta description search engines index.

When a repo's SHAPE changes (rebuild, scope change, rename, public/private flip), treat the description as a separate artifact to update; no gate will remind you.

```bash
gh repo view --json description,homepageUrl,repositoryTopics
```

Verify a change landed by fetching the anonymous page's meta description, not just the API.

Sibling problem: a repo going private silently breaks every public link to it. The check is a visibility sweep (`gh repo view --json isPrivate` over everything linked), not a liveness sweep, because a private repo returns a real 404 that a liveness checker correctly calls dead without telling you it used to work.
