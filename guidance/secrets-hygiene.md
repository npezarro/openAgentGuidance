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

When reading credential files (your private context repo, `.env`, etc.), confirm you found them by name but **never include actual values in your response text**. Reference credentials by variable name only ("got the API credentials from the private context repo"); the person you are working with already knows the values, and echoing them to chat creates unnecessary exposure in conversation logs and exports.

**Why:** Credentials should stay in files and env vars. Chat output gets logged, exported, and sometimes shared. This is a habit violation, not a theoretical concern.

### The leak usually arrives sideways, not from a deliberate `echo`

Nobody sets out to print a credential. The rule above is easy to follow for *intentional* output and useless against the indirect paths. **Never run any of these against a script that sources an env file** (`. ~/.env`, `source .env`, `set -a; . <file>`):

| Never | Why it leaks | Instead |
|---|---|---|
| `bash -x script.sh` / `set -x` | xtrace prints **every expansion**, so `. ~/.env` dumps the whole file, variable by variable, with values | `bash -n` for syntax; add explicit `echo` checkpoints; trace only the section after unsetting secrets |
| `set -v` | Prints each line as read, including the sourced file | same |
| `env` / `printenv` / `declare -p` / `set` with no args | Dumps the entire environment after sourcing | `printenv VAR_NAME >/dev/null; echo "VAR_NAME set: $?"` |
| `caller \|& tee log` on a sourcing script | Trace lands in a file that later gets read back into context | Redirect trace to a file you never `cat` |

**This section exists because of a real incident.** A debug run of `bash -x` on a script whose second line was `set -a; . ~/.env; set +a` printed roughly 20 credentials (webhook URLs, an application password) straight into a session transcript. The script was not even broken; the failure being debugged was elsewhere. Cost: a rotation cycle, plus secrets sitting in a session transcript that any recall indexer would ingest on its next run.

**If it happens anyway:** stop the process, do NOT repeat the values in any response, tell the user immediately with the *names* of what leaked, do not rotate unilaterally (it breaks live services and is the user's call), and **hold off on any indexer, exporter, or publishing job that would ingest the transcript** until they decide.

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
HOST="35.x.x.x"

# BAD: SSH command revealing internal structure
token=$(ssh myhost 'grep TOKEN /path/to/.env')
```

## Every Repo Must Have

1. **`.gitignore`** that includes `.env`, `.env.local`, `*.pem`, `credentials.json`, `.claude/`
2. **`.env.example`** documenting required variables with placeholder values
3. **No inline defaults that leak specifics**: use `YOUR_VALUE` or `:?` to require the var

**Why `.claude/`?** The `.claude/settings.json` file contains agent hook configurations (curl-pipe-bash patterns, remote-exec URLs) that reveal internal architecture and represent a supply-chain risk in public repos. A portfolio-wide security scan confirmed this was systemic across 10+ repos and remediated it everywhere. Any config files containing infrastructure details (repo lists, port maps, process names) should also use gitignored files with `.example` templates.

## Sensitive Identifiers (Non-Secret Leaks)

Not all leaks are credentials. Usernames, private repo names, internal hostnames, and home directory paths also reveal infrastructure layout and should not appear in public repos, including in test fixtures, JSDoc examples, and documentation.

Before making a repo public or writing example code in a public repo:
1. Check your **private reference list of sensitive identifiers** for anything that must be sanitized
2. Replace real usernames, paths, and private project names with generic alternatives
3. Verify that repo names referenced in tests and docs are actually public

That reference list should record every known private identifier and its safe replacement. If you do not have one, use generic placeholders: `/home/user/`, `myProject`, `example.com`.

## Public Repo Commits Are Anonymous; the Private Repo Carries the Attribution

**A commit message is published exactly as widely as the diff.** It is on the commits page, in the Atom feed, in the search index, and in every `git log` a cloner runs. Writing one is a publishing act, and the audit habit ("read every line of `git diff --staged`") has to cover the message too.

The split, which applies to guidance files and commit messages alike:

| Public repo | Your private context repo |
|---|---|
| The rule, stated impersonally | Who asked for it, and their exact words |
| The failure mode and how it was detected | The people, employers, and rooms involved |
| The mechanism (API call, exit code, flag) | The account, sheet, channel, request id, message link |
| "A tracking sheet's source column" | Which sheet, which column |

Public text names **roles and shapes**, not **identities**: `a poster`, `one employer`, `a private community`, `<community> #<channel> (<poster>)`. That is enough for the rule to be followable by anyone; the private file supplies the lookup when your own environment needs to act on it. Link the two so neither is orphaned: the public section ends with a pointer to the private file, and the private file names its public counterpart.

**What must never reach a public commit (message or diff):**
- A directive quoted and attributed: `<Name>, <date>: "<what they said>"`. State the rule the directive produced. Attribution is what turns an ordinary preference into a published statement about a person.
- Names of individuals who are not the repo owner: posters, recruiters, hiring managers, referrers, interviewers. Third parties did not opt into the commit log.
- Private community and channel names, and message permalinks. A workspace name plus a channel identifies a membership list.
- Employers applied to or interviewed with, and applicant-tracking request ids. A job search is private; a commit log that names targets reconstructs it in date order.

### Every publish path, not just the commit

A repo publishes through more surfaces than `git push`, and each one is a separate write path that needs the same rule:

| Path | Gate |
|---|---|
| Staged file content | pre-commit hook |
| Commit message | commit-msg hook |
| Pushed diff | pre-push hook |
| PR/issue/release title and body, comments | a PreToolUse guard on Bash that inspects `gh` invocations |
| Already-published history | a retroactive exposure-sweep script |

`gh pr create --body "…"` posts straight to the GitHub API. No commit happens, so no commit gate ever sees it, and any automation that opens PRs on a public repo hits this path on every run. Keep the shared checks in one library that all gates source, so they enforce one definition rather than three drifting copies.

**A gate that cannot find its own library must say so.** These gates should fail open when the shared library is missing, because breaking every commit on the machine is worse than missing one check, but they must print a warning when they do. A silent fail-open is indistinguishable from a pass, and a refactor of one hook disabled two gates for exactly that reason before the warning existed.

### Employer and person names: why there is no pattern for them

Third-party names, employers under application, and request ids are forbidden in public repos but should **not** go in the blocked-identifier list, and that is deliberate. Company names collide with ordinary words: a game engine, a public repo name, a common noun. Adding them as global patterns produces a gate that fires constantly on nothing, and a gate people learn to bypass protects nothing.

What is enumerable is blocked: private community names, message permalinks, private repo names. What is not enumerable gets three weaker defences that add up:

- **Write-time generalisation.** The rule above. This is the one that actually works.
- **A shape check with no name list.** Match the *grammar* of an attributed directive, not who is named in it, so it catches new people automatically.
- **Corporate email domains**, which have no ambiguity: `someone@<employer>.com` in a public repo is always a finding. A sweep for these is what once found a forwarded email with two employees' work addresses sitting in a public portfolio repo, three months after it was committed.

**Enforcement, and its limit.** A commit-msg gate can block the enumerable half (identifier patterns, plus the quoted-directive shape) on public repos only, since attribution is exactly what private repos are *for*. It cannot enumerate people and employers: those change constantly and a pattern list will always trail them. **Generalise at write time.** The gate is a backstop for the cases someone already thought of, not a substitute for deciding what the sentence is allowed to say.

This section was written after a public-repo commit put a quoted directive, a private community, a named third party, and two employers on the public commits page, in the message *and* the diff. The content-only pre-commit hook had nothing to say about the message, and the identifier list had no category for people or closed rooms.

## AI Chat Export Files

AI chat exports are a high-risk PII vector. Export files routinely contain:
- **Sidebar chat titles** with sensitive topics (medical records, financial details, legal matters)
- **Email addresses** embedded in conversation metadata
- **Personal names and identifiers** from prior conversations

Never commit raw AI chat exports to any repository. If reference material from an AI conversation is needed:
1. Extract only the relevant content into a new file
2. Scrub any sidebar and metadata content before committing
3. Add the export directory to `.gitignore` (e.g., `Reference Files/`)
4. If the full export is needed for agent access, store it in your private context repo

This pattern caused a real incident: chat exports whose sidebar titles included medical topics were committed to a public repo and had to be emergency-removed.

## Automated Security Hooks (Pre-Commit + Pre-Push)

All public repos MUST have both pre-commit and pre-push hooks installed. These scan for sensitive identifiers before code reaches the remote.

### Hook Files

- `hooks/git-pre-commit` scans staged diffs at commit time
- `hooks/git-pre-push` scans all commits being pushed (catches amended commits, rebases, and cherry-picks that bypassed pre-commit)
- `hooks/install-hooks.sh` installs both hooks to one or all public repos

### How They Work

- **Pre-commit:** pipes `git diff --cached` through your identifier scanner. Blocks if any sensitive identifier is found.
- **Pre-push:** determines the commit range being pushed, checks whether the repo is public (via `gh repo view`), and scans the full diff. Only enforces on public repos; private repos pass through.

### Installation

```bash
# Install to all local public repos + set up the global git template
bash hooks/install-hooks.sh --all-public

# Install to a single repo
bash hooks/install-hooks.sh $HOME/<repo>
```

The `--all-public` flag also configures `~/.git-templates/hooks/` as the global git template directory, so any newly cloned repo automatically gets both hooks.

### For Agents

When creating a new public repo, or cloning one that does not have hooks yet, run:
```bash
bash hooks/install-hooks.sh $HOME/<repo>
```

**Why:** hardcoded VM credentials once survived in a public repo for months because only pre-commit hooks existed, and only on one repo. Pre-push hooks on every public repo would have caught it at push time regardless of where it happened.

### Legitimate `--no-verify` for Security Redactions

The hooks scan the full `git diff`, including removed lines. When you are *removing* a sensitive identifier (redacting), the removed line still contains the identifier and triggers the hook. This is a known catch-22: the hook blocks the very commit that fixes the problem.

**`--no-verify` is acceptable** when all of these are true:
1. The commit is purely a security redaction (removing or replacing sensitive identifiers)
2. The removed lines are the only hook violations (no new identifiers being added)
3. The commit message explicitly states the bypass reason (e.g., "Security remediation: --no-verify used because pre-commit hook flags the removal lines")

This pattern was validated across 7+ repos during an infrastructure redaction sweep.

## Pre-Commit Checklist (Manual Fallback)

When the automated hook is not installed, verify before committing to any public repo:

1. `grep -rn 'ssh.*@\|BEGIN.*KEY\|api.key\|webhook' .` finds no secrets in staged files
2. No IP addresses in code: `grep -rn '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' .`
3. No absolute paths to home directories
4. No private repo names or usernames in test fixtures, docs, or comments (check against your private identifier list)
5. `.gitignore` covers `.env*` files
6. Config files use environment variables, not hardcoded values
7. `git remote -v` shows no credentials embedded in remote URLs (see below)

## Credentials in Git Remote URLs

Using an HTTPS remote with an embedded PAT (`https://<token>@github.com/user/repo.git`) stores the token in `.git/config` in plaintext, visible in `git remote -v`, in shell history, and to any process that reads the config.

**Correct approaches:**
- Use SSH remotes: `git remote set-url origin git@github.com:user/repo.git`
- Or use the git credential store or a credential helper, with no token in the URL

**If already set:** rotate the PAT immediately (it was already exposed), then re-set the remote: `git remote set-url origin git@github.com:user/repo.git`

**How it happens:** `git clone https://<token>@github.com/...` bakes the token into `.git/config`; CI automation that sets remotes directly does the same. Check all remotes with `git remote -v` before considering a repo "clean." In the documented incident, a build VM's git remote was set with an embedded PAT that stayed live and visible until rotated.

## Architecture Documentation

When documenting internal systems in a public repo:
- Describe the **pattern** ("reverse SSH tunnel to a local machine"), not the **specifics** (`ssh -p 2222 user@1.2.3.4`)
- Use generic terms: "cloud VM", "local machine", "the bot", not hostnames or IPs
- Keep incident details focused on the **lesson**, not the infrastructure layout
- If specifics are needed, put them in a private repo or local notes

## Infrastructure Overshare in Context Files

`context.md`, `CLAUDE.md`, and deploy scripts in public repos must NOT include:
- **VM filesystem paths** (`/var/www/...`, `/opt/...`, `/home/deploy/...`)
- **Process-manager process names and port assignments** (this maps the full service architecture)
- **Internal API endpoint URLs** (e.g., `https://<domain>/api/internal-service/`)
- **SSH aliases or VM connection patterns** (e.g., `ssh myvm 'grep TOKEN ...'`)
- **Production health check URLs** with full domain and path
- **References to private companion repos** by name (e.g., `project-private/`)
- **Process-to-repo mappings** (these reveal which repos power which services)

**Instead:** use a pointer such as `"see <private-context-repo>/infrastructure.md"`. Infrastructure details belong in the private repo, which is never public. For scripts that need these values at runtime, use environment variables with `:?` guards (fail loudly if unset) or source them from private files.

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

**Common violation patterns in context files:**
```markdown
# BAD:
- Deploy: example.com/myapp via Apache ProxyPass to localhost:8080
- Process-manager process: myapp (id 4)
- Port: 8080 (production), 5000 (dev)

# GOOD:
- Deploy details: see your private context repo, infrastructure notes (myapp row)
```

## History Rewriting: Techniques and Collateral Damage

### Installation: git-filter-repo Path Gotcha

`git-filter-repo` installed via pip does **not** register as a git subcommand. Running `git filter-repo` fails with "not a git command" unless the binary is on `$PATH`.

A common install location is `~/.local/bin/git-filter-repo`, which is often not on `$PATH`. Invoke it directly:

```bash
~/.local/bin/git-filter-repo --invert-paths --path <file> --force
```

To check: `which git-filter-repo || ls ~/.local/bin/git-filter-repo`

### Email-Only Rewrites with Mailmap

To change commit author and committer emails without touching file content (for example, removing personal emails from public repo history), use `--mailmap`:

```bash
# 1. Unshallow first - filter-repo refuses to run on shallow clones
git fetch --unshallow 2>/dev/null || true

# 2. Create a mailmap file
echo "Name <new@email.com> <old@email.com>" > /tmp/mailmap

# 3. Rewrite history (changes metadata only, not file content)
git filter-repo --mailmap /tmp/mailmap --force
```

This is the right tool when a dependency audit or security scan flags personal emails in commit metadata. It does not touch file content, so collateral damage risk is minimal compared to `--replace-text`.

### Collateral Damage from Content Rewrites

`git filter-repo` replaces strings across **all commits including the current working tree**. This causes collateral damage when the replacement is too broad:

- A replacement for `/var/www/html` will also hit `.env.example` defaults, inline comments, and config fallbacks, even though the path itself is not a secret (it is a standard Apache default).
- A replacement for a username in paths (e.g., `/home/someuser/`) will break any SSH fallback or token-fetch command that references that path, even in scripts that are otherwise fine.

**After any history rewrite:**
1. Diff the working tree against what you expect: `git diff HEAD` should be empty, but check for `REDACTED_` artifacts in non-secret locations.
2. Run every script that changed. Syntax checks (`bash -n`) catch parse errors but not broken runtime behavior.
3. Check that gitignored files (`.env`, caches, state files) survived: `git reset --hard` and `git filter-repo` both wipe untracked and ignored files. Re-deploy them.
4. Verify on every machine the repo is cloned to (local and remote). A hard reset on a server to match the rewritten remote will wipe gitignored `.env` files there too.

**Scope replacements narrowly.** Replace the full string (the complete webhook URL) rather than substrings that appear in innocent contexts (a username that is also part of standard paths).

## Push-Forbidden Archive Repos

Some repos on disk are deliberately local-only archives: pre-sanitization backups, forensic copies, or experimental trees whose history must never reach a remote. These repos often carry `CLAUDE.md` annotations like "NEVER PUSH" or "local-only archive." But the `origin` remote may still be configured and point at a live repo.

**The trap:** a session read a suggestion mentioning "3 copies of a file" and applied a fix to all three repos, including a local archive. The push was rejected only because another push from the real checkout had already used the same branch name seconds earlier, a coincidence that prevented the archive's pre-sanitization history (30+ commits with unsanitized secrets) from reaching the public repo. No safety mechanism stopped it.

**Required when designating a repo as push-forbidden:**
```bash
# Immediately after writing "NEVER PUSH" in CLAUDE.md:
git remote remove origin
# Verify - should produce no output:
git remote -v
```

**Before touching any unfamiliar repo:**
```bash
grep -i "never push\|push.forbidden\|archive\|local.only" CLAUDE.md
# If any match: do NOT push from this repo under any circumstances
```

Disconnecting but keeping the remote name is not sufficient; a remote still listed in `git remote -v` creates false confidence. Remove it entirely so any accidental push fails immediately with "no remote configured" rather than silently landing on a live repo.

## When a Secret is Accidentally Committed

1. **Rotate immediately.** The secret is compromised the moment it is pushed.
2. **Rewrite history.** Use `git filter-repo` to remove it from all commits.
3. **Force-push** to update the remote.
4. **Verify the rewrite:** `git log --all -p | grep <secret>` should return 0 matches.
5. **Check for collateral:** grep for `REDACTED_` in the working tree; fix any unintended replacements.
6. **Restore gitignored files.** `.env` files, caches, and state files are wiped by history rewrites and hard resets; re-deploy them to all machines.
7. **Re-verify functionality.** Run every affected script on every machine; do not trust syntax checks alone.
8. **Check the host's cache.** PRs, issues, and cached pages may still show the secret.

## Never Interpolate a Credential Into a Log Line, Even to Report Presence

`${VAR:+yes}${VAR:-no}` looks like a boolean and is not:

- `${VAR:+yes}` gives `yes` when set
- `${VAR:-no}` gives **the value of VAR** when set; `no` only when UNSET

So when the variable IS set, the pair prints `yes<THE ACTUAL VALUE>`. Written to report "is this configured?", it prints the secret.

This bit in a real cron wrapper: it echoed two API keys into a transcript, and the same line would have written both into a persistent log file on any partial-config run. Both required rotation.

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

## A Blocking Gate With No Write-Time Counterpart Guarantees a Backlog

A secret or identifier gate that only BLOCKS, with nothing that REDACTS at write time, does not prevent leaks: it converts them into a growing pile of files that can never be committed. One generator reached 29 stuck posts this way, and kept adding more every session.

Three failure modes, all of which have to be fixed together:

1. **No redactor.** The scanner decided what was blocked but nothing decided what content should be replaced WITH. Fix: a redaction script that reads the *same* sensitive-identifiers file as the scanner, so the gate and the redactor cannot drift into "redacted but still blocked". Invariant worth testing: every pattern in the machine-parseable pattern list has a redaction-replacement entry.

2. **Swallowed failure.** The generator ran `git commit ... 2>/dev/null || true`. Every gate rejection was discarded, so the backlog grew invisibly for days. A gated write must log its rejection somewhere a human or agent will see it.

3. **Shared index.** The hook ran `git add` then a bare `git commit`, so one dirty file blocked every other session committing in the same checkout. Fix: `git add -- <path>` followed by `git commit -- <path>`. A path-limited commit builds a temporary index, so the pre-commit hook sees only that path and a peer's commit is neither swept in nor blocked. Verify this with a test.

**Corollary for allowlists:** an allowlist file (e.g. `.security-scan-allow`) is itself scanned. Explaining an exemption by naming the other blocked identifiers makes the allowlist uncommittable. Describe them ("its hostname, IP and deploy paths"); do not name them.

**Corollary for redaction targets:** replacement values are read by humans in published prose. Use a plausible generic value like `/var/www/app`, not a "(see private notes)" pointer.

## Gate Every Publish Path: PR and Issue Text Bypasses All Three Commit Gates

A repo publishes through more surfaces than `git push`. The commit path has three gates (pre-commit on content, commit-msg on the message, pre-push on the diff); PR and issue text has none, because `gh pr create --body` posts straight to the API without a commit. Gate it with a PreToolUse hook on Bash (public repos only), with the shared checks in one library so the gates cannot drift.

Two traps found while building this:

1. A hook that resolves its shared library by absolute path only takes the fail-open branch when run from a worktree, so BOTH gates silently passed everything and the test suite reported green. Fail-open is right (breaking every commit is worse) but it must WARN; a silent fail-open is indistinguishable from a pass. The general lesson: a fallback that keeps the end state healthy can hide a check running at 0% success for weeks.
2. Employer and person names must NOT become global blocklist patterns; they collide with ordinary words and public project names. Blanket patterns build a gate people learn to bypass. Enumerable things get blocked; the rest gets write-time generalisation, a name-free shape check, and a corporate-email-domain check.

Pair the hooks with a retroactive exposure-sweep script. That sweep is what found the thing the hooks could never have caught: a forwarded email with two employees' work addresses in a public portfolio repo, three months after commit.
