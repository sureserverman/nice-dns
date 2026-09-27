# Release inputs

Every image a nice-dns install pulls or builds on is pinned in
`release/images.lock`. The installers never float to whatever a tag points at
today. The lock records, for each input:

- the repository, the tag it was taken from, and its multi-platform index digest;
- the platforms that digest provides;
- the source repository and commit (or `upstream`) and the version;
- the signer identity cosign must see, or `none`.

It also lists the interfaces each proxy image provides and the ones this tree
requires. It is data, parsed by `lib/install.sh` and
`scripts/update-images-lock.sh`, never sourced.

## What an install checks, before it interrupts anything

1. The lock parses: schema line, known row kinds, `sha256:` digests.
2. This host's platform is in the lock's `supported` set, and every image the
   install uses has a build for it.
3. The lock says the chosen proxy provides every interface this tree
   `requires`: fixed route listeners, the route probe and the acknowledged
   control restart. This compares the lock's own reviewed rows; it catches a
   lock pinned to an image that was never qualified for this tree. What the
   pulled image actually does is proven later, before the resolver is pinned:
   the readiness wait needs Unbound to resolve over a route (the route
   listeners and probe), and the controller's self-check must pass.
4. With cosign installed, each signed image's signature is checked on its
   locked digest against the lock's signer and issuer. Without cosign the
   install says the signatures were not verified and records that; set
   `ND_INST_REQUIRE_SIGNATURES=1` to refuse instead. An upstream input
   nice-dns cannot name a signer for (`pihole/pihole`) is recorded as
   `unsigned`: no check is invented for it.

Each generation's manifest records the lock's sha256, every locked reference,
each signature result, the gravity sources (`pihole/adlists-default.txt`,
`pihole/custom-allowlist.txt`; the lists they name are downloaded at build
time, so their contents are not pinned) and, for the hardened flavour, the
sibling `pi-hole-hardened` commit and the local id of the base its Dockerfile
names. The hardened base is not published, so a hardened
install needs that sibling checkout next to nice-dns.

The previous generation's images stay on the host (lib/install.sh prunes only
older ones), so a failed install rolls back to what ran before.

## Updating the lock

Run this on a maintainer machine with curl, podman, python3 and cosign:

```sh
scripts/update-images-lock.sh            # report: exit 0 current, 1 drift, 2 error
scripts/update-images-lock.sh --write    # record new digests and platforms
```

For each image the script:

- reads the current digest of `<repository>:<tag>` from Docker Hub;
- requires every `supported` platform;
- verifies each signed image's signature on the new digest.

It refuses to write if any of that fails. Only the moved rows change.

Then:

1. Set each moved row's `source` commit and `version` by hand, or move its
   `tag` to the new release first.
2. Requalify the new images: the transport and controller test groups, and a
   live install on each platform (`tests/run.sh plan installers`).
3. Update any `provides` row the new image changes.
4. Review the diff and commit it on its own, citing the qualification.

Refresh at least with every sibling image release, and whenever an upstream
base carries a security fix. Pinning must not freeze a vulnerable input
(ARCH-05).
