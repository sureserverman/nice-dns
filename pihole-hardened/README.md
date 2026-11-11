# pihole-hardened (downstream extension)

Side-by-side alternative to `nice-dns/pihole/`. Same runtime contract — same
container name (`pi-hole`), same image name (`localhost/pi-hole:latest`),
same quadlets, same DNS pinning — but the **base image** is the hardened
pi-hole-hardened build, made from the inputs in [`base/`](base/) (copied from
the pi-hole-hardened project at the commit `base/UPSTREAM` names), instead of
upstream `pihole/pihole:latest`.

## Why

- **`linux/riscv64` support** — upstream doesn't publish riscv64; this base does.
- **Smaller surface** — the hardened base is ~109 MB vs. ~700 MB upstream.
- **Non-root by default** — `pihole-FTL` runs as uid 1000 with file-cap
  `cap_net_bind_service=+ep` instead of as root.
- **iron-alpine carve-outs** — same hardening pattern as `tor-haproxy`,
  `tor-socat`, `hardened-unbound` siblings.

## How to use

Run the parallel installer instead of `install-deb.sh` / `install-mac.sh`:

```sh
# Linux quadlet stack
./install-deb-hardened.sh haproxy

# macOS Apple-container stack
./install-mac-hardened.sh haproxy
```

These installers:

1. Build the hardened base from `pihole-hardened/base/` in this tree, on the
   Alpine image `release/images.lock` pins (the `hardened-os` row). Nothing
   outside the tree is needed; `scripts/sync-hardened-base.sh <checkout>`
   refreshes `base/` from a reviewed pi-hole-hardened commit.
2. Build this `pihole-hardened/Containerfile` on top of that base, tagged
   as `localhost/pi-hole:latest` so the existing quadlets pick it up
   unchanged.
3. Reuse every other piece of `nice-dns` infrastructure (`unbound/`,
   `tor-{haproxy,socat}` images, `deb/` quadlets, `mac/` LaunchAgent,
   `scripts/seed-pihole.sh`, `pihole/etc/*`, `pihole/adlists-default.txt`,
   `pihole/custom-allowlist.txt`).

## Reverting

`./install-deb.sh haproxy` (or `./install-mac.sh haproxy`) on top will tear
down and rebuild against the upstream image. Both installers tear down all
named containers/images/quadlets first, so swapping is non-destructive.
