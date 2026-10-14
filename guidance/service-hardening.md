<!-- Load when: restricting a service to a VPN/private interface, auditing whether a port is actually exposed, hardening a host-installed service after its installer ran, or hardening a Docker/container service for long-running reliability -->
# Service Hardening and Exposure Auditing

Binding a service to a private interface is a claim about the whole host, not about your rules. Three things routinely make that claim false.

## 1. The Installer's Own Firewall Rule Outranks Yours

Installers (MSI, .deb postinst, setup scripts) often add a blanket allow rule for their own binary during installation. That rule is usually **scoped to the program, with no port, interface, profile, or remote-address restriction**.

Allow rules **do not narrow each other**: traffic that matches *any* enabled allow rule is admitted, so one unrestricted allow rule for the binary makes every narrowly scoped allow rule you add afterward decorative. You can write a perfect interface-scoped ruleset and still not change who can reach the service. (An explicit *block* rule is different: on Windows Firewall and most host firewalls a matching block overrides a conflicting allow. Check your firewall's precedence rules before relying on either behavior.)

**Before you add your own rules, list the rules the installer created**, then disable or remove them. Grep the installer's own scripts to find where the rules come from:

```
# Windows: what did the installer add for this program?
Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True | ForEach-Object {
  $ap = $_ | Get-NetFirewallApplicationFilter
  if ($ap.Program -like '*<binary>*') { $_.DisplayName }
}
```

**If the installer manages the rule, disable it rather than deleting it.** A disabled rule still shows up in an audit and is easy to turn back on.

**Check whether the rules are added at install time or at service start.** Read the installer's scripts. If a helper script adds them and the service does not, a disabled rule stays disabled. If the service re-adds them every time it starts, disabling them achieves nothing and you need a different approach.

**Assume an upgrade re-adds them.** Installers that run an unconditional `add rule` (instead of checking first) re-create the blanket rule on every version bump, so any upgrade can undo your hardening. Record this as a follow-up and don't treat the fix as permanent.

## 2. Scope by Interface AND Address, Not by Profile

When you restrict a service to a VPN interface, apply two independent filters that must both match:

- the interface (adapter alias or name), and
- the VPN's address space as the allowed remote range.

**Do not scope by network profile** (Windows Private/Public, firewalld zones). The OS can recategorize an adapter on its own, which silently widens the rule. An interface + address rule survives recategorization; a profile rule does not.

Most services bind `0.0.0.0` and do not choose an interface themselves. In that case the firewall is the *only* control, which is why one stray allow rule exposes everything.

## 3. Prove a Negative from Outside the Perimeter

Reading your own firewall rules does not prove a service is "not exposed to the internet". Rules describe what you intended; a reachability test tells you what actually happens. Test the public address from a host that is really outside the perimeter (a cloud VM, a phone off wifi). Never report "not exposed" until you have actually run that probe and seen it fail.

Also test from a second interface that is not on the VPN. A block on the LAN-facing address is a separate fact from a block on the public address, and neither one is the same as "my rule looks right".

**Read results from the local host carefully.** A container or VM that shares the host (WSL, Docker with host networking) may NAT through the host and correctly appear as an on-VPN source, so it can reach a VPN-scoped port. That is access from the host itself, not network exposure. Report it precisely; don't ignore it and don't call it a leak.

## 4. A Port That Is Not Bound Yet Cannot Be Verified Yet

Many services open only their control or listener ports at startup. Media, data, or worker ports are bound **per session**. If you audit while the service is idle, those ports show as unbound, which looks like a misconfiguration but isn't one.

Do not "fix" a rule for a port that just isn't open yet. Record the rule as provisioned but unverified, and confirm it during a real session. Calling it verified before a session has run is a false claim that the work is complete.

## 5. Docker `restart: unless-stopped` Cannot Recover Hung Containers

`restart: unless-stopped` only triggers when the container's entrypoint process **exits** (crash, OOM kill, daemon restart). A hung or wedged container, where the process is still running but no longer serving requests, stays in the `Up` state indefinitely. `docker ps` looks healthy while the service is dead. A typical symptom is a container reported `Up` for days with nothing listening on its port.

**Pattern: Docker HEALTHCHECK + external watchdog**

Add a HEALTHCHECK inside the container so a script can read the unhealthy state:

```yaml
# docker-compose.yml
healthcheck:
  test: ["CMD", "curl", "-sf", "http://127.0.0.1:PORT/<health-endpoint>"]
  interval: 60s
  timeout: 5s
  retries: 3
```

Then add an external watchdog that acts on it (a systemd timer every 5 minutes, or a cron job guarded with flock):

```bash
status=$(docker inspect --format='{{.State.Health.Status}}' CONTAINER 2>/dev/null || echo "missing")
if [[ "$status" == "unhealthy" || "$status" == "missing" ]]; then
  docker compose restart SERVICE   # or: docker compose up -d SERVICE
fi
```

**Why HEALTHCHECK alone is not enough:** a HEALTHCHECK only changes the reported `Health.Status` field. Docker does NOT restart a container just because it is `unhealthy`. Something else has to act on that status, either an autoheal-style helper container or your own external watchdog. The watchdog is what actually recovers the service.

**Probe the endpoint, not just the container state.** An endpoint check (`curl -sf`) is harder to fool than `docker inspect`. Use both: the HEALTHCHECK gives you machine-readable state, and the watchdog acts on it. Add a cooldown between restarts so a service that is down for good doesn't get stuck in a restart loop.

**Cap logs before they fill the disk.** By default, Docker json-file logs and the systemd journal have no size limit. Set a global Docker default in `/etc/docker/daemon.json`:

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
```

And cap journald in `/etc/systemd/journald.conf`:
```
SystemMaxUse=300M
```

After editing daemon.json, run `sudo systemctl reload docker` (or `restart docker`) and recreate the containers. Existing containers keep their old log settings until they are recreated.

## Reporting

Say plainly which checks you ran and where you ran them from, and which guarantees are proven versus only provisioned. "Blocked from the public internet (tested from an external host)" and "UDP range provisioned but unverified until a session runs" are different claims. Don't merge them into one word like "hardened".
