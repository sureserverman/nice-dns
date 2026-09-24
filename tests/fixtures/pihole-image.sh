# shellcheck shell=bash
# Candidate Pi-hole images for integration groups (sub-plan 02, Task 2.3).
# Sourced; the runner provides fail and CASE_DIR. Bash 3.2 compatible.
#
#   ph_image standard|hardened   build (or reuse) the candidate image and set
#                                PH_IMG. Tags are content hashes of the build
#                                inputs, so an unchanged recipe is built once.
#
#   localhost/nd-test-pihole:<hash>                  standard (nice-dns pihole/)
#   localhost/nd-test-pi-hole-hardened-base:<hash>   sibling pi-hole-hardened
#   localhost/nd-test-pihole-hardened:<hash>         nice-dns pihole-hardened/
#
# Builds are the declared bootstrap exception (PRIV-BOOTSTRAP-DECLARED): the
# base image pull, apk upgrade and gravity download use the builder's
# network, exactly as the installers do. No --dns override is passed, so
# build-time lookups use the host's resolver. The resulting containers run
# with no network at all.

PH_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"

ph_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# ph_hash <dir> <path...>: content hash of the named files and trees.
ph_hash() {
  local d="$1" f
  shift
  (cd "$d" && find "$@" -type f 2>/dev/null | LC_ALL=C sort) | while IFS= read -r f; do
    printf '%s\n' "$f"; ph_sha <"$d/$f"
  done | ph_sha
}

ph_image() {
  local h bh base
  case "$1" in
    standard)
      h="$(ph_hash "$NICE_DNS_ROOT" pihole)"
      PH_IMG="localhost/nd-test-pihole:$(printf '%s' "$h" | cut -c1-16)"
      if ! podman image exists "$PH_IMG" 2>/dev/null; then
        podman build -t "$PH_IMG" "$NICE_DNS_ROOT/pihole" >"$CASE_DIR/build-pihole.log" 2>&1 \
          || fail "standard Pi-hole build failed: $(tail -n 15 "$CASE_DIR/build-pihole.log")"
      fi ;;
    hardened)
      [ -f "$PH_SIBS/pi-hole-hardened/Dockerfile" ] || fail "pi-hole-hardened sibling checkout not found at $PH_SIBS/pi-hole-hardened"
      bh="$( { git -C "$PH_SIBS/pi-hole-hardened" ls-files -co --exclude-standard | LC_ALL=C sort | while IFS= read -r f; do
               printf '%s\n' "$f"; ph_sha <"$PH_SIBS/pi-hole-hardened/$f"; done; } | ph_sha)"
      base="localhost/nd-test-pi-hole-hardened-base:$(printf '%s' "$bh" | cut -c1-16)"
      if ! podman image exists "$base" 2>/dev/null; then
        podman build -t "$base" "$PH_SIBS/pi-hole-hardened" >"$CASE_DIR/build-pihole-base.log" 2>&1 \
          || fail "pi-hole-hardened base build failed: $(tail -n 15 "$CASE_DIR/build-pihole-base.log")"
      fi
      h="$( { printf '%s\n' "$bh"; ph_hash "$NICE_DNS_ROOT" pihole pihole-hardened; } | ph_sha)"
      PH_IMG="localhost/nd-test-pihole-hardened:$(printf '%s' "$h" | cut -c1-16)"
      if ! podman image exists "$PH_IMG" 2>/dev/null; then
        podman build --build-arg "BASE_IMAGE=$base" -t "$PH_IMG" -f "$NICE_DNS_ROOT/pihole-hardened/Containerfile" "$NICE_DNS_ROOT" \
          >"$CASE_DIR/build-pihole-hardened.log" 2>&1 \
          || fail "hardened Pi-hole build failed: $(tail -n 15 "$CASE_DIR/build-pihole-hardened.log")"
      fi ;;
    *) fail "ph_image: unknown Pi-hole variant '$1'" ;;
  esac
  printf 'pihole\t%s\t%s\n' "$1" "$PH_IMG" >>"$CASE_DIR/pihole-images.tsv"
}
