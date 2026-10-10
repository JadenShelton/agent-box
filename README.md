# agent-box

A small, locked-down home server for running [Paperclip](https://github.com/paperclipai/paperclip) (open-source multi-agent orchestration) and the AI coding agents it manages, with the agents confined to a virtual machine that can reach the internet but not your home network.

> **Status.** The design and every individual step were built and verified by hand on a real machine (details in [How I run it](#how-i-run-it)). The scripts in this repo are those steps, generalized and parameterized. The end-to-end run of the generalized scripts on a clean VM is tracked in [Testing status](#testing-status): read that before trusting a step.

```
                         your workstation
                               │  ssh -J (key only)          https (tailnet only)
                               ▼                                      │
┌──────────────────────── HOST (thin) ───────────────────────────────┼──────────────┐
│  SSH · Tailscale · ufw · Incus (hypervisor)         tailscale serve ─┘              │
│  No Docker, Node, Paperclip or agent CLIs on the host.                              │
│                                                                                      │
│   ufw:  VM ──► internet   ✔ allowed                                                 │
│         VM ──► LAN / router / other servers / host SSH / tailnet   ✘ rejected       │
│                                                                                      │
│   ┌──────────────────────── VM (Ubuntu, Incus/QEMU) ─────────────────────────┐      │
│   │ user `agents` (no sudo, key-only SSH from the host only)                 │      │
│   │   Paperclip service (:3100) ── PostgreSQL (Unix socket only)             │      │
│   │        │ launches, per task                                              │      │
│   │        ▼                                                                 │      │
│   │   agent CLIs (Claude Code, …)  ── rootless Docker (docker compose ok)    │      │
│   │ VM firewall: deny in; 22 and 3100 from the host only                     │      │
│   └──────────────────────────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

## Contents

1. [Why this exists](#why-this-exists)
2. [Design decisions](#design-decisions)
3. [Threat model](#threat-model)
4. [Requirements](#requirements)
5. [Quick start](#quick-start)
6. [Step-by-step walkthrough](#step-by-step-walkthrough)
7. [Onboarding Paperclip](#onboarding-paperclip)
8. [Day-two operations](#day-two-operations)
9. [Giving agents somewhere to put their work](#giving-agents-somewhere-to-put-their-work)
10. [Cost notes](#cost-notes)
11. [How I run it](#how-i-run-it)
12. [Testing status](#testing-status)
13. [Repo layout](#repo-layout)
14. [Gotchas](docs/gotchas.md)

## Why this exists

AI coding agents are most useful when they can run commands, install dependencies and start containers, which is exactly what you don't want an unattended program doing on a machine that also holds your family photos, your media server or your credentials. I wanted a box that is **always on**, **cheap to run**, and where "the agent went off the rails" has a small, known blast radius.

Paperclip is the management layer: an org chart of agents, tickets, budgets and an audit trail, in a self-hosted web UI. The agents themselves are external CLIs (Claude Code, Codex, ...) that Paperclip launches through adapters. This repo is the infrastructure underneath: where they run, what they can reach, and how to rebuild it.

## Design decisions

| Decision | Why | Trade-off accepted |
|---|---|---|
| **Everything agent-related runs in one full VM; the host stays thin** | Agents run `docker compose`. In a container that means giving them the Docker socket or privileged mode, i.e. root on the host. In a VM, Docker runs *inside* and the VM is the boundary. | VM memory is reserved up front; some overhead. |
| **Incus** as the hypervisor | One small CLI for VMs and containers, in Ubuntu's own archive (gets security updates), clean snapshot support. | Less well known than Proxmox/libvirt; no GUI. |
| **Not microVMs (Firecracker, ...)** | Built for multi-tenant platforms. For one user and a few long-lived agents they add tooling without adding protection that matters here. | None for this use case; a fun weekend experiment later. |
| **One VM, not one per agent** | Paperclip's local adapters run every agent as the *same OS user* as Paperclip, on the same machine. Per-agent VMs would mean running Paperclip remotely. | Agents can see each other's files and credentials. See the [threat model](#threat-model). |
| **btrfs storage pool (loop file)** | Copy-on-write snapshots: snapshot before every experiment, roll back instead of repairing. A sparse file works even when the disk is fully allocated to one LVM volume. | Can grow, can never shrink. |
| **No sudo-capable account inside the VM** | Admin is only from the host via `incus exec` (root over vsock, not the network). A compromised agent has nothing to escalate to, and a broken SSH/firewall config in the VM can't lock you out. | You need access to the host to administer the VM. |
| **`agents` user: non-admin, key-only SSH, reachable only from the host** | Principle of least privilege. `ssh -J` through the host; no agent forwarding, ever. | Two hops to log in (one SSH config entry hides it). |
| **Rootless Docker, not the `docker` group** | The `docker` group is root-equivalent. Rootless keeps container escapes inside the `agents` user. Rootless published ports are ordinary user sockets, so the VM firewall filters them (rootful Docker writes iptables rules that bypass ufw). | No ports below 1024; slight network overhead. |
| **Host firewall rejects VM → private ranges** | The adversary is a confused or prompt-injected agent, or a malicious dependency. The thing worth protecting is the rest of your network. | The VM can't use LAN services (a local package mirror, a NAS). Open a specific hole on purpose if you need one. |
| **The VM does not join the tailnet; the host proxies one port** | A tailnet node can reach all your other nodes, which would undo the egress block. `tailscale serve` on the host forwards a single port; the VM firewall accepts it from the host only. | One more moving part. |
| **Ubuntu's PostgreSQL over a Unix socket, not Paperclip's embedded one** | Automatic security updates; no dependency on npm install scripts (blocked by npm 11, see gotchas); socket-only means no network listener and no password. | One more package to know about. |
| **Pinned versions** (Paperclip, nvm, Node) | Paperclip publishes several canary builds a day. Upgrade deliberately, with a snapshot first. | You must remember to upgrade. |
| **Dedicated API key with a spend limit, held only in the VM** | A runaway agent loop can only burn what the limit allows. | Setup effort in the Anthropic Console. |

## Threat model

**Who is the adversary?** A prompt-injected or merely confused agent, or a malicious package an agent installed. Not another tenant; this is a single-user box.

**What the setup protects**
- Your LAN, router and other servers: unreachable from the VM (checked by `./bootstrap.sh verify`).
- The host: no mounts, no shared directories, no shared sockets, no host services reachable from the VM except DHCP/DNS, and the hypervisor boundary.
- Your workstation's keys: SSH agent forwarding is disabled client- and server-side.
- Your money: a dedicated API key in its own Anthropic workspace with a monthly limit, plus Paperclip budgets.
- Your accounts: nothing personal lives in the VM. GitHub and Drive access go through dedicated bot accounts (see below).

**What it does not protect**
- **Agents from each other.** They share one OS user, one home directory and one set of credentials. An agent that goes bad can read everything the others can. If that matters, run separate Unix users (or separate VMs, with Paperclip's remote adapters).
- **Anything inside the VM.** Treat the VM as disposable: the data worth keeping lives in git remotes and Paperclip's database backups.
- **The internet side.** A rogue agent can still reach the internet: exfiltrate what it can read, call APIs with keys it can see, or attack third parties. Mitigations are credential scoping (narrow, expiring, revocable tokens) and, if you want to go further, an egress allow-list proxy.
- **A hypervisor escape.** Low probability, but it exists. Keep the host patched (unattended-upgrades is on by default on Ubuntu Server).
- **Everything on your tailnet can open the UI URL.** Paperclip's login is the guard; a Tailscale ACL grant can narrow it further.

## Requirements

**Host**
- Ubuntu Server 24.04+ (developed on 26.04), x86-64 with hardware virtualization on (VT-x/AMD-V enabled in the BIOS, `/dev/kvm` present).
- Enough RAM and disk for what you give the VM (defaults: 8 GiB, 60 GiB disk, 100 GiB sparse pool).
- Already hardened the usual way before you start: key-only SSH, `ufw` **active** with default-deny incoming, unattended upgrades. The scripts add rules for the VM; they deliberately do *not* enable ufw or touch SSH on the host, because a mistake there can lock you out. **If ufw is inactive, the LAN block is not enforced**; the firewall script warns about this.
- (Optional) Tailscale on the host with HTTPS certificates enabled, to reach the UI from your other devices.

**You also need**
- A workstation with an SSH key pair dedicated to this VM (`ssh-keygen -t ed25519 -f ~/.ssh/agent_box_agents`), with the `.pub` file copied to the host.
- An Anthropic Console account where you can create a **workspace** with a spend limit, and a key inside it.

## Quick start

On the host:

```bash
git clone https://github.com/JadenShelton/agent-box.git && cd agent-box
cp config.example.env config.env      # keep only the lines you want to change (VM size, blocked ranges, ...)
sudo ./bootstrap.sh firewall          # dry run: read what it would do first
sudo ./bootstrap.sh host              # Incus, firewall rules, VM, baseline snapshot
sudo ./bootstrap.sh vm                # everything inside the VM
sudo ./bootstrap.sh snapshot provisioned
sudo ./bootstrap.sh verify            # prove the VM can reach the internet and nothing else
sudo ./bootstrap.sh onboard           # interactive; see "Onboarding Paperclip" for the answers
sudo ./bootstrap.sh service           # start Paperclip as a service
sudo ./bootstrap.sh expose            # optional: https://<host>.<tailnet>.ts.net
```

Set `VERIFY_BLOCKED` in `config.env` first (e.g. `"192.168.1.1:80 192.168.1.50:22"`) so `verify` actually tests *your* router and servers. To log in from your workstation: `sudo ./bootstrap.sh ssh-config` prints an `~/.ssh/config` block.

Every script is short, commented with the *why*, and safe to read before running. Please do.

## Step-by-step walkthrough

### Host

| Script | What it does and why |
|---|---|
| [`host/10-incus.sh`](host/10-incus.sh) | Checks KVM, installs Incus from Ubuntu's archive, creates a btrfs pool on a sparse loop file and an IPv4-only NAT bridge. Doesn't add you to `incus-admin` (root-equivalent), so VM actions need `sudo`. |
| [`host/20-firewall.sh`](host/20-firewall.sh) | Opens exactly: DHCP and DNS on the bridge, then **rejects** VM → private ranges, then allows VM → uplink. Order matters (first match wins); the script handles re-runs. Removes IPv6 twins. Dry run by default. |
| [`host/30-vm.sh`](host/30-vm.sh) | Creates the VM (`--vm`), pins its IP, sets CPU/RAM limits and `boot.autostart`, waits for cloud-init, takes a clean `baseline-firstboot` snapshot. No host mounts, no passthrough. |
| [`host/40-tailscale-serve.sh`](host/40-tailscale-serve.sh) | Optional. `tailscale serve` (tailnet only, never `funnel`) proxies the UI port from the host to the VM. |

### Inside the VM

All run as root over `incus exec` (vsock, no network). Steps that need the `agents` user drop to it with a real user-session environment.

| Script | What it does and why |
|---|---|
| [`vm/10-ssh-and-firewall.sh`](vm/10-ssh-and-firewall.sh) | Removes the image's default sudo user; writes the SSH hardening config **before** installing sshd (it never runs with defaults); `AllowUsers agents@<host-bridge-ip>`; ufw deny-in with SSH and the Paperclip port allowed from the host only. |
| [`vm/20-agents-user.sh`](vm/20-agents-user.sh) | Creates `agents`: own group, locked password, no sudo, your public key. |
| [`vm/30-docker.sh`](vm/30-docker.sh) | Docker from Docker's apt repo (key fingerprint checked first). The rootful daemon is **disabled**; rootless prerequisites and lingering configured. |
| [`vm/31-docker-rootless.sh`](vm/31-docker-rootless.sh) | Sets up the rootless daemon as `agents`; runs `hello-world` and checks `docker compose`. |
| [`vm/40-node.sh`](vm/40-node.sh) | nvm (pinned tag, installer saved to a file, not piped from `master`) → Node 24 in the agents' home, so agents can `npm i -g` without root. |
| [`vm/50-postgres.sh`](vm/50-postgres.sh) | Ubuntu's PostgreSQL, no TCP listener, role `agents` (not superuser) owning database `paperclip`, peer auth (no password). |
| [`vm/60-paperclip.sh`](vm/60-paperclip.sh) | Installs the pinned Paperclip and Claude Code, a launcher for systemd, telemetry-off environment, and the service drop-in. |
| [`vm/70-service.sh`](vm/70-service.sh) | After onboarding: installs and starts the systemd user service; checks health. |

### Verification

- [`verify/egress-check.sh`](verify/egress-check.sh) (`./bootstrap.sh verify`): from inside the VM, proves internet works and the host's SSH (via bridge, LAN and tailnet addresses) and your listed LAN targets are blocked. Exits non-zero on any gap.
- [`verify/vm-audit.sh`](verify/vm-audit.sh) (`./bootstrap.sh audit`): read-only inventory: accounts, sudo groups, sshd settings, firewall, listeners, rootful Docker state.

## Onboarding Paperclip

`./bootstrap.sh onboard` is interactive. **Every menu's highlighted default is the quick, local, no-login choice**, and several prompts (backups, logging, storage) have no "accept the default" key: you must type or paste the values, even when they match the suggestion. Answer like this:

| Prompt | Answer |
|---|---|
| Choose setup path | **Advanced setup** (move the arrow; Quickstart is highlighted) |
| Database mode | **PostgreSQL (external server)** |
| PostgreSQL connection string | **`postgres:///paperclip`** (the socket directory comes from `PGHOST`, which the scripts set) |
| Enable automatic database backups? | **Yes** |
| Backup directory | `/home/agents/.paperclip/instances/default/data/backups` |
| Backup interval (minutes) / retention (days) | `120` / `7` |
| *(expect "Database connection successful")* | |
| Configure an LLM provider now? | **No** (the API key goes in later, through the UI, as a secret) |
| Logging mode / log directory | File-based logging / `/home/agents/.paperclip/instances/default/logs` |
| Reachability | **Private network (`lan`)**: authenticated mode, binds `0.0.0.0` inside the VM (the VM firewall limits it to the host). **Not `tailnet`**: it looks for a Tailscale IP, the VM has none, and it falls back to loopback. |
| Server port | `3100` |
| Allowed private hostnames | the name you will browse to, e.g. `<host>.<tailnet>.ts.net` (add more later with `./bootstrap.sh paperclip allowed-hostname <name>`) |
| Storage provider / base directory | Local disk / `/home/agents/.paperclip/instances/default/data/storage` |
| Secrets | none asked: defaults are used (`local_encrypted`, strict mode **off**; we turn it on below) |
| Start Paperclip now? | **No** (the service does that) |

**Expected error at the end:** `Could not create bootstrap invite: Failed query: ... instance_user_roles`. The database tables don't exist until the server has started once. Ignore it; you generate the invite after the service is running (below).

Then, before starting the service (strict secrets mode is the one setting onboarding leaves off):

```bash
sudo ./bootstrap.sh paperclip configure --section secrets   # turn ON "Require secret refs for sensitive env vars"
sudo ./bootstrap.sh paperclip doctor                        # expect: authenticated/private, PostgreSQL connection successful
sudo ./bootstrap.sh service                                 # its JSON says "lingerEnabled": false; harmless (see gotchas)
sudo ./bootstrap.sh paperclip auth bootstrap-ceo --expires-hours 1   # prints a one-time admin invite URL
```

Open the invite URL, but **replace its host with your real hostname** (the URL is generated from the bind address). Create the admin account. Strict secrets mode makes Paperclip reject plain-text values for keys like `ANTHROPIC_API_KEY`: they must be stored as secrets, so the key doesn't sit in an agent's config in the clear.

The first agent's key comes from the post-signup wizard. Use a **dedicated key from a dedicated Anthropic workspace with its own monthly limit** (keys can't be moved between workspaces, and the default workspace can't have its own limit). Type it into the UI; never paste it into a chat, a script or a shell command.

### Tasks and agents: how Paperclip actually works

- Agents are not long-running processes. On each **heartbeat** (assignment, mention, manual trigger, or a timer you enable), Paperclip runs the CLI headless (`claude --print`, up to `maxTurnsPerRun`) and it exits. The session is saved and resumed next time if the working directory matches.
- **Assigning a task is the wake trigger.** An unassigned ticket wakes nobody. Timer heartbeats are off by default; keep them off until you've measured costs.
- `claude_local` defaults to `dangerouslySkipPermissions: true`, because a headless run can't answer a permission prompt (with `false`, tools that need permission simply don't run). That is acceptable *here, and only here*: the VM is the permission boundary and the agents run as a non-root user. **Don't do this on a machine that isn't a disposable VM.**
- The Anthropic CLI refuses full bypass as root, which is one more reason `agents` is a normal user.

## Day-two operations

```bash
sudo ./bootstrap.sh snapshot before-experiment    # snapshot (VM briefly stopped); roll back instead of repairing
sudo incus snapshot restore <vm> <name>
sudo ./bootstrap.sh shell                         # root shell in the VM, over vsock
sudo ./bootstrap.sh paperclip <anything>          # run the paperclipai CLI as the agents user
sudo ./bootstrap.sh audit                         # re-check the VM's posture
```

- **Logs:** `journalctl --user -u paperclipai` as the `agents` user. **Status:** `systemctl --user status paperclipai`.
- **Reboots:** the VM autostarts; lingering brings the Paperclip service up with nobody logged in. Test this once (`incus restart`, then load the UI).
- **Upgrading Paperclip:** snapshot, change `PAPERCLIP_VERSION`, `sudo ./bootstrap.sh vm 60`, restart the service. Read the release notes; canary builds are published daily, so stay on stable. `paperclipai update` does not work with this install method (see gotchas).
- **Upgrading Node:** `nvm install`, then re-run `vm 60` (the launcher hardcodes Node's path).
- **Docker packages** come from Docker's repo and are *not* covered by unattended-upgrades: `apt upgrade` them yourself now and then. Claude Code auto-updates by itself; that is the one deliberate exception to the "pin everything" rule.
- **Growing the pool:** `sudo incus storage set default size=<bigger>` (live; cannot shrink).

## Giving agents somewhere to put their work

Everything in the VM is readable by every agent, so give them narrow, revocable, non-personal credentials:

- **Code → GitHub, through a separate bot account** (GitHub's terms allow one free machine user per person). Make it a collaborator on **only** the agent repos. Use a **fine-grained token** limited to those repos (Contents and Pull requests: read/write) with an expiry date. Turn on **branch protection on `main`** requiring your review: agents push branches and open PRs but can't merge.
- **Other files → Google Drive, through a bot Google account** that owns an `Agent Output` folder shared with your personal account; agents upload with `rclone` logged in as the bot (one-time OAuth, done in a browser on your workstation via `rclone authorize`). Not a service account: on personal (non-Workspace) Google, service accounts have no storage quota and uploads fail with `storageQuotaExceeded`.
- Never put your own accounts, SSH keys or API keys in the VM.

## Cost notes

Measured on my instance (Claude Code agent, default model, `claude_local`):

| Task | Cost | Time |
|---|---|---|
| "Write a haiku to a file" | **$0.18** | 24 s |

Most of that is fixed per-run overhead (Claude Code's system prompt, Paperclip's instructions and skills, tool definitions): roughly **$0.10-0.15 per run** before any real work. So a $5-10/month agent budget buys on the order of 30-50 tiny runs. Practical consequences: prefer fewer, larger tickets; use a cheaper model for the agent that does most of the work; set per-agent budgets *and* a company cap; leave timer heartbeats off; measure cost per ticket on a handful of small tickets before moving a real project over.

## How I run it

This is the instance the scripts were distilled from.

- **Hardware:** a Beelink SER5 mini PC (Ryzen 5 5560U, 6 cores/12 threads, ~58 GB RAM, 477 GB NVMe), headless, BIOS set to power on after AC loss (plug-pull tested).
- **Host:** Ubuntu Server 26.04 LTS, key-only SSH, Tailscale (key expiry disabled), ufw default-deny, unattended security upgrades, NTP. Nothing but the hypervisor runs on it. It is deliberately separate from my media server, which is not reachable from the agent VM.
- **VM:** the whole machine minus headroom: 12 vCPU (not pinned), 48 GiB RAM (the host keeps ~10 GiB for QEMU overhead, Incus and page cache, plus 8 GiB swap), a 200 GiB root disk, on a 380 GiB btrfs pool (the rest is snapshot space). Ubuntu 26.04 cloud image.
- **Access:** the UI at `https://<host>.<tailnet>.ts.net` via `tailscale serve`; SSH from my Mac with `ssh -J`, key-only, no agent forwarding.
- **Why so big:** the plan is at least three agents (a planner on a strong model that wakes rarely, an engineer on a cheaper model that does most of the work, and a reviewer on a *different* model that gates merges), all managed from the Mac, and agents that run `docker compose` stacks.
- **Verified by hand**, in this order: firewall rules and VM networking; the egress block (internet reachable, router/media server/host SSH/tailnet not); SSH hardening; rootless Docker (including that the VM firewall blocks a published test port); nvm/Node; Paperclip `test-drive` with a throwaway task; the real install; and a reboot test with nobody logged in. Snapshots were taken at each milestone.

## Testing status

- ✅ **Design and manual steps:** verified on real hardware as described above.
- 🔄 **Generalized scripts:** refactored from those manual steps (parameterized, made idempotent, nested provisioning added). They pass `bash -n` and the generated nested scripts were rendered and syntax-checked, but the full `./bootstrap.sh host && ./bootstrap.sh vm` run on a clean VM is still being exercised. Expect to hit a rough edge; please open an issue with the output if you do.
- Developed against Ubuntu 26.04, Incus 6.0.5, Paperclip `2026.916.1`, Node 24.21, npm 11.19, Docker 29.x.

## Repo layout

```
bootstrap.sh              the one command you run (host, vm, onboard, service, expose, verify, ...)
config.example.env        every setting and its default; copy the ones you change into config.env
lib/config.sh             loads defaults + config.env (host side)
lib/vm-lib.sh             helpers prepended to every VM script (as_agents, wait_user_session)
host/                     10-incus, 20-firewall, 30-vm, 40-tailscale-serve
vm/                       10-ssh-and-firewall … 70-service, run inside the VM
verify/                   egress-check, vm-audit
docs/gotchas.md           every trap I hit, with symptom, cause and fix
```

## License

MIT, see [LICENSE](LICENSE). Paperclip is a separate MIT-licensed project; this repo is not affiliated with it.
