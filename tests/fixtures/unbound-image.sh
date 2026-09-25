# shellcheck shell=bash
# Candidate Unbound images for integration groups (sub-plan 02). Sourced;
# the runner provides fail and CASE_DIR. Bash 3.2 compatible.
#
#   ub_images   build (or reuse) the hardened-unbound base from the sibling
#               checkout and nice-dns/unbound FROM it; sets UB_BASE_IMG,
#               UB_IMG. Tags are content hashes of the build inputs, so an
#               unchanged tree is built once and reused by every group.
#
#   localhost/nd-test-hardened-unbound:<hash>   candidate base
#   localhost/nd-test-unbound:<hash>            candidate product image

UB_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"
UB_BASE_SRC="$UB_SIBS/hardened-unbound"
UB_PRODUCT_SRC="$NICE_DNS_ROOT/unbound"

ub_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# ub_tree_hash <dir> <file...>: content hash of the named files (paths and bytes).
ub_tree_hash() {
  local d="$1" f
  shift
  for f in "$@"; do
    printf '%s\n' "$f"
    if [ -f "$d/$f" ]; then ub_sha <"$d/$f"; else printf 'absent\n'; fi
  done | ub_sha
}

ub_images() {
  local bh ph files
  [ -f "$UB_BASE_SRC/Dockerfile" ] || fail "hardened-unbound sibling checkout not found at $UB_BASE_SRC"
  bh="$(ub_tree_hash "$UB_BASE_SRC" Dockerfile post-install.sh)"
  files="$(cd "$UB_PRODUCT_SRC" && find . -type f | LC_ALL=C sort)"
  # shellcheck disable=SC2086
  ph="$( { printf '%s\n' "$bh"; ub_tree_hash "$UB_PRODUCT_SRC" $files; } | ub_sha)"
  UB_BASE_IMG="localhost/nd-test-hardened-unbound:$(printf '%s' "$bh" | cut -c1-16)"
  UB_IMG="localhost/nd-test-unbound:$(printf '%s' "$ph" | cut -c1-16)"
  if ! podman image exists "$UB_BASE_IMG" 2>/dev/null; then
    podman build -t "$UB_BASE_IMG" "$UB_BASE_SRC" >"$CASE_DIR/build-base.log" 2>&1 \
      || fail "base image build failed: $(tail -n 15 "$CASE_DIR/build-base.log")"
  fi
  if ! podman image exists "$UB_IMG" 2>/dev/null; then
    podman build --build-arg "BASE_IMAGE=$UB_BASE_IMG" -t "$UB_IMG" "$UB_PRODUCT_SRC" \
      >"$CASE_DIR/build-product.log" 2>&1 \
      || fail "product image build failed: $(tail -n 15 "$CASE_DIR/build-product.log")"
  fi
  printf 'images\t%s\t%s\n' "$UB_BASE_IMG" "$UB_IMG" >"$CASE_DIR/unbound-images.tsv"
}
