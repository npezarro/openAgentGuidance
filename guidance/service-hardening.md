<!-- Load when: restricting a service to a VPN/private interface, auditing whether a port is actually exposed, hardening a host-installed service after its installer ran, or hardening a Docker/container service for long-running reliability -->
# Service Hardening and Exposure Auditing

Binding a service to a private interface is a claim about the whole host. Your own rules do not make it true on their own, and three things routinely make it false.

## 1. The Installer's Own Firewall Rule Outranks Yours

Installers (MSI, .deb postinst, setup scripts) often add a blanket allow rule for their own binary during installation. That rule is usually **scoped to the program only, with no restriction on port, interface, profile or remote address**.

Allow rules **do not narrow each other**. Traffic that matches *any* enabled allow rule gets in. So one unrestricted allow rule for the binary turns every narrowly scoped allow rule you add later into decoration. You can write a perfect interface-scoped ruleset and still change nothing about who can reach the service. (An explicit *block* rule works differently: on Windows Firewall and most host firewalls, a matching block overrides a conflicting allow. Check your firewall's precedence before you rely on either.)

**Always list the rules the installer created before you add your own**, then disable or remove them. To find where the rules come from, grep the installer's scripts:

```
# Windows: what did the installer add for this program?
Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True | ForEach-Object {
  $ap = $_ | Get-NetFirewallApplicationFilter
  if ($ap.Program -like '*<binary>*') { $_.DisplayName }
}
```

**Disable installer-managed rules rather than deleting them.** A disabled rule still shows up in an audit and is easy to turn back on.

**Find out whether the rules are added at install time or at service start.** Read the installer's scripts. If a helper script adds them and the service does not, disabling them sticks. If the service adds them again every time it starts, disabling is useless and you need a different approach.

**Assume an upgrade adds them back.** An installer that runs `add rule` unconditionally (instead of checking first) recreates the blanket rule on every version bump, so your hardening is one upgrade away from being undone. Record this as a follow-up. Do not treat the fix as permanent.

## 2. Scope by Interface AND Address, Not by Profile

To restrict a service to a VPN interface, apply two separate filters that must both match:

- the interface (adapter alias or name), and
- the VPN's address space as the allowed remote range.

**Do not scope by network profile** (Windows Private/Public, firewalld zones). The OS can recategorize an adapter on its own, which silently widens the rule. An interface + address rule survives recategorization; a profile rule does not.

Most services bind `0.0.0.0` and do not choose an interface themselves. That leaves the firewall as the *only* control, which is why one stray allow rule is fatal.

## 3. Prove a Negative from Outside the Perimeter

Reading your own firewall rules does not prove a service is "not exposed to the internet". Rules describe what you intended; reachability is what actually happens. Test the public address from a host that is really outside the perimeter, such as a cloud VM or a phone with wifi off. Before you report that something is unreachable, confirm the test could have succeeded: the service is up and answers from an allowed source.

Also test from a second interface that is not on the VPN. A block on the LAN-facing address, a block on the public address and "my rule looks right" are three separate facts.

**Read local-host results carefully.** A container or VM that shares the host (WSL, Docker with host networking) may NAT through the host and show up as a source on the VPN, so it can legitimately reach a VPN-scoped port. That is local access on the host, not network exposure. Say exactly that; do not ignore it, and do not report it as a leak.

## 4. A Port That Is Not Bound Yet Cannot Be Verified Yet

Many services open only their control or listener ports at startup. They bind media, data or worker ports **per session**. An audit at idle shows those ports unbound. That looks like a misconfiguration but is not one.

Do not "fix" a rule for a port that simply is not open yet. Record the rule as provisioned but unverified, and confirm it during a real session. Calling it verified before a session has run is a false claim of completion.

## 5. Docker `restart: unless-stopped` Cannot Recover Hung Containers

`restart: unless-stopped` only fires when the container's entrypoint process **exits** (crash, OOM kill, daemon restart). A hung container, where the process is still running but no longer serving requests, stays `Up` forever. `docker ps` looks healthy while the service is dead: it can show `Up 9 days` with nothing listening on the port.

**Pattern: Docker HEALTHCHECK + external watchdog**

Add a HEALTHCHECK inside the container so the unhealthy state is machine-readable:

```yaml
# docker-compose.yml
healthcheck:
  test: ["CMD", "curl", "-sf", "http://127.0.0.1:PORT/ping-or-settings"]
  interval: 60s
  timeout: 5s
  retries: 3
```

Then add an external watchdog that acts on it, either a systemd timer every 5 minutes or a cron job guarded with flock:

```bash
status=$(docker inspect --format='{{.State.Health.Status}}' CONTAINER 2>/dev/null || echo "missing")
if [[ "$status" == "unhealthy" || "$status" == "missing" ]]; then
  docker compose restart SERVICE   # or: docker compose up -d SERVICE
fi
```

**Why HEALTHCHECK alone is not enough:** a HEALTHCHECK only changes the reported `Health.Status` field. Docker does NOT restart a container just because it is `unhealthy`. Something else has to do that, such as an autoheal companion container or an external watchdog. The watchdog is what actually recovers the service.

**Probe the endpoint, not just the container state.** A real request to the endpoint (`curl -sf`) is harder to fool than `docker inspect`. Use both: the HEALTHCHECK for machine-readable state, and the watchdog to act on it. Add a cooldown between restarts so a service that is down for good does not get restarted in a tight loop.

**Cap logs before they fill the disk.** By default, Docker json-file logs and systemd journald grow without limit. Set a global Docker default in `/etc/docker/daemon.json`:

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
```

Cap journald in `/etc/systemd/journald.conf`:
```
SystemMaxUse=300M
```

After you edit daemon.json, run `sudo systemctl reload docker` (or `restart docker`) and recreate the containers. Existing containers keep their old log settings until they are recreated.

## Reporting

Say plainly which checks you ran and where you ran them from, and which guarantees are proven and which are only provisioned. "Blocked from the public internet (tested from an external host)" and "UDP range provisioned but unverified until a session runs" are different claims. Do not merge them into "hardened".
