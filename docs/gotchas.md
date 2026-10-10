# Gotchas

Everything here cost me time. Each entry says what you see, why it happens, and what the scripts do about it.
Versions are the ones I used: Ubuntu 26.04 (host and VM), Incus 6.0.5, Paperclip `2026.916.1`, npm 11.19, Node 24.21.

## ufw and the Incus bridge don't cooperate

**Symptom:** a new VM never gets an IP address, or gets one but can't reach the internet.
**Why:** ufw's defaults drop DHCP and forwarded traffic on the bridge. Same family of problem as Docker bypassing ufw.
**Trap:** Ubuntu's stock ufw rules drop DHCP and broadcast packets *without logging*, so `/var/log/ufw.log` stays empty and you can't see the cause.
**Debugging tip:** `sudo incus exec <vm> -- networkctl list` works without any networking (it goes over vsock).
**Fix:** `host/20-firewall.sh` adds narrow rules (DHCP, DNS, forwarding to the uplink) instead of the blanket `allow in on incusbr0` that Incus's docs suggest. That blanket rule would also expose the host's SSH to the VM.

## ufw syntax: `log` position in route rules

`ufw route reject in on X out on Y log to ...` works. Putting `log` right after the action (`ufw route reject log in on X ...`) fails with `Invalid interface clause`. To check syntax without root, use `sudo ufw --dry-run ...`.

## ufw adds IPv6 copies of every rule

With `IPV6=yes` in `/etc/default/ufw`, each rule gets a `(v6)` twin. For the bridge (no IPv6) that is useless, and the twin of the egress *allow* is dangerous: the LAN rejects are IPv4-only, so a v6 twin would be an unfiltered path to your LAN if IPv6 were ever enabled on the bridge. The firewall script deletes the twins (`::/0` in the delete spec matches only them). If you ever turn on IPv6 for the bridge, write v6 rules on purpose, including rejects for `fc00::/7`, `fe80::/10` and your LAN's prefix.

## `grep` skips ufw.log

If `/var/log/ufw.log` contains NUL bytes (mine did, after a hard power-off test), `grep` treats it as binary and prints nothing. Use `grep -a`, or `journalctl -k | grep UFW`.

## Moving the host from Wi-Fi to Ethernet

The firewall rules name the uplink interface. After a change, set `UPLINK` in `config.env` and re-run `sudo ./bootstrap.sh host`, then remove the old interface's rules (`sudo ufw status numbered`, `sudo ufw delete N`). Otherwise the VM loses internet.

## `paperclipai install` is broken with npm 11

**Symptom:** `npm returned an unexpected version response`, nothing installed. Present in both `2026.916.1` and `2026.1005.0`.
**Why:** it runs `npm view paperclipai@<spec> version --json`. npm 11 returns a JSON *array* (`["2026.916.1"]`), but the parser only accepts a string or a bare version.
**Workaround (used by `vm/60-paperclip.sh`):** `npm install -g paperclipai@<version>`, plus a hand-written launcher in the same format as the managed shim. The service finds it through the official `PAPERCLIP_SHIM_PATH` override.
**Cost:** `paperclipai update` / `rollback` don't work. Upgrade with `npm i -g paperclipai@<new>` and re-run `./bootstrap.sh vm 60`; roll back with a VM snapshot. This is worth reporting upstream.

## Do NOT put the launcher at `~/.local/bin/paperclipai`

**Symptom:** the service crash-loops (systemd gives up after 5 restarts) with `Doctor found blocking issues. Not starting server.`
**Why:** `paperclipai doctor` treats that exact path (and a few files under `~/.paperclip/cli/`) as artifacts of a *managed install*. If the path exists but `install.json` doesn't, doctor fails "Managed install manifest", and `paperclipai run`, which is what the service executes, refuses to start.
**Fix:** the launcher lives at `~/.local/libexec/paperclipai-launcher`, and `PAPERCLIP_SHIM_PATH` points there, both in your shell and in the systemd drop-in. Don't fake an `install.json`.

## Paperclip's embedded PostgreSQL fails with exit code 127

**Symptom:** `Postgres init script exited with code 127` (seen with `test-drive`, which uses the embedded database).
**Why:** `@embedded-postgres/linux-x64` ships real libraries (`libpq.so.5.18`, an old ICU 60) and relies on its `postinstall` to create the symlinks (`libpq.so.5`, `libicuuc.so.60`, ...). npm 11 blocks dependency install scripts by default, so the symlinks never appear. ICU 60 isn't in Ubuntu 26.04's archive, so apt can't supply it either.
**What this repo does:** avoids the problem by using Ubuntu's own PostgreSQL (`vm/50-postgres.sh`). If you do want the embedded database, run the package's own `scripts/hydrate-symlinks.js` from its directory (review it first; it only creates symlinks listed in `native/pg-symlinks.json`).

## npm 11 blocks install scripts: leave it that way

During `npm i -g paperclipai`, npm reports blocked scripts for `@embedded-postgres/linux-x64`, `ssh2`, `protobufjs` and `cpu-features`. With an external database none are needed (`ssh2`/`cpu-features` are optional native speed-ups). Don't "fix" the warning by setting `allow-scripts` globally: that allows install scripts from every future dependency.

## postgres.js ignores `?host=` in the connection URL

Paperclip uses postgres.js, which takes the host from the URL's hostname or `PGHOST`, never from `?host=/path`. For a Unix socket use `DATABASE_URL=postgres:///paperclip` together with `PGHOST=/var/run/postgresql`. (`postgres://agents@/paperclip` is an invalid URL: credentials with an empty host.) The scripts set `PGHOST` in both the shell environment and the service drop-in.

## Onboarding menus default to the "safe local" choice

Every menu in `paperclipai onboard` highlights the quick, local-only option (Quickstart, Trusted local). Pressing Enter without moving the arrow keys picks it. This repo's README lists the choices to make. To fix only the server section later: `paperclipai configure --section server`.

## `reachability: tailnet` doesn't work when the VM isn't a tailnet node

Paperclip's `tailnet` option detects a Tailscale IP to bind to. The VM deliberately has none (see the README's architecture notes), so it falls back to loopback and the UI is unreachable from the host. Use "Private network (`lan`)", which binds `0.0.0.0` inside the VM. The VM's firewall then limits port 3100 to the host.

## Paperclip's hostname allowlist

In `authenticated` + `private` mode, requests whose `Host` header isn't allowlisted get `403`. Add your tailnet hostname during onboarding, or later with `paperclipai allowed-hostname <name>`. A `403` from `http://<vm-ip>:3100` is therefore normal and good.

## `test-drive` is not the real install

It forces `local_trusted` mode (no login), binds to `127.0.0.1` only (so `tailscale serve` can't reach it; use an SSH tunnel), and deletes every `PAPERCLIP_*` environment variable before starting, so `PAPERCLIP_TELEMETRY_DISABLED` has no effect there. Use `DO_NOT_TRACK=1`, which survives.

## Telemetry

On by default. Two switches are checked: `PAPERCLIP_TELEMETRY_DISABLED=1` and `DO_NOT_TRACK=1`. The scripts set both, plus `DISABLE_TELEMETRY` / `DISABLE_ERROR_REPORTING` for the Claude Code CLI that agents run.

## nvm only loads in interactive shells

systemd services, `ssh host command`, and cron don't source `.bashrc`'s interactive part. The launcher therefore hardcodes Node's absolute path, and `~/.agent-box-env` is sourced at the *top* of `.bashrc` (before Ubuntu's "return if not interactive" guard). **Consequence:** after upgrading Node, re-run `./bootstrap.sh vm 60`.

## Rootless Docker details

* Needs `uidmap`, `dbus-user-session` and `slirp4netns`, a subuid/subgid range for the user, lingering enabled, and (on Ubuntu 24.04+) an AppArmor profile that allows `rootlesskit` to create user namespaces. Ubuntu 26.04 ships the profile; the script adds one if yours doesn't.
* Published ports are ordinary user-space sockets, so the VM's ufw *does* filter them, unlike rootful Docker, which writes its own iptables rules around ufw. Still bind to `127.0.0.1:PORT:PORT` out of habit.
* Docker's packages come from Docker's apt repo, which unattended-upgrades doesn't cover. Update them deliberately.

## cloud-init and the removed default user

`cloud-init schema --config-file` reports "Invalid user-data" for any file in `cloud.cfg.d`, the stock ones included, because it expects a `#cloud-config` header. That is a validator quirk. To validate, add the header to a temp copy.

## NIC name changes between boots

The VM's interface appeared as `enp5s0` on first boot and `eth0` after a restart. Don't hardcode it in anything inside the VM.

## Ubuntu 26.04 ships sudo-rs

A refused `sudo` prints "I'm afraid I can't do that" instead of the classic message. Same meaning.

## The storage pool can grow but never shrink

`incus storage set default size=380GiB` grows a loop-file pool live. Shrinking fails ("Pool cannot be shrunk"). Size it generously, but remember it's sparse: it only uses what's written.
