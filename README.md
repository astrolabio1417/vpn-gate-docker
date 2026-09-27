# vpn-gate-docker

A Docker container that connects to a [VPN Gate](https://www.vpngate.net/)
volunteer relay and exposes the tunnel as a SOCKS5 + HTTP proxy on one port.
No account, no credentials, no configuration required. Image size is 29.2 MB
(Alpine 3.21, OpenVPN 2.6.20, gost 2.12.0).

VPN Gate's public API lists roughly 100 volunteer-run servers. The container
downloads that list, ranks servers by the service's own Score field, and
claims exactly one relay for its lifetime — see "Running several containers"
below for what that means when you run more than one of these. A cold start
takes about 20 seconds.

## Quick start

```bash
docker compose up -d
```

Wait about 20 seconds for the tunnel to come up, then use the proxy:

```bash
curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

Always use `--socks5-hostname`, not `--socks5`. The hostname form resolves
DNS at the proxy, inside the tunnel. The plain `--socks5` form resolves
locally first and leaks your lookups to your own resolver.

### Plain `docker run`

If you are not using `docker compose`, you MUST pass `--dns 1.1.1.1`
yourself:

```bash
docker run -d --name vpn-gate \
    --restart unless-stopped \
    --cap-add NET_ADMIN --device /dev/net/tun \
    --dns 1.1.1.1 \
    -p 127.0.0.1:1080:1080 \
    vpn-gate-docker
```

`--restart unless-stopped` is MANDATORY, not just recommended. The config
carries exactly one relay (see "What happens when a relay fails" below), so
openvpn has no second remote to fall back to, and any relay failure exits the
container outright. Without a restart policy the container just stays dead;
with one, it retries with a freshly fetched server list and a fresh relay
claim. `docker-compose.yml` uses `restart: always` for the same reason,
though the two policies differ after a manual `docker stop` or a daemon
restart.

Without `--dns 1.1.1.1` the proxy returns nothing at all. Once the VPN
server pushes its route, the container's default resolver is no longer
reachable, so every DNS lookup through the proxy fails, even though the
tunnel itself looks healthy. `docker-compose.yml` already sets this; a bare
`docker run` does not.

## Requirements

- `--cap-add NET_ADMIN`
- `--device /dev/net/tun`

Both are needed to create and route through the VPN tunnel interface. No
other capabilities are required.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `COUNTRY` | *(unset)* | Comma-separated ISO-2 codes, e.g. `JP,US` or `JP, US` — spaces are tolerated. Unset means best available. |
| `MAX_SERVERS` | `32` | How far down the score-ranked list a container may walk looking for a relay it can claim. MUST exceed your container count with real margin — N containers racing for relays need at least N candidates within this window, or the extras exit with nothing left to try even though claimable relays exist further down VPN Gate's real list. |
| `CLAIM_DIR` | `/var/lib/vpn-gate/claims` | Directory that arbitrates which container owns which relay (see "Running several containers"). Container-local by default, so even a single container gets tombstone protection against re-claiming a relay it just watched die. MUST be a local filesystem — `mkdir` atomicity and mtime ordering, which the whole scheme depends on, are not guaranteed on NFS or CIFS. |
| `CLAIM_TTL` | `300` | Seconds since a claim's last heartbeat before another container may steal it. Should comfortably exceed `CHECK_INTERVAL` (entrypoint heartbeats every second while waiting for the tunnel, then once per `CHECK_INTERVAL` tick after); entrypoint warns at startup if `CHECK_INTERVAL + 15` does not leave enough room, since undershooting lets a sibling judge a live container's claim stale. |
| `TOMBSTONE_TTL` | `900` | Seconds a relay stays excluded after entrypoint tombstones it for a failure, before another container may retry it. Automatic and expiring — see how this differs from `BLOCKED_IPS` below. |
| `BLOCKED_IPS` | *(unset)* | Comma-separated relay entry IPs (field 2 of the VPN Gate list) to keep out of the pool permanently. A token ending in `.` blocks a subnet prefix instead of one address, e.g. `219.100.37.` for the whole `public-vpn-*` farm. Operator-set, and survives restarts. A relay that keeps reappearing as a tombstone belongs here instead of waiting out `TOMBSTONE_TTL` forever. |
| `BLOCKED_EXIT_IPS` | *(unset)* | Comma-separated exit IPs to reject after connecting, once the real exit IP is known. See below for how this differs from `BLOCKED_IPS`. |
| `CHECK_INTERVAL` | `30` | Seconds between watchdog health checks. |
| `CHECK_URL` | `https://api.ipify.org` | URL the watchdog probes through the proxy. |
| `PROXY_PORT` | `1080` | Port gost listens on, inside the container only. The published port is hardcoded in `docker-compose.yml`; changing `PROXY_PORT` alone yields connection-refused on the old port while the healthcheck still passes. |

`BLOCKED_IPS` matches on the entry IP VPN Gate publishes, not the exit
address a target sees — most relays are 1:1, but VPN Gate's `public-vpn-*`
farm NATs roughly a dozen relays out through a handful of shared exit IPs
in `219.100.37.0/24`, none of which appear in the CSV as an entry IP. Banning
the exit IP a target names blocks nothing. Block the farm's entry-IP prefix
instead, e.g. `BLOCKED_IPS=219.100.37.`.

`BLOCKED_EXIT_IPS` is the other half: it filters *after* the tunnel is up,
by the address `CHECK_URL` reports back through it, rather than *before*
dialing. Use it for an exit IP you cannot pre-filter by entry IP — for
example a shared NAT exit whose entry IPs you have not enumerated yet. A
match runs the same `give_up` path as any other failed relay: the proxy
never starts, and the relay is tombstoned, so the restart claims a
different one. That tombstone expires after `TOMBSTONE_TTL`, so this alone
is relief, not a permanent ban — the same relay can be claimed again once it
expires. Entrypoint logs the entry IP that produced the blocked exit
(`exit IP ... via entry ...`); put that entry IP in `BLOCKED_IPS` for a
permanent ban. The comparison is a whole-line exact match, so `CHECK_URL`
MUST return a bare IP and nothing else — a URL like `https://ipinfo.io/json`
that answers `{"ip":"1.2.3.4"}` will never match. With `BLOCKED_EXIT_IPS`
set, a container that cannot determine its exit IP after retrying refuses to
serve and restarts, rather than serving an unverified exit.

Example with a country filter:

```bash
COUNTRY=JP docker compose up -d
```

## What happens when a relay fails

There is no in-process failover: the config carries exactly one `remote`, so
if it dies, openvpn has nothing to fall back to on its own. Every failure —
the initial connect never completing, openvpn exiting once its own
`connect-retry-max 3` is exhausted, or the watchdog's three consecutive
failed proxy checks — makes the container exit non-zero. A restart policy is
therefore MANDATORY (see "Plain `docker run`" above), not just recommended:
without one, a single dead relay leaves the container permanently down.

A restart is not just a process restart. It fetches a fresh server list and
makes a fresh claim (see "Running several containers" below), and the relay
that just failed is tombstoned first, so the same container does not
immediately re-claim the relay that just killed it.

The watchdog is the backstop for the case openvpn cannot see for itself: the
tunnel stays up and authenticated while traffic quietly goes nowhere. Three
consecutive failed checks are treated the same as openvpn exiting outright —
both end in the container exiting so a fresh claim gets made.

## Running several containers

Each container claims exactly one relay, by score, through `CLAIM_DIR`. On a
single host, N containers sharing ONE bind-mounted `CLAIM_DIR` get distinct
relays via `mkdir`, which is atomic: two containers racing for the same IP,
including two racing to steal the same stale claim, cannot both win it —
`mkdir` (never deletion) is the only thing that ever decides ownership. That
holds even under concurrent contention, not just on a cold, empty `CLAIM_DIR`.

The one condition this does not cover: `CLAIM_TTL` set too low relative to
how long this container actually takes to heartbeat (see `CLAIM_TTL` above)
can still let a live container's claim be judged stale and stolen out from
under it. When that happens, an ownership token written at claim time is
what bounds the damage — the original container checks the on-disk token
before it ever releases, tombstones, or heartbeats a claim, and does nothing
further the moment it no longer matches, rather than destroying the new
owner's live claim.

Omitting the shared mount does not fail loudly. Each container silently gets
its own private, container-local `CLAIM_DIR`, and every container claims the
same top-scored relay — exactly as if there were no coordination at all. This
is the one part of "fail loudly" that cannot be a hard error, because a
single container's `CLAIM_DIR` is deliberately container-local too, and that
default must keep working. The one signal you get is the `NOTE ... is not a
mount point` line in `docker logs`, once per container start — it only
checks that container's own `CLAIM_DIR` against `/proc/self/mountinfo`, it
does not compare against any other container, so seeing it on even one
container tells you that one has a private path.

`CLAIM_DIR` MUST be a local filesystem. The `mkdir` atomicity and mtime
ordering this whole scheme depends on are not guaranteed on NFS or CIFS.

Each container still needs its own `--cap-add NET_ADMIN` and
`--device /dev/net/tun`; the tunnel device is per-container, not shared.

`docker compose up --scale` does NOT work for this: `docker-compose.yml`
sets `container_name: vpn-gate` and publishes a fixed `127.0.0.1:1080:1080`,
both of which are per-container and refuse to scale — Compose rejects the
scale outright because of `container_name`, and even past that, containers
2..6 would fail to start with "port is already allocated". Those compose
settings stay as they are: single-container compose is the documented
default and must keep working. Use one of the two shapes below instead.

dokku:

```bash
dokku storage:mount <app> /var/lib/vpn-gate-claims:/var/lib/vpn-gate/claims
dokku docker-options:add <app> deploy "--cap-add NET_ADMIN --device /dev/net/tun --dns 1.1.1.1"
dokku ps:scale <app> web=6
```

`storage:mount` is what makes the 6 processes coordinate at all — without it
every one gets a private claim directory and all 6 dial the same top relay.
`docker-options:add` is required too: each process needs its own `NET_ADMIN`
and `/dev/net/tun`, and dokku does not grant either by default.

Plain `docker run`, looped, sharing one claim directory on the host and one
published port per container:

```bash
mkdir -p /var/lib/vpn-gate-claims
for i in 1 2 3 4 5 6; do
    docker run -d --name "vpn-gate-$i" \
        --restart unless-stopped \
        --cap-add NET_ADMIN --device /dev/net/tun \
        --dns 1.1.1.1 \
        -v /var/lib/vpn-gate-claims:/var/lib/vpn-gate/claims \
        -p "127.0.0.1:108$i:1080" \
        vpn-gate-docker
done
```

## Security

**Exposure.** The default binding, in `docker-compose.yml`, is
`127.0.0.1:1080` — reachable only from the host. Widening this to `0.0.0.0`
without authentication turns the container into an open relay: anyone who
can reach the host on port 1080 can proxy through your VPN Gate exit. If you
need to expose it, add authentication instead:

```bash
gost -L socks5://user:pass@:1080
```

**This is not anonymity.** VPN Gate relays are run by anonymous volunteers
who can observe your exit traffic. This container changes which network
your traffic appears to come from. It does not hide that traffic from the
relay operator.

**Tunnel death is a bounded leak window, not a guarantee.** If the tunnel
dies unexpectedly, traffic CAN exit unencrypted over the host's normal
network path for up to `CHECK_INTERVAL` seconds, until the watchdog notices.
On every failure path — there is no other kind now that the config carries a
single relay — the proxy is stopped before the container exits, so once the
watchdog acts, connections are refused rather than sent outside the tunnel.
Anyone who needs a hard guarantee instead of a bounded window MUST add a
firewall kill-switch; this container does not provide one.

## Testing

End-to-end (builds the image, starts a real container, makes a real VPN
Gate connection, takes a few minutes):

```bash
./test.sh
```

VPN Gate's pool is volunteer-run: individual servers frequently reject
connections or are simply dead. `test.sh` makes one attempt per run with no
retry, so a failed run does not mean the build is broken — retry it before
concluding anything is wrong.

Offline unit tests for the config generator (no network, no privileges):

```bash
./test/test-generate-config.sh
```
