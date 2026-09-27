# shellcheck shell=bash
# lib/install.sh: shared installer preparation for the four public entrypoints
# (install-deb.sh, install-deb-hardened.sh, install-mac.sh,
# install-mac-hardened.sh). Sub-plan 4 Task 1.1; ARCH-01, ARCH-02 (install.sh),
# ARCH-03 (prepare_install), ARCH-08 ("Four drifting destructive installers").
#
# Sourced by an entrypoint after it has staged its source tree (an in-tree
# checkout, or a clone of the requested branch): it sets ND_INST_SRC (that
# tree), ND_INST_ORIGIN (checkout|clone) and, for a clone, ND_INST_CLEANUP.
# Sourcing only defines functions and constants.
#
# The install is split in two:
#   preparation   nd_install_begin, nd_install_<platform>_host_prereqs,
#                 nd_install_config_dir, nd_install_linux_prepare_images /
#                 nd_install_macos_{stage_tree,prepare_images,bridges}.
#                 Dependencies, source staging, image builds and pulls and the
#                 prepare manifest. Preparation never writes /etc/resolv.conf,
#                 runs networksetup, reloads or restarts NetworkManager,
#                 stops/removes/restarts a container, pod, network, image or
#                 stack unit, unloads a launchd agent or runs `podman system
#                 migrate`. A failure here exits non-zero and leaves the
#                 running deployment as it was.
#   interruption  nd_install_<platform>_teardown and everything after it, which
#                 the entrypoint runs only once preparation succeeded. The
#                 macOS local builds belong here (see nd_install_macos_build_images).
#
# Generations: each install gets an id YYYYMMDDTHHMMSSZ-<12 hex of the source
# commit, or nogit0000000> and an owned manifest
#   <state>/generations/<gen>/prepare.tsv      (0600, dir 0700)
# state = ${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns-install (Linux) or
#         $HOME/Library/Application Support/nice-dns-install (macOS).
# Images carry a generation tag; :latest is re-pointed at activation. A fully
# successful install writes generations/<gen>/activated and `current`; the
# next install reads `current` as its previous generation, and only images of
# generations older than that previous one are pruned.
#
# Portability: Bash 3.2 (macOS /bin/bash): no associative arrays, ${v,,},
# mapfile or declare -g. State files are data: read with awk/read and checked
# against a strict format, never sourced or evaluated.

ND_INST_SCHEMA='nice-dns-install-prepare/1'
# One build policy per platform, shared by the standard and hardened
# entrypoints (the flags are explained where the builds run).
ND_INST_LINUX_BUILD_FLAGS=(--pull=newer --no-cache --dns 1.1.1.1)
# macOS builds run in the interruption window, while host DNS stays pinned to
# the stopped stack, so their bases are pulled in preparation and the builds
# take no --pull (see nd_install_macos_prepare_images).
ND_INST_MACOS_BUILD_FLAGS=(--no-cache --dns 1.1.1.1)
ND_INST_GEN_RE='^[0-9]{8}T[0-9]{6}Z-([0-9a-f]{12}|nogit0000000)$'
ND_INST_TAB="$(printf '\t')"
ND_INST_NL='
'

_nd_inst_err() { printf 'nice-dns install: %s\n' "$*" >&2; }

# ─────────────────────────── generation ids and manifests (pure) ─────────────

# nd_install_generation_id <commit|unknown> [YYYYMMDDTHHMMSSZ]: prints the id.
nd_install_generation_id() {
  local c="${1:-}" t="${2:-}" h
  [ -n "$t" ] || t="$(date -u +%Y%m%dT%H%M%SZ)"
  case "$t" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
    *) _nd_inst_err "malformed timestamp '$t'"; return 1 ;;
  esac
  if [ "$c" = unknown ]; then
    h=nogit0000000
  else
    case "$c" in ''|*[!0-9a-f]*) _nd_inst_err "malformed source commit '$c'"; return 1 ;; esac
    [ "${#c}" -ge 12 ] || { _nd_inst_err "source commit '$c' is too short"; return 1; }
    h="${c:0:12}"
  fi
  printf '%s-%s\n' "$t" "$h"
}

# nd_install_valid_generation <id>: 0 when <id> has the generation id format.
nd_install_valid_generation() {
  local re="$ND_INST_GEN_RE"
  [[ "${1:-}" =~ $re ]]
}

# _nd_inst_manifest_init <file>: a new manifest holding only the schema line.
_nd_inst_manifest_init() {
  local f="$1"
  if [ -L "$f" ] || [ -L "$f.tmp" ]; then _nd_inst_err "refusing symlink $f"; return 1; fi
  ( umask 077 && printf 'schema\t%s\n' "$ND_INST_SCHEMA" >"$f.tmp" ) || return 1
  chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"
}

# _nd_inst_manifest_row <file> <key> <value>...: appends one tab-separated row.
# Values must be non-empty and free of tabs and newlines.
_nd_inst_manifest_row() {
  local f="$1" k="$2" v line
  shift 2
  case "$k" in ''|*[!a-z_-]*) _nd_inst_err "bad manifest key '$k'"; return 1 ;; esac
  line="$k"
  for v in "$@"; do
    case "$v" in ''|*"$ND_INST_TAB"*|*"$ND_INST_NL"*) _nd_inst_err "bad manifest value for $k"; return 1 ;; esac
    line="$line$ND_INST_TAB$v"
  done
  if [ -L "$f" ] || [ ! -f "$f" ]; then _nd_inst_err "manifest $f is missing or a symlink"; return 1; fi
  printf '%s\n' "$line" >>"$f"
}

# _nd_inst_manifest_check <file>: 0 when <file> is a regular manifest of this schema.
_nd_inst_manifest_check() {
  local f="$1" first=""
  if [ -L "$f" ] || [ ! -f "$f" ]; then _nd_inst_err "no manifest at $f"; return 1; fi
  IFS= read -r first <"$f" || true
  [ "$first" = "schema$ND_INST_TAB$ND_INST_SCHEMA" ] || { _nd_inst_err "$f is not a $ND_INST_SCHEMA manifest"; return 1; }
}

# nd_install_manifest_get <file> <key>: the first value of the first <key> row.
nd_install_manifest_get() {
  _nd_inst_manifest_check "$1" || return 1
  awk -F '\t' -v k="$2" 'NR > 1 && $1 == k { print $2; exit }' "$1"
}

# nd_install_manifest_images <file>: one "role<TAB>ref<TAB>id" line per image row.
nd_install_manifest_images() {
  _nd_inst_manifest_check "$1" || return 1
  awk -F '\t' 'NR > 1 && $1 == "image" && NF >= 4 { print $2 "\t" $3 "\t" $4 }' "$1"
}

# nd_install_read_current <state dir>: prints the activated generation named by
# <state>/current, nothing when there is none. A malformed file is refused.
nd_install_read_current() {
  local sd="$1" f="$1/current" line="" n
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 0; fi
  if [ -L "$f" ] || [ ! -f "$f" ]; then _nd_inst_err "$f is not a regular file"; return 1; fi
  n="$(awk 'END { print NR }' "$f")"
  [ "$n" -le 1 ] || { _nd_inst_err "$f is malformed"; return 1; }
  IFS= read -r line <"$f" || true
  nd_install_valid_generation "$line" || { _nd_inst_err "$f is malformed; refusing to guess the installed generation"; return 1; }
  [ -f "$sd/generations/$line/prepare.tsv" ] || { _nd_inst_err "$f names $line, which has no manifest"; return 1; }
  printf '%s\n' "$line"
}

# _nd_inst_write_file <path> <line>: replaces <path> atomically, mode 0600.
_nd_inst_write_file() {
  if [ -L "$1" ] || [ -L "$1.tmp" ]; then _nd_inst_err "refusing symlink $1"; return 1; fi
  ( umask 077 && printf '%s\n' "$2" >"$1.tmp" ) || return 1
  chmod 600 "$1.tmp" && mv -f "$1.tmp" "$1"
}

# _nd_inst_owned_dir <dir>: <dir> exists, is not a symlink, is ours, mode 0700.
_nd_inst_owned_dir() {
  local d="$1"
  if [ -L "$d" ]; then _nd_inst_err "refusing $d: it is a symlink"; return 1; fi
  if [ ! -d "$d" ]; then ( umask 077 && mkdir -p "$d" ) || return 1; fi
  if [ -L "$d" ] || [ ! -d "$d" ] || [ ! -O "$d" ]; then
    _nd_inst_err "refusing $d: not a directory owned by $(id -un 2>/dev/null || echo this user) (or a symlink)"; return 1
  fi
  chmod 700 "$d"
}

# ─────────────────────────── runtime images ──────────────────────────────────

_nd_inst_image_exists() {
  case "$ND_INST_PLATFORM" in
    linux) podman image exists "$1" 2>/dev/null ;;
    macos) "${CONTAINER_BIN:-container}" image inspect "$1" >/dev/null 2>&1 ;;
  esac
}

# _nd_inst_image_id <ref>: the local image id (Linux) or index digest (macOS).
_nd_inst_image_id() {
  local id
  case "$ND_INST_PLATFORM" in
    linux) id="$(podman image inspect --format '{{.Id}}' "$1" 2>/dev/null)" || id="" ;;
    macos)
      # `container image inspect` prints JSON; the first digest is the index's.
      # The image must exist; a JSON shape without a readable digest is
      # recorded as unknown rather than failing the install.
      local js
      js="$("${CONTAINER_BIN:-container}" image inspect "$1" 2>/dev/null)" \
        || { _nd_inst_err "image $1 not found"; return 1; }
      id="$(printf '%s\n' "$js" | grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]+"' | head -n 1 \
        | sed -E 's/.*sha256:([0-9a-f]+)"$/\1/')" || id=""
      if [ -z "$id" ]; then
        _nd_inst_err "warning: no digest in the inspect output of $1; recording its id as unknown"
        echo unknown; return 0
      fi ;;
  esac
  id="${id#sha256:}"
  case "$id" in ''|*[!0-9a-f]*) _nd_inst_err "cannot read the image id of $1"; return 1 ;; esac
  printf '%s\n' "$id"
}

# _nd_inst_record_image <role> <ref>: the image row for a prepared image.
_nd_inst_record_image() {
  local id
  id="$(_nd_inst_image_id "$2")" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" image "$1" "$2" "$id"
}

_nd_inst_image_rm() {
  case "$ND_INST_PLATFORM" in
    linux) podman image rm "$@" >/dev/null 2>&1 || true ;;
    macos) "${CONTAINER_BIN:-container}" image rm "$@" >/dev/null 2>&1 || true ;;
  esac
}

# _nd_inst_rollback_status <previous gen|none>: none, available or missing.
_nd_inst_rollback_status() {
  local prev="$1" m rows ref n=0
  [ "$prev" != none ] || { echo none; return 0; }
  m="$ND_INST_STATE/generations/$prev/prepare.tsv"
  rows="$(nd_install_manifest_images "$m" 2>/dev/null)" || { echo missing; return 0; }
  while IFS="$ND_INST_TAB" read -r _ ref _; do
    [ -n "$ref" ] || continue
    n=$((n + 1))
    _nd_inst_image_exists "$ref" || { echo missing; return 0; }
  done <<EOF
$rows
EOF
  if [ "$n" -gt 0 ]; then echo available; else echo missing; fi
}

# ─────────────────────────── preparation: common ─────────────────────────────

# nd_install_state_dir: the platform's install state directory.
nd_install_state_dir() {
  case "$ND_INST_PLATFORM" in
    linux) printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns-install" ;;
    macos) printf '%s\n' "$HOME/Library/Application Support/nice-dns-install" ;;
    *) _nd_inst_err "unknown platform '$ND_INST_PLATFORM'"; return 1 ;;
  esac
}

# nd_install_begin <linux|macos> <entrypoint> <standard|hardened> <variant> <branch>:
# records the staged source, allocates the generation and writes its manifest.
nd_install_begin() {
  ND_INST_PLATFORM="$1" ND_INST_ENTRY="$2" ND_INST_PIHOLE="$3" ND_INST_VARIANT="$4" ND_INST_BRANCH="$5"
  case "$ND_INST_PLATFORM" in linux|macos) ;; *) _nd_inst_err "unknown platform '$1'"; return 1 ;; esac
  case "$ND_INST_PIHOLE" in standard|hardened) ;; *) _nd_inst_err "unknown pihole '$3'"; return 1 ;; esac
  case "$ND_INST_VARIANT" in haproxy|socat) ;; *) _nd_inst_err "unknown variant '$4'"; return 1 ;; esac
  case "${ND_INST_ORIGIN:-}" in checkout|clone) ;; *) _nd_inst_err "the source tree was not staged"; return 1 ;; esac
  [ -d "${ND_INST_SRC:-}" ] || { _nd_inst_err "no source tree at '${ND_INST_SRC:-}'"; return 1; }
  ND_INST_TREE="$ND_INST_SRC"
  ND_INST_BASE_SIBLING=""

  # Source generation: the staged tree's commit and whether it has local
  # changes to tracked files (untracked files, such as locally built
  # bridge-eval binaries, do not count).
  local c gens tries=0
  c="$(git -C "$ND_INST_SRC" rev-parse HEAD 2>/dev/null)" || c=""
  case "$c" in ''|*[!0-9a-f]*) c=unknown ;; esac
  [ "${#c}" -ge 12 ] || c=unknown
  ND_INST_COMMIT="$c"
  if [ "$c" = unknown ]; then
    ND_INST_DIRTY=unknown
  elif [ -n "$(git -C "$ND_INST_SRC" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    ND_INST_DIRTY=1
  else
    ND_INST_DIRTY=0
  fi

  ND_INST_STATE="$(nd_install_state_dir)" || return 1
  _nd_inst_owned_dir "$ND_INST_STATE" || return 1
  gens="$ND_INST_STATE/generations"
  _nd_inst_owned_dir "$gens" || return 1
  ND_INST_PREV="$(nd_install_read_current "$ND_INST_STATE")" || return 1
  [ -n "$ND_INST_PREV" ] || ND_INST_PREV=none
  while :; do
    ND_INST_GEN="$(nd_install_generation_id "$ND_INST_COMMIT")" || return 1
    if [ ! -e "$gens/$ND_INST_GEN" ] && [ ! -L "$gens/$ND_INST_GEN" ]; then break; fi
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || { _nd_inst_err "generation $ND_INST_GEN already exists"; return 1; }
    sleep 1
  done
  _nd_inst_owned_dir "$gens/$ND_INST_GEN" || return 1
  ND_INST_MANIFEST="$gens/$ND_INST_GEN/prepare.tsv"

  local rb
  rb="$(_nd_inst_rollback_status "$ND_INST_PREV")"
  _nd_inst_manifest_init "$ND_INST_MANIFEST" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" generation "$ND_INST_GEN" &&
  _nd_inst_manifest_row "$ND_INST_MANIFEST" created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" &&
  _nd_inst_manifest_row "$ND_INST_MANIFEST" platform "$ND_INST_PLATFORM" &&
  _nd_inst_manifest_row "$ND_INST_MANIFEST" entrypoint "$ND_INST_ENTRY" &&
  _nd_inst_manifest_row "$ND_INST_MANIFEST" pihole "$ND_INST_PIHOLE" &&
  _nd_inst_manifest_row "$ND_INST_MANIFEST" variant "$ND_INST_VARIANT" &&
  _nd_inst_manifest_row "$ND_INST_MANIFEST" branch "$ND_INST_BRANCH" &&
  _nd_inst_manifest_row "$ND_INST_MANIFEST" source_origin "$ND_INST_ORIGIN" &&
  _nd_inst_manifest_row "$ND_INST_MANIFEST" source_commit "$ND_INST_COMMIT" &&
  _nd_inst_manifest_row "$ND_INST_MANIFEST" source_dirty "$ND_INST_DIRTY" &&
  _nd_inst_manifest_row "$ND_INST_MANIFEST" previous "$ND_INST_PREV" || return 1
  if [ "$rb" = none ]; then
    _nd_inst_manifest_row "$ND_INST_MANIFEST" rollback none || return 1
  else
    _nd_inst_manifest_row "$ND_INST_MANIFEST" rollback "$ND_INST_PREV" "$rb" || return 1
  fi
  echo "▸ Preparing generation $ND_INST_GEN (source $ND_INST_ORIGIN, commit $ND_INST_COMMIT; previous $ND_INST_PREV, rollback $rb)"
}

# nd_install_config_dir: ~/.config/nice-dns, where bridges.env lives. Nothing
# else creates it on a fresh host, and the bridge service fails without it.
nd_install_config_dir() {
  local d="${XDG_CONFIG_HOME:-$HOME/.config}/nice-dns"
  mkdir -p "$d" && chmod 700 "$d"
}

# nd_install_finish: marks the generation activated, names it current and
# prunes generations older than the previous one. Only after a fully
# successful install.
nd_install_finish() {
  local d="$ND_INST_STATE/generations/$ND_INST_GEN"
  _nd_inst_write_file "$d/activated" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  _nd_inst_write_file "$ND_INST_STATE/current" "$ND_INST_GEN" || return 1
  _nd_inst_prune
  echo "▸ Generation $ND_INST_GEN is active (previous: $ND_INST_PREV)."
}

# _nd_inst_prune: removes the generation-tagged images of every generation
# except the current and the previous one (ARCH-08: prior generations are kept
# for rollback). The manifests stay, marked pruned.
_nd_inst_prune() {
  local d g keep="" rows ref
  for g in "$ND_INST_GEN" "$ND_INST_PREV"; do
    [ "$g" != none ] || continue
    rows="$(nd_install_manifest_images "$ND_INST_STATE/generations/$g/prepare.tsv" 2>/dev/null)" || continue
    keep="$keep$ND_INST_NL$(printf '%s\n' "$rows" | awk -F '\t' '{ print $2 }')"
  done
  for d in "$ND_INST_STATE/generations"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    g="${d##*/}"
    nd_install_valid_generation "$g" || continue
    [ "$g" != "$ND_INST_GEN" ] && [ "$g" != "$ND_INST_PREV" ] || continue
    [ ! -e "$d/pruned" ] || continue
    rows="$(nd_install_manifest_images "$d/prepare.tsv" 2>/dev/null)" || continue
    while IFS="$ND_INST_TAB" read -r _ ref _; do
      [ -n "$ref" ] || continue
      if printf '%s\n' "$keep" | grep -qxF -- "$ref"; then continue; fi
      _nd_inst_image_rm "$ref"
    done <<EOF
$rows
EOF
    _nd_inst_write_file "$d/pruned" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
  done
}

# _nd_inst_generation_refs: every image ref any recorded generation tagged or
# pulled (uninstall removes them; a base a build pulled implicitly is not
# recorded and stays).
_nd_inst_generation_refs() {
  local sd d
  sd="$(nd_install_state_dir)" || return 0
  [ -d "$sd/generations" ] && [ ! -L "$sd" ] && [ ! -L "$sd/generations" ] || return 0
  for d in "$sd/generations"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    nd_install_manifest_images "$d/prepare.tsv" 2>/dev/null | awk -F '\t' '{ print $2 }'
    _nd_inst_manifest_check "$d/prepare.tsv" 2>/dev/null \
      && awk -F '\t' 'NR > 1 && $1 == "pulled" && NF >= 3 { print $3 }' "$d/prepare.tsv"
  done
}

# ─────────────────────────── transaction (Task 1.2) ──────────────────────────
#
# Sub-plan 4 Task 1.2 (ARCH-03 activate_install/rollback_install, ARCH-06,
# WF-DNS-003). Host DNS belongs to its owner until nice-dns pins it, and only
# the DNS helpers (deb/custom-dns-deb, mac/start-container-root.sh) ever
# write it: the pin, or the state recorded before nice-dns. So:
#   1. nd_install_check_owned: before any work, refuse when another owner
#      changed the host DNS after nice-dns pinned it.
#   2. nd_install_save_previous: before any pull, keep the deployment the
#      install replaces: its :latest images under pre-<gen> tags, and a copy of
#      its owned files (quadlets or agents, helpers, controller).
#   3. preparation (Task 1.1).
#   4. nd_install_<platform>_activate: record the owned DNS state (first
#      install only), hold the controller, interrupt, bring the new stack up,
#      wait until it answers, install the controller and check it, and only
#      then pin the host resolver and verify the pin.
# A failure at any point of step 4 (including an interrupt) rolls back: the
# new stack goes, the saved files and image tags come back, the previous
# stack and the controller restart, and a first install gives back the DNS
# state it recorded. No step points the host at a public resolver: during the
# outage the host keeps its pin, so it fails closed.

# ND_INST_ROOT prefixes the root-owned paths for the fixture tests; empty on a
# host. ND_INST_READY_TRIES bounds the readiness wait (5 s apart): Tor's first
# bootstrap through obfs4 bridges takes 1-4 minutes, and more on a poor link.
ND_INST_ROOT="${ND_INST_ROOT:-}"
ND_INST_READY_TRIES="${ND_INST_READY_TRIES:-120}"
ND_INST_PROBE_NAME=cloudflare.com

# _nd_inst_dns_helper <verb>: the staged tree's DNS helper, under sudo.
_nd_inst_dns_helper() {
  case "$ND_INST_PLATFORM" in
    linux) sudo bash "$ND_INST_TREE/deb/custom-dns-deb" "$1" ;;
    macos) sudo bash "$ND_INST_TREE/mac/start-container-root.sh" "$1" ;;
  esac
}

# nd_install_check_owned: exits 3 when another owner changed the host DNS
# after nice-dns pinned it (nothing has been changed yet).
nd_install_check_owned() {
  local rc=0
  _nd_inst_dns_helper check || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) _nd_inst_err "another owner changed the host DNS after nice-dns pinned it; nothing was changed."
       _nd_inst_err "Run '$ND_INST_ENTRY uninstall' to restore the recorded state, then install again."
       exit 3 ;;
    *) _nd_inst_err "the DNS ownership check failed (exit $rc); nothing was changed."; exit 1 ;;
  esac
}

_nd_inst_dns_addr() { if [ "$ND_INST_PLATFORM" = linux ]; then echo 127.0.0.1; else echo 172.31.240.250; fi; }

# _nd_inst_latest_refs: the :latest references a deployment runs.
_nd_inst_latest_refs() {
  case "$ND_INST_PLATFORM" in
    linux) printf '%s\n' localhost/unbound:latest localhost/pi-hole:latest localhost/pi-hole-hardened-base:latest \
             docker.io/sureserver/tor-haproxy:latest docker.io/sureserver/tor-socat:latest ;;
    macos) printf '%s\n' unbound:latest pi-hole:latest pi-hole-hardened-base:latest \
             docker.io/sureserver/tor-haproxy:latest docker.io/sureserver/tor-socat:latest ;;
  esac
}

# _nd_inst_saved_ref <ref>: where <ref> is kept for this generation's rollback.
_nd_inst_saved_ref() {
  local n="${1%:latest}"
  n="${n##*/}"
  case "$ND_INST_PLATFORM" in
    linux) printf 'localhost/%s:pre-%s\n' "$n" "$ND_INST_GEN" ;;
    macos) printf '%s:pre-%s\n' "$n" "$ND_INST_GEN" ;;
  esac
}

_nd_inst_image_tag() {
  case "$ND_INST_PLATFORM" in
    linux) podman tag "$1" "$2" ;;
    macos) "${CONTAINER_BIN:-container}" image tag "$1" "$2" ;;
  esac
}

# _nd_inst_owned_paths: the files the deployment owns, one
# "kind<TAB>path<TAB>mode<TAB>user|root" line each (kind f or d).
_nd_inst_owned_paths() {
  local R="$ND_INST_ROOT" q u c f
  if [ "$ND_INST_PLATFORM" = linux ]; then
    q="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
    u="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    for f in nice-dns.network nice-dns.pod unbound.container pi-hole.container tor-haproxy.container tor-socat.container; do
      printf 'f\t%s\t644\tuser\n' "$q/$f"
    done
    for f in nice-dns-fetch-bridges.service nice-dns-health.service nice-dns-health.timer \
             nice-dns-health-bridges.service nice-dns-health-bridges.timer; do
      printf 'f\t%s\t644\tuser\n' "$u/$f"
    done
    printf 'f\t%s\t644\tuser\n' "${XDG_CONFIG_HOME:-$HOME/.config}/containers/containers.conf.d/90-nice-dns-firewall.conf"
    printf 'f\t%s\t755\tuser\n' "$HOME/.local/bin/nice-dns-fetch-bridges" "$HOME/.local/bin/nice-dns-health" \
      "${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns-health/bin/nice-dns-health"
    printf 'd\t%s\t755\tuser\n' "${XDG_DATA_HOME:-$HOME/.local/share}/nice-dns-health"
    printf 'f\t%s\t755\troot\n' "$R/usr/bin/custom-dns-deb" "$R/etc/NetworkManager/dispatcher.d/90-nice-dns-pin"
    printf 'f\t%s\t644\troot\n' "$R/etc/systemd/system/custom-dns-deb.service" "$R/etc/NetworkManager/conf.d/90-nice-dns.conf" \
      "$R/etc/sysctl.d/99-nice-dns-disable-ipv6.conf" \
      "$R/etc/systemd/system/NetworkManager-wait-online.service.d/10-wait-for-connectivity.conf"
  else
    for f in start-container health health-bridges bridge-eval; do
      printf 'f\t%s\t644\tuser\n' "$HOME/Library/LaunchAgents/org.nice-dns.$f.plist"
    done
    printf 'f\t%s\t755\tuser\n' "$HOME/.local/bin/nice-dns-health" "$HOME/Library/Logs/nice-dns-health/bin/nice-dns-health"
    printf 'd\t%s\t755\tuser\n' "$HOME/Library/Application Support/nice-dns-health"
    for f in start-container.sh start-container-root.sh nice-dns-fetch-bridges.sh nice-dns-bridge-eval.sh; do
      printf 'f\t%s\t755\troot\n' "$R/usr/local/sbin/$f"
    done
    printf 'f\t%s\t440\troot\n' "$R/etc/sudoers.d/start-container"
  fi
}

# nd_install_save_previous: keeps the deployment this install replaces, before
# any pull can move a :latest tag. Sets ND_INST_HAD_DEPLOY and ND_INST_RB.
nd_install_save_previous() {
  local ref saved kind p mode who n=0 rows
  ND_INST_RB="$ND_INST_STATE/generations/$ND_INST_GEN/rollback"
  _nd_inst_owned_dir "$ND_INST_RB" || return 1
  if [ "$ND_INST_PLATFORM" = linux ]; then
    [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/pi-hole.container" ] && ND_INST_HAD_DEPLOY=1 || ND_INST_HAD_DEPLOY=0
  else
    [ -f "$HOME/Library/LaunchAgents/org.nice-dns.start-container.plist" ] && ND_INST_HAD_DEPLOY=1 || ND_INST_HAD_DEPLOY=0
  fi
  _nd_inst_manifest_row "$ND_INST_MANIFEST" replaces "$( [ "$ND_INST_HAD_DEPLOY" = 1 ] && echo deployment || echo nothing)" || return 1
  if [ "$ND_INST_PLATFORM" = macos ] && ! command -v "${CONTAINER_BIN:-container}" >/dev/null 2>&1; then
    rows=""   # no runtime yet: nothing to keep
  else
    rows="$(_nd_inst_latest_refs)"
  fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if _nd_inst_image_exists "$ref"; then
      saved="$(_nd_inst_saved_ref "$ref")"
      _nd_inst_image_tag "$ref" "$saved" || return 1
      _nd_inst_manifest_row "$ND_INST_MANIFEST" saved "$ref" "$saved" || return 1
      _nd_inst_record_image saved "$saved" || return 1
    else
      _nd_inst_manifest_row "$ND_INST_MANIFEST" saved "$ref" absent || return 1
    fi
  done <<EOF
$rows
EOF
  : >"$ND_INST_RB/files.tsv" && chmod 600 "$ND_INST_RB/files.tsv" || return 1
  while IFS="$ND_INST_TAB" read -r kind p mode who; do
    [ -n "$kind" ] || continue
    n=$((n + 1))
    if [ "$kind" = d ]; then
      if [ -d "$p" ] && [ ! -L "$p" ]; then
        cp -Rp "$p" "$ND_INST_RB/s$n" || return 1
        printf 'd\t%s\ts%s\t%s\t%s\n' "$p" "$n" "$mode" "$who" >>"$ND_INST_RB/files.tsv"
      else
        printf 'd\t%s\tabsent\t%s\t%s\n' "$p" "$mode" "$who" >>"$ND_INST_RB/files.tsv"
      fi
    elif [ "$who" = root ]; then
      if sudo test -f "$p"; then
        # The redirect is ours on purpose: the copy lands in our 0700 state dir.
        # shellcheck disable=SC2024
        ( umask 077 && sudo cat "$p" >"$ND_INST_RB/s$n" ) || return 1
        printf 'f\t%s\ts%s\t%s\t%s\n' "$p" "$n" "$mode" "$who" >>"$ND_INST_RB/files.tsv"
      else
        printf 'f\t%s\tabsent\t%s\t%s\n' "$p" "$mode" "$who" >>"$ND_INST_RB/files.tsv"
      fi
    elif [ -f "$p" ] && [ ! -L "$p" ]; then
      cp -p "$p" "$ND_INST_RB/s$n" || return 1
      printf 'f\t%s\ts%s\t%s\t%s\n' "$p" "$n" "$mode" "$who" >>"$ND_INST_RB/files.tsv"
    else
      printf 'f\t%s\tabsent\t%s\t%s\n' "$p" "$mode" "$who" >>"$ND_INST_RB/files.tsv"
    fi
  done <<EOF
$(_nd_inst_owned_paths)
EOF
}

# _nd_inst_restore_files: puts every saved owned file back, and removes the
# ones that did not exist before.
_nd_inst_restore_files() {
  local kind p s mode who
  [ -f "${ND_INST_RB:-}/files.tsv" ] || return 0
  while IFS="$ND_INST_TAB" read -r kind p s mode who; do
    [ -n "$kind" ] || continue
    if [ "$kind" = d ]; then
      rm -rf "${p:?}"
      [ "$s" = absent ] || cp -Rp "$ND_INST_RB/$s" "$p"
    elif [ "$who" = root ]; then
      if [ "$s" = absent ]; then
        sudo rm -f "$p"
      else
        [ "$p" = "$ND_INST_ROOT/etc/sudoers.d/start-container" ] && ! sudo visudo -cf "$ND_INST_RB/$s" >/dev/null && continue
        sudo mkdir -p "$(dirname "$p")" && sudo install -m "$mode" "$ND_INST_RB/$s" "$p"
      fi
    elif [ "$s" = absent ]; then
      rm -f "$p"
    else
      mkdir -p "$(dirname "$p")" && cp -p "$ND_INST_RB/$s" "$p" && chmod "$mode" "$p"
    fi
  done <"$ND_INST_RB/files.tsv"
}

# _nd_inst_restore_tags: :latest back on the images the replaced deployment ran;
# a :latest this install added goes.
_nd_inst_restore_tags() {
  local ref saved
  while IFS="$ND_INST_TAB" read -r ref saved; do
    [ -n "$ref" ] || continue
    if [ "$saved" = absent ]; then
      _nd_inst_image_exists "$ref" && _nd_inst_image_rm "$ref"
    else
      _nd_inst_image_tag "$saved" "$ref"
    fi
  done <<EOF
$(awk -F '\t' 'NR > 1 && $1 == "saved" { print $2 "\t" $3 }' "$ND_INST_MANIFEST")
EOF
}

# nd_install_hold_controller: stops the controller's schedules for the
# transaction, so its recovery never acts on a stack the install is replacing.
nd_install_hold_controller() {
  local u p
  ND_INST_HELD=""
  if [ "$ND_INST_PLATFORM" = linux ]; then
    for u in nice-dns-health.timer nice-dns-health-bridges.timer; do
      if systemctl --user is-active --quiet "$u" 2>/dev/null; then
        systemctl --user stop "$u"
        ND_INST_HELD="$ND_INST_HELD $u"
      fi
    done
  else
    for p in "$HOME/Library/LaunchAgents/org.nice-dns.health.plist" "$HOME/Library/LaunchAgents/org.nice-dns.health-bridges.plist"; do
      if [ -f "$p" ]; then
        launchctl unload "$p" 2>/dev/null || true
        ND_INST_HELD="$ND_INST_HELD $p"
      fi
    done
  fi
}

# _nd_inst_release_controller: restarts the schedules held (rollback only; a
# successful install's controller install starts its own).
_nd_inst_release_controller() {
  local x
  for x in $ND_INST_HELD; do
    if [ "$ND_INST_PLATFORM" = linux ]; then
      systemctl --user start "$x"
    else
      [ -f "$x" ] && launchctl load "$x"
    fi
  done
}

# nd_install_wait_ready: the new chain answers an ordinary query at the
# address the host will be pinned to, within ND_INST_READY_TRIES x 5 s.
nd_install_wait_ready() {
  local i=0 addr
  addr="$(_nd_inst_dns_addr)"
  echo "Waiting for the DNS chain to come up at $addr (Tor bootstrap takes 1-4 min)..."
  while [ "$i" -lt "$ND_INST_READY_TRIES" ]; do
    if dig "@$addr" +time=3 +tries=1 +short "$ND_INST_PROBE_NAME" 2>/dev/null | grep -Eq '^[0-9.]+$' \
        && _nd_inst_route_probe; then
      echo "Chain is resolving, and Unbound resolves over its authenticated route."
      return 0
    fi
    i=$((i + 1))
    sleep 5
  done
  _nd_inst_err "the new stack did not answer at $addr within $((ND_INST_READY_TRIES * 5)) s; not pinning the host resolver"
  return 1
}

# _nd_inst_route_probe: Unbound resolves over its own route in a fresh TLS
# session (nice-dns-unbound-start probe-route), so a Pi-hole answer from
# cache alone cannot pass the readiness wait (DEC-006). The image is built
# from this tree, so the probe must exist.
_nd_inst_route_probe() {
  local rc=0
  case "$ND_INST_PLATFORM" in
    linux) podman exec --user unbound unbound /usr/local/bin/nice-dns-unbound-start probe-route . >/dev/null 2>&1 || rc=$? ;;
    macos) "${CONTAINER_BIN:-container}" exec --user unbound unbound /usr/local/bin/nice-dns-unbound-start probe-route . >/dev/null 2>&1 || rc=$? ;;
  esac
  # A rolled-back generation may predate probe-route (exit 126/127): its Pi-hole
  # answer is then all there is to go on.
  if [ "${ND_INST_PROBE_OPTIONAL:-0}" = 1 ] && { [ "$rc" = 126 ] || [ "$rc" = 127 ]; }; then rc=0; fi
  return "$rc"
}

# _nd_inst_controller_entry: the installed controller's entrypoint.
_nd_inst_controller_entry() {
  local rec
  if [ "$ND_INST_PLATFORM" = linux ]; then
    rec="${XDG_DATA_HOME:-$HOME/.local/share}/nice-dns-health/install.tsv"
  else
    rec="$HOME/Library/Application Support/nice-dns-health/install.tsv"
  fi
  if [ -f "$rec" ] && [ ! -L "$rec" ]; then
    awk -F '\t' 'NR == 1 && $0 != "schema\tnice-dns-health-install/1" { exit } $1 == "entrypoint" { print $2; exit }' "$rec"
  else
    printf '%s\n' "$HOME/.local/bin/nice-dns-health"
  fi
}

# nd_install_controller_self_check: the installed controller loads its bundle.
nd_install_controller_self_check() {
  local ep
  ep="$(_nd_inst_controller_entry)"
  if [ -z "$ep" ] || [ ! -f "$ep" ]; then _nd_inst_err "the controller is not installed; not pinning the host resolver"; return 1; fi
  if ! bash "$ep" self-check >/dev/null; then _nd_inst_err "the installed controller fails its self-check; not pinning the host resolver"; return 1; fi
  echo "  • The controller is installed and passes its self-check."
}

# nd_install_verify_pin: the host resolver is pinned and the stack answers.
nd_install_verify_pin() {
  [ "$(_nd_inst_dns_helper status)" = pinned ] || { _nd_inst_err "the host resolver is not pinned after the pin"; return 1; }
  ND_INST_READY_TRIES=6 nd_install_wait_ready >/dev/null || return 1
}

# _nd_inst_begin_interruption: from here a failure rolls back.
_nd_inst_begin_interruption() {
  ND_INST_PHASE=interrupted ND_INST_PINNED=0
  trap '_nd_inst_exit_trap' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
}

_nd_inst_end_interruption() {
  ND_INST_PHASE="done"
  trap - INT TERM HUP
}

# _nd_inst_exit_trap: the entrypoint's EXIT trap once the interruption began:
# a failure rolls back; the staged copies are removed either way.
_nd_inst_exit_trap() {
  local rc=$?
  trap - EXIT
  set +e
  if [ "$rc" -ne 0 ] && [ "${ND_INST_PHASE:-}" = interrupted ]; then
    echo "✗ The install failed after the stack was interrupted (exit $rc); rolling back." >&2
    _nd_inst_rollback
  fi
  [ -z "${ND_INST_CLEANUP:-}" ] || rm -rf "${ND_INST_CLEANUP:?}"
  [ -z "${ND_INST_WORK:-}" ] || rm -rf "${ND_INST_WORK:?}"
  exit "$rc"
}

_nd_inst_rollback() {
  local back=1
  # A second Ctrl-C must not cut the recovery short.
  trap '' INT TERM HUP
  _nd_inst_manifest_row "$ND_INST_MANIFEST" status rolling-back
  if [ "$ND_INST_PLATFORM" = linux ]; then _nd_inst_linux_stop_new; else _nd_inst_macos_stop_new; fi
  if [ "$ND_INST_HAD_DEPLOY" = 0 ]; then
    # A first install: give back the DNS state recorded before it, or drop
    # the unused record when nothing was pinned.
    if [ "$ND_INST_PINNED" = 1 ]; then _nd_inst_dns_helper restore; else _nd_inst_dns_helper discard; fi
  fi
  _nd_inst_restore_files
  _nd_inst_restore_tags
  if [ "$ND_INST_HAD_DEPLOY" = 1 ]; then
    if [ "$ND_INST_PLATFORM" = linux ]; then
      systemctl --user daemon-reload
      systemctl --user start nice-dns-pod.service
    else
      launchctl load "$HOME/Library/LaunchAgents/org.nice-dns.start-container.plist"
    fi
  elif [ "$ND_INST_PLATFORM" = linux ]; then
    systemctl --user daemon-reload
  fi
  _nd_inst_release_controller
  if [ "$ND_INST_HAD_DEPLOY" = 1 ]; then
    # The previous stack must answer again; the rollback does not claim it.
    ND_INST_PROBE_OPTIONAL=1 nd_install_wait_ready >&2 || back=0
  fi
  _nd_inst_manifest_row "$ND_INST_MANIFEST" status "$( [ "$back" = 1 ] && echo rolled-back || echo rolled-back-not-answering)"
  if [ "$ND_INST_HAD_DEPLOY" = 1 ] && [ "$back" = 1 ]; then
    echo "Rolled back to the previous deployment ($ND_INST_PREV), which answers again; host DNS stays pinned to it." >&2
  elif [ "$ND_INST_HAD_DEPLOY" = 1 ]; then
    echo "Rolled back to the previous deployment ($ND_INST_PREV), but it does not answer: host DNS stays pinned to it, so the host has no DNS (it fails closed, never public)." >&2
    echo "Check the stack (podman ps / container list) and its logs, or run the uninstall to restore the DNS recorded before nice-dns." >&2
  else
    echo "Rolled back: nothing is installed and host DNS is as it was before the install." >&2
  fi
}

# ─────────────────────────── release inputs (Task 1.3) ───────────────────────
#
# Sub-plan 4 Task 1.3 (ARCH-05, ARCH-08). Every image an install pulls or
# builds on is pinned in release/images.lock (reviewed; refreshed with
# scripts/update-images-lock.sh, docs/release-inputs.md): the proxy and the
# two build bases by multi-platform index digest, with their platforms,
# source commit and signer. Before anything is interrupted, an install checks
# the lock's shape, that this host's platform is supported, that the chosen
# proxy provides every interface this tree requires, and each signed image's
# signature when cosign is installed (ND_INST_REQUIRE_SIGNATURES=1 makes a
# missing cosign fatal). An unsigned upstream input is recorded as unsigned;
# no check is invented for it.

ND_INST_LOCK_SCHEMA='nice-dns-images-lock/1'

# _nd_inst_lock_image <role> <column>: one field of the lock's image row.
_nd_inst_lock_image() {
  awk -F '\t' -v r="$1" -v c="$2" '$1 == "image" && $2 == r { print $c; exit }' "$ND_INST_LOCK"
}

# _nd_inst_host_platform: this host as an OCI platform (containers are Linux;
# a Mac runs linux/arm64 guests).
_nd_inst_host_platform() {
  case "$(uname -m)" in
    x86_64|amd64) echo linux/amd64 ;;
    aarch64|arm64) echo linux/arm64 ;;
    armv7l|armv7*) echo linux/arm/v7 ;;
    riscv64) echo linux/riscv64 ;;
    *) echo "linux/$(uname -m)" ;;
  esac
}

# _nd_inst_lock_roles: the image roles this install uses.
_nd_inst_lock_roles() {
  printf 'proxy-%s\nunbound-base\n' "$ND_INST_VARIANT"
  [ "$ND_INST_PIHOLE" = standard ] && printf 'pihole-base\n'
  return 0
}

# nd_install_read_lock: validates the lock and this install's choices from it.
# Sets ND_INST_LOCK and ND_INST_PINNED_<role> (repository@digest); records the
# lock and the locked references in the manifest. Refuses (returns 1) on any
# problem; nothing has been interrupted yet.
nd_install_read_lock() {
  local lock="$ND_INST_TREE/release/images.lock" bad role plat sup ifc sha
  ND_INST_LOCK="$lock"
  if [ -L "$lock" ] || [ ! -f "$lock" ]; then _nd_inst_err "no release/images.lock in the source tree"; return 1; fi
  [ "$(head -n 1 "$lock")" = "schema$ND_INST_TAB$ND_INST_LOCK_SCHEMA" ] \
    || { _nd_inst_err "$lock is not a $ND_INST_LOCK_SCHEMA lock"; return 1; }
  bad="$(awk -F '\t' '
    NR == 1 || /^#/ || NF == 0 { next }
    $1 == "supported" && NF == 2 && $2 ~ /^[a-z0-9]+\/[a-z0-9]+(\/v[0-9]+)?(,[a-z0-9]+\/[a-z0-9]+(\/v[0-9]+)?)*$/ { next }
    $1 == "issuer" && NF == 2 && $2 ~ /^https:\/\/[^[:space:]]+$/ { next }
    $1 == "image" && NF == 9 && $2 ~ /^[a-z0-9-]+$/ && $3 ~ /^docker\.io\/[a-z0-9._\/-]+$/ && $4 ~ /^[A-Za-z0-9._-]+$/ \
      && $5 ~ /^sha256:[0-9a-f]{64}$/ && $6 ~ /^[a-z0-9]+\/[a-z0-9]+(\/v[0-9]+)?(,[a-z0-9]+\/[a-z0-9]+(\/v[0-9]+)?)*$/ \
      && $7 != "" && $8 != "" && ($9 == "none" || $9 ~ /^https:\/\/[^[:space:]]+$/) { next }
    $1 == "unpublished" && NF == 4 { next }
    ($1 == "provides" || $1 == "requires") && NF == 3 && $2 ~ /^[a-z0-9-]+$/ && $3 ~ /^[a-z0-9-]+\/[0-9]+$/ { next }
    { print NR ": " $0; exit }' "$lock")"
  [ -z "$bad" ] || { _nd_inst_err "malformed row in $lock, line $bad"; return 1; }

  plat="$(_nd_inst_host_platform)"
  sup="$(awk -F '\t' '$1 == "supported" { print $2; exit }' "$lock")"
  case ",$sup," in *",$plat,"*) ;; *)
    _nd_inst_err "this host is $plat; nice-dns supports $sup (release/images.lock)"; return 1 ;;
  esac
  for role in $(_nd_inst_lock_roles); do
    [ -n "$(_nd_inst_lock_image "$role" 5)" ] || { _nd_inst_err "release/images.lock has no image for $role"; return 1; }
    case ",$(_nd_inst_lock_image "$role" 6)," in *",$plat,"*) ;; *)
      _nd_inst_err "the locked $role image has no $plat build"; return 1 ;;
    esac
  done
  # The interfaces this tree's controller, quadlets and routes need from the
  # proxy image must be provided by the one this install runs.
  # (Interface names are validated tokens, one per row.)
  while IFS= read -r ifc; do
    [ -n "$ifc" ] || continue
    awk -F '\t' -v r="proxy-$ND_INST_VARIANT" -v i="$ifc" '$1 == "provides" && $2 == r && $3 == i { f = 1 } END { exit !f }' "$lock" \
      || { _nd_inst_err "the locked tor-$ND_INST_VARIANT image does not provide $ifc, which this nice-dns needs; refusing before any change"; return 1; }
  done <<EOF
$(awk -F '\t' '$1 == "requires" && $2 == "proxy" { print $3 }' "$lock")
EOF

  ND_INST_PINNED_PROXY="$(_nd_inst_lock_image "proxy-$ND_INST_VARIANT" 3)@$(_nd_inst_lock_image "proxy-$ND_INST_VARIANT" 5)"
  ND_INST_PINNED_UNBOUND="$(_nd_inst_lock_image unbound-base 3)@$(_nd_inst_lock_image unbound-base 5)"
  ND_INST_PINNED_PIHOLE="$(_nd_inst_lock_image pihole-base 3)@$(_nd_inst_lock_image pihole-base 5)"
  sha="$(health_sha_file "$lock")" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" lock "sha256:$sha" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" platform-host "$plat" || return 1
  for role in $(_nd_inst_lock_roles); do
    _nd_inst_manifest_row "$ND_INST_MANIFEST" locked "$role" \
      "$(_nd_inst_lock_image "$role" 3)@$(_nd_inst_lock_image "$role" 5)" \
      "$(_nd_inst_lock_image "$role" 7)" "$(_nd_inst_lock_image "$role" 8)" || return 1
  done
}

# health_sha_file <file>: its sha256, hex (sha256sum on Linux, shasum on macOS).
health_sha_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# nd_install_verify_signatures: each signed image this install uses, checked
# on its locked digest against the lock's signer and issuer.
nd_install_verify_signatures() {
  local role signer issuer ref unverified=0
  issuer="$(awk -F '\t' '$1 == "issuer" { print $2; exit }' "$ND_INST_LOCK")"
  for role in $(_nd_inst_lock_roles); do
    signer="$(_nd_inst_lock_image "$role" 9)"
    ref="$(_nd_inst_lock_image "$role" 3)@$(_nd_inst_lock_image "$role" 5)"
    if [ "$signer" = none ]; then
      _nd_inst_manifest_row "$ND_INST_MANIFEST" signature "$role" unsigned || return 1
      continue
    fi
    if command -v cosign >/dev/null 2>&1; then
      if ! cosign verify --certificate-identity-regexp "^$(printf '%s' "$signer" | sed 's/\./\\./g')" \
            --certificate-oidc-issuer "$issuer" "$ref" >/dev/null 2>&1; then
        _nd_inst_err "the signature of $ref does not verify for $signer; refusing before any change"
        return 1
      fi
      _nd_inst_manifest_row "$ND_INST_MANIFEST" signature "$role" verified "$signer" || return 1
    elif [ "${ND_INST_REQUIRE_SIGNATURES:-}" = 1 ]; then
      _nd_inst_err "ND_INST_REQUIRE_SIGNATURES=1 but cosign is not installed; refusing before any change"
      return 1
    else
      _nd_inst_manifest_row "$ND_INST_MANIFEST" signature "$role" unverified-no-cosign || return 1
      unverified=1
    fi
  done
  if [ "$unverified" = 1 ]; then
    echo "  ! Image signatures were not verified (cosign is not installed); the images are pinned by digest from the reviewed release/images.lock."
  fi
}

# _nd_inst_record_blocklist: the gravity sources the Pi-hole build bakes in.
_nd_inst_record_blocklist() {
  local sha
  sha="$(health_sha_file "$ND_INST_TREE/pihole/adlists-default.txt")" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" blocklist adlists "sha256:$sha" || return 1
  sha="$(health_sha_file "$ND_INST_TREE/pihole/custom-allowlist.txt")" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" blocklist allowlist "sha256:$sha"
}

# _nd_inst_hardened_sibling: the sibling pi-hole-hardened checkout the hardened
# base is built from (it is not published; see the lock), with its commit
# recorded. Refuses when there is none.
_nd_inst_hardened_sibling() {
  local sib c
  sib="$(cd "$ND_INST_SRC/.." && pwd)/pi-hole-hardened"
  if [[ ! -f "$sib/Dockerfile" || ! -f "$sib/post-install.sh" ]]; then
    _nd_inst_err "the hardened base is not published (release/images.lock); clone https://github.com/sureserverman/pi-hole-hardened next to nice-dns/ ($sib) and run again"
    return 1
  fi
  c="$(git -C "$sib" rev-parse HEAD 2>/dev/null)" || c=""
  case "$c" in ''|*[!0-9a-f]*) c=unknown ;; esac
  _nd_inst_manifest_row "$ND_INST_MANIFEST" source hardened-base "$sib@$c" || return 1
  printf '%s\n' "$sib"
}

# ─────────────────────────── Linux ───────────────────────────────────────────

# nd_install_linux_host_prereqs: packages, Podman/crun versions, registries,
# AppArmor, sysctl, subuid/subgid, cgroup delegation and linger. None of it
# interrupts the running stack or host DNS.
nd_install_linux_host_prereqs() {
  # Pin all sejug/podman PPA packages (podman, crun, containers-common, ...) at
  # priority 600 so apt installs the PPA's coherent stack rather than mixing with
  # Ubuntu archive versions. Inert if the PPA isn't added yet.
  printf 'Package: *\nPin: release o=LP-PPA-sejug-podman\nPin-Priority: 600\n' \
    | sudo tee /etc/apt/preferences.d/podman-ppa >/dev/null

  # Repair package state if a previous install left the PPA half-configured
  if grep -rqs 'sejug/podman' /etc/apt/sources.list.d/ 2>/dev/null; then
    sudo apt-get update -q
    sudo apt-get install -yq --fix-broken
  fi

  # Base packages. catatonit is the pause binary Podman uses when building the
  # pod's infra container (`podman pod create` errors out with "finding pause
  # binary: exec: catatonit: executable file not found in $PATH" without it).
  # netavark is Podman 5.x's network backend and aardvark-dns is the in-network
  # resolver; both are pulled via Recommends on stock Ubuntu, but we use
  # --no-install-recommends, so name them explicitly. Without netavark, `podman
  # network create dnsnet` fails with "netavark: not found". bind9-dnsutils
  # is the host's dig: the install's readiness wait and the controller's
  # observations query the stack with it.
  sudo apt-get install -yq --no-install-recommends git podman netavark aardvark-dns catatonit bind9-dnsutils

  # Ensure user-level registries.conf knows about docker.io
  local CONFIG
  CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/containers/registries.conf"
  mkdir -p "$(dirname "$CONFIG")"
  if [[ ! -f "$CONFIG" ]]; then
    cat > "$CONFIG" <<'EOF'
# registries.conf for Podman

unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "registry-1.docker.io"
EOF
  fi
  if grep -q '^[[:space:]]*unqualified-search-registries' "$CONFIG"; then
    if ! grep -q '^[[:space:]]*unqualified-search-registries.*docker.io' "$CONFIG"; then
      sed -i 's|^[[:space:]]*unqualified-search-registries.*|unqualified-search-registries = ["docker.io"]|' "$CONFIG"
    fi
  else
    echo 'unqualified-search-registries = ["docker.io"]' >> "$CONFIG"
  fi
  if ! grep -q '^[[:space:]]*prefix[[:space:]]*=[[:space:]]*"docker.io"' "$CONFIG"; then
    cat >> "$CONFIG" <<'EOF'

[[registry]]
prefix = "docker.io"
location = "registry-1.docker.io"
EOF
  fi

  # Ensure Podman >= 5.3.0. The .pod quadlet type itself only exists in Podman
  # 5.0+, so a stale 4.x binary will silently ignore deb/quadlet/nice-dns.pod
  # and `systemctl --user restart nice-dns-pod.service` fails with
  # "Unit nice-dns-pod.service not found." Re-check after the upgrade so we
  # fail fast with a clear message instead of bombing out later in
  # persistent-podman.sh.
  local MIN_PODMAN="5.3.0" CUR_PODMAN MIN_CRUN="1.14.3" CUR_CRUN pkg
  CUR_PODMAN=$(podman --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
  if ! printf '%s\n%s\n' "$MIN_PODMAN" "$CUR_PODMAN" | sort -V -C; then
    echo "Podman $CUR_PODMAN < $MIN_PODMAN — upgrading via ppa:sejug/podman..."
    sudo add-apt-repository -y ppa:sejug/podman
    sudo apt-get update -q
    sudo apt-get install -yq --fix-broken
    # PPA's containers-common replaces golang-github-containers-{common,image}
    # from Ubuntu repos; remove them first to avoid dpkg file conflicts
    for pkg in golang-github-containers-common golang-github-containers-image; do
      if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        sudo dpkg --remove --force-depends "$pkg"
      fi
    done
    # Ubuntu's podman-compose and PPA's podman both ship
    # /usr/share/man/man1/podman-compose.1.gz; divert *before* installing the
    # PPA podman so dpkg doesn't fail with a file conflict. Must happen before
    # the `apt-get install podman crun` below.
    sudo dpkg-divert --add --rename --package podman \
      --divert /usr/share/man/man1/podman-compose.1.gz.dpkg-divert \
      /usr/share/man/man1/podman-compose.1.gz 2>/dev/null || true
    sudo apt-get install -yq --no-install-recommends podman crun
    # Re-check that the upgrade actually moved us to >= 5.3.0. The PPA does not
    # ship every Ubuntu release / arch combo, and apt-get can return success
    # without changing the binary version (no candidate, version held, etc.).
    CUR_PODMAN=$(podman --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
    if ! printf '%s\n%s\n' "$MIN_PODMAN" "$CUR_PODMAN" | sort -V -C; then
      echo "ERROR: Podman is still at $CUR_PODMAN after the upgrade attempt." >&2
      echo "       nice-dns requires Podman >= $MIN_PODMAN (the .pod quadlet" >&2
      echo "       type was added in Podman 5.0). Check whether ppa:sejug/podman" >&2
      echo "       has a build for $(lsb_release -cs 2>/dev/null || uname -m):" >&2
      echo "         apt-cache policy podman" >&2
      echo "       If no PPA candidate is available for your Ubuntu release/arch," >&2
      echo "       upgrade to a release that ships Podman 5.x natively (Ubuntu 25.04+)." >&2
      exit 1
    fi
  fi

  # Ensure crun >= 1.14.3 (older versions reject OCI runtime-spec 1.2.x from Podman 5)
  CUR_CRUN=$(crun --version 2>/dev/null | grep -oP 'crun version \K\d+\.\d+(\.\d+)?' || echo "0.0.0")
  if ! printf '%s\n%s\n' "$MIN_CRUN" "$CUR_CRUN" | sort -V -C; then
    echo "crun $CUR_CRUN < $MIN_CRUN — upgrading via ppa:sejug/podman..."
    if ! grep -rqs 'sejug/podman' /etc/apt/sources.list.d/ 2>/dev/null; then
      sudo add-apt-repository -y ppa:sejug/podman
      sudo apt-get update -q
    fi
    sudo apt-get install -yq --no-install-recommends crun
  fi

  # pasta is a symlink to passt, so AppArmor applies the passt profile.
  # Ubuntu Noble's stock passt (0.0~git20240220) ships a profile written before
  # Podman 5.x rootless-netns. The PPA upgrades the binary but marks the
  # conffiles obsolete, so they'll never be overwritten by package upgrades.
  # Replace the entire profile with one that covers rootless-netns.
  if [ -f /etc/apparmor.d/usr.bin.passt ]; then
    sudo tee /etc/apparmor.d/usr.bin.passt > /dev/null <<'APPARMOR'
abi <abi/3.0>,

include <tunables/global>

profile passt /usr/bin/passt{,.avx2} flags=(attach_disconnected) {
  include <abstractions/pasta>

  # Podman 5.x rootless-netns with pasta
  allow userns,
  ptrace (read) peer=crun,
  signal (receive) peer=podman,
  @{PROC}/[0-9]*/ns/ r,
  @{PROC}/sys/net/** r,
  @{run}/user/@{uid}/containers/** rwlk,
  # Standalone (non-pod) containers run with --userns=keep-id place their netns
  # under run/user/<uid>/netns/ rather than the containers/ subtree; pasta must
  # read that dir to enter the namespace. Without this, the host-side bridge-eval
  # "manage" job (nice-dns-fetch-bridges.service) dies with pasta "netns dir
  # open: Permission denied" (exit 126), so bridges.env never refreshes.
  @{run}/user/@{uid}/netns/ r,
  @{run}/user/@{uid}/netns/** rwlk,

  owner /tmp/**				w,
  owner @{HOME}/**			w,

  include if exists <local/usr.bin.passt>
}
APPARMOR
    sudo apparmor_parser -r --skip-cache /etc/apparmor.d/usr.bin.passt
  fi

  echo 'net.ipv4.ip_unprivileged_port_start = 53' | \
    sudo tee /etc/sysctl.d/99-podman-privileged-ports.conf >/dev/null
  sudo sysctl --system

  # Add UID/GID mappings for current user if missing. Accept any pre-existing
  # range — usermod --add-sub{u,g}ids fails if the user already has an entry
  # and we have no reason to force our specific range over whatever is there.
  # ND_INST_ETC is where the id files are read (the fixture tests).
  local subids_added=0
  if ! grep -q "^$USER:" "${ND_INST_ETC:-/etc}/subuid" 2>/dev/null; then
    sudo usermod --add-subuids 100000-165535 "$USER"
    subids_added=1
  fi
  if ! grep -q "^$USER:" "${ND_INST_ETC:-/etc}/subgid" 2>/dev/null; then
    sudo usermod --add-subgids 100000-165535 "$USER"
    subids_added=1
  fi
  # Ranges added just now reach podman only through `podman system migrate`,
  # and the image builds below need them. It stops the user's running
  # containers (podman-system-migrate(1)), but a user who had no ranges runs
  # no rootless nice-dns stack to interrupt. Otherwise it waits for the
  # interruption window (nd_install_linux_interrupt_prereqs).
  if [ "$subids_added" = 1 ]; then
    podman system migrate
  fi

  # Enable cgroups v2 delegation for systemd services
  sudo mkdir -p /etc/systemd/system/user@.service.d
  sudo tee /etc/systemd/system/user@.service.d/delegate.conf >/dev/null << EOF
[Service]
Delegate=cpu cpuset io memory pids
EOF
  sudo systemctl daemon-reload

  # Enable user lingering for service persistence
  sudo loginctl enable-linger "$USER"

  # Re-exec the user's systemd manager so it picks up the new cgroup
  # delegation config. daemon-reload only affects PID 1 (system level);
  # the user instance keeps the old settings until re-exec or reboot.
  systemctl --user daemon-reexec
}

# nd_install_linux_prepare_images: builds unbound and pi-hole (and the hardened
# base) under generation tags and pulls the proxy, all while the running stack
# keeps serving from its own images.
nd_install_linux_prepare_images() {
  local gen="$ND_INST_GEN"
  cd "$ND_INST_TREE" || return 1
  # --dns 1.1.1.1 ensures the pi-hole image build's `pihole -g` precheck
  # always succeeds, even on hosts whose default resolver is partial.
  #
  # The bases are the locked digests (release/images.lock), pulled here and
  # passed as BASE_IMAGE, so a build never floats to whatever :latest is today
  # (Task 1.3). --pull=newer stays for any other FROM a recipe names (the
  # hardened sibling's own base); a base that exists only locally, such as the
  # hardened base, still builds: with --pull=newer podman suppresses pull
  # errors when a local image exists.
  #
  # --no-cache because --pull only governs the FROM base, not the RUN layers.
  # Our RUN steps fetch from the network — pihole/Containerfile runs `pihole -g`
  # for the gravity blocklists and `apk -U upgrade` for security updates,
  # unbound/Containerfile runs post-install.sh — so a replayed layer means an
  # image whose blocklists and package updates are as old as the build that
  # first populated the cache.
  #
  # Before Sub-plan 4 the teardown removed the unbound and pi-hole images
  # first, and on podman that also invalidates their cached layers, so this was
  # mostly covered already. "Mostly" is the problem: it made freshness a side
  # effect of teardown ordering and of podman's cache-invalidation behaviour
  # rather than something this build actually asks for. Measured on podman
  # 5.8.1 with a probe image whose RUN step records a timestamp: rebuilding
  # while the image still exists replays the cached layer (identical stamp),
  # --no-cache does not. The builds now run before the teardown, next to the
  # running stack's images, so --no-cache is what keeps them fresh.
  #
  # The standard and hardened entrypoints build with the same flags.
  if [ "$ND_INST_PIHOLE" = hardened ]; then
    _nd_inst_linux_hardened_base || return 1
  else
    podman pull "$ND_INST_PINNED_PIHOLE" || return 1
    _nd_inst_manifest_row "$ND_INST_MANIFEST" pulled base "$ND_INST_PINNED_PIHOLE" || return 1
  fi
  podman pull "$ND_INST_PINNED_UNBOUND" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" pulled base "$ND_INST_PINNED_UNBOUND" || return 1
  _nd_inst_record_blocklist || return 1
  podman build "${ND_INST_LINUX_BUILD_FLAGS[@]}" --build-arg "BASE_IMAGE=$ND_INST_PINNED_UNBOUND" \
    -t "localhost/unbound:$gen" unbound/ || return 1
  _nd_inst_record_image unbound "localhost/unbound:$gen" || return 1
  if [ "$ND_INST_PIHOLE" = hardened ]; then
    # Hardened-base Pi-hole: pihole-hardened/Containerfile `FROM`s the hardened
    # base and layers on the gravity DB, allowlist seeds, and post-install.sh
    # lockdown. The build context is the repo root.
    podman build "${ND_INST_LINUX_BUILD_FLAGS[@]}" --build-arg "BASE_IMAGE=localhost/pi-hole-hardened-base:$gen" \
      -t "localhost/pi-hole:$gen" -f pihole-hardened/Containerfile . || return 1
  else
    podman build "${ND_INST_LINUX_BUILD_FLAGS[@]}" --build-arg "BASE_IMAGE=$ND_INST_PINNED_PIHOLE" \
      -t "localhost/pi-hole:$gen" pihole/ || return 1
  fi
  _nd_inst_record_image pi-hole "localhost/pi-hole:$gen" || return 1
  # The proxy is pulled by its locked digest, not built. Its generation tag
  # keeps the image this generation ran for rollback; :latest (the name the
  # quadlet runs) moves to it only at activation.
  podman pull "$ND_INST_PINNED_PROXY" || return 1
  podman tag "$ND_INST_PINNED_PROXY" "localhost/tor-${ND_INST_VARIANT}:$gen" || return 1
  _nd_inst_record_image proxy "localhost/tor-${ND_INST_VARIANT}:$gen" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" pulled proxy "$ND_INST_PINNED_PROXY"
}

# Build (or pull-and-tag) the hardened Pi-hole base under its generation tag,
# before the downstream pihole-hardened/Containerfile build.
_nd_inst_linux_hardened_base() {
  local base_img="localhost/pi-hole-hardened-base:$ND_INST_GEN" sibling_repo
  echo "▸ Resolving hardened base image…"
  sibling_repo="$(_nd_inst_hardened_sibling)" || return 1
  echo "  • Sibling pi-hole-hardened repo found at $sibling_repo — building locally."
  podman build "${ND_INST_LINUX_BUILD_FLAGS[@]}" -t "$base_img" "$sibling_repo" || return 1
  _nd_inst_record_image hardened-base "$base_img"
}

# nd_install_linux_stop_stack: the interruption. It stops the stack and removes
# its quadlets (a variant switch must not leave the other proxy's), but keeps
# every image (the previous generation is the rollback target, ARCH-08) and
# never touches host DNS: the resolver keeps its pin, so it fails closed until
# the new stack answers. The files it removes were saved by
# nd_install_save_previous.
nd_install_linux_stop_stack() {
  local svc name
  # Stop and disable user-mode quadlet services, then remove quadlet files.
  # nice-dns-warmup is here only to clean up after older installs that
  # shipped the (since-removed) cache pre-seed unit; current installs
  # never lay it down. Safe to drop from this list once enough cycles
  # of `uninstall` have run in the wild.
  for svc in pi-hole unbound tor-haproxy tor-socat nice-dns-pod nice-dns-network nice-dns-warmup; do
    systemctl --user disable --now "${svc}.service" 2>/dev/null || true
  done
  rm -f "$HOME/.config/containers/systemd/"{pi-hole,unbound,tor-haproxy,tor-socat}.container \
        "$HOME/.config/containers/systemd/nice-dns.pod" \
        "$HOME/.config/containers/systemd/nice-dns.network" \
        "$HOME/.config/systemd/user/nice-dns-warmup.service" \
        "$HOME/.local/bin/nice-dns-warmup" \
        "$HOME/.config/nice-dns/warmup-domains.txt" \
        "$HOME/.config/containers/containers.conf.d/90-nice-dns-firewall.conf"
  systemctl --user daemon-reload 2>/dev/null || true

  # Containers, network (images stay)
  podman pod rm -f nice-dns 2>/dev/null || true
  for name in tor-socat tor-haproxy unbound pi-hole; do
    podman rm -f "$name" 2>/dev/null || true
  done
  podman network rm dnsnet 2>/dev/null || true
}

# _nd_inst_linux_stop_new: the rollback's first step, the new stack goes.
_nd_inst_linux_stop_new() {
  local svc name
  for svc in pi-hole unbound tor-haproxy tor-socat nice-dns-pod; do
    systemctl --user stop "${svc}.service" 2>/dev/null || true
  done
  podman pod rm -f nice-dns 2>/dev/null || true
  for name in tor-socat tor-haproxy unbound pi-hole; do
    podman rm -f "$name" 2>/dev/null || true
  done
}

_nd_inst_linux_nm_lockdown() {
  local R="$ND_INST_ROOT"
  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi
  if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
    return 0
  fi

  # Two pieces are sufficient to keep /etc/resolv.conf pinned at 127.0.0.1
  # under NetworkManager:
  #
  #   1. dns=none — tell NM to stop managing /etc/resolv.conf entirely.
  #      With this set, per-connection ipv4.dns / ipv4.ignore-auto-dns
  #      have no observable effect; NM never writes resolv.conf, so
  #      whatever custom-dns-deb wrote stays.
  #
  #   2. dispatcher hook — re-run custom-dns-deb on every NM state change,
  #      so if anything *else* on the system (cloud-init, dhclient, a
  #      package upgrade) ever rewrites resolv.conf, the next NM event
  #      pins it back. Cheap defense-in-depth.
  #
  # An earlier version of this function also iterated every active
  # connection to set ipv4.dns 127.0.0.1 and then re-upped them all. With
  # dns=none in effect those modifications had no observable behaviour —
  # and the re-up loop kicked libvirt bridges (virbr0 etc.) into a
  # deactivate→detach-ports→reactivate cycle that orphaned VM tap
  # interfaces (vnet0…). Removed. (The hardened installer kept that loop
  # until Sub-plan 4 Task 1.2; it also changed connection profiles nice-dns
  # does not own and never restored them.)
  sudo mkdir -p "$R/etc/NetworkManager/conf.d" "$R/etc/NetworkManager/dispatcher.d"
  sudo tee "$R/etc/NetworkManager/conf.d/90-nice-dns.conf" >/dev/null <<'EOF'
[main]
dns=none
EOF
  sudo tee "$R/etc/NetworkManager/dispatcher.d/90-nice-dns-pin" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -x /usr/bin/custom-dns-deb ]; then
  /usr/bin/custom-dns-deb
fi
EOF
  sudo chmod 755 "$R/etc/NetworkManager/dispatcher.d/90-nice-dns-pin"

  sudo systemctl reload NetworkManager 2>/dev/null || sudo systemctl restart NetworkManager
}

_nd_inst_linux_ipv6_disable() {
  local R="$ND_INST_ROOT"
  sudo mkdir -p "$R/etc/sysctl.d"
  sudo tee "$R/etc/sysctl.d/99-nice-dns-disable-ipv6.conf" >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sudo sysctl --system >/dev/null

  # sysctl-only on purpose. The kernel cmdline flag ipv6.disable=1 (shipped by
  # earlier versions as a grub.d drop-in) removes AF_INET6 entirely, so any
  # software that creates an IPv6 socket fails with EAFNOSUPPORT (os error 97)
  # — observed bricking Mullvad's userspace WireGuard (gotatun binds ::), which
  # then fail-closes the whole machine at boot. The sysctl above gives the same
  # posture (no v6 addresses, no v6 traffic) while keeping sockets creatable.
  # Remove the legacy drop-in left by previous installs.
  if sudo test -f "$R/etc/default/grub.d/99-nice-dns-ipv6.cfg"; then
    sudo rm "$R/etc/default/grub.d/99-nice-dns-ipv6.cfg"
    if command -v update-grub >/dev/null 2>&1; then
      sudo update-grub
    fi
  fi
}

# nd_install_linux_pin: the resolver cutover, only after the new stack answers
# and the controller passed its self-check. The pin itself is the helper's.
nd_install_linux_pin() {
  local R="$ND_INST_ROOT"
  ND_INST_PINNED=1
  sudo mkdir -p "$R/etc/systemd/system" "$R/usr/bin"
  sudo install -m 644 "$ND_INST_TREE/deb/custom-dns-deb.service" "$R/etc/systemd/system/custom-dns-deb.service"
  sudo install -m 755 "$ND_INST_TREE/deb/custom-dns-deb" "$R/usr/bin/custom-dns-deb"
  sudo systemctl daemon-reload
  # Enabled for every boot; this run pins explicitly below and checks it.
  sudo systemctl enable custom-dns-deb.service
  _nd_inst_linux_nm_lockdown
  _nd_inst_linux_ipv6_disable
  sudo "$R/usr/bin/custom-dns-deb" pin
}

# nd_install_linux_activate: records the owned DNS state, then interrupts,
# activates and pins, rolling back on any failure (see the transaction notes).
nd_install_linux_activate() {
  _nd_inst_dns_helper snapshot
  _nd_inst_begin_interruption
  nd_install_hold_controller
  nd_install_linux_stop_stack
  nd_install_linux_interrupt_prereqs
  nd_install_linux_activate_images
  # Quadlets, the bridge selection, the pod start and the controller install
  # (whose own self-check must pass before it replaces anything).
  ( cd "$ND_INST_TREE" && ./deb/persistent-podman.sh "$ND_INST_VARIANT" )
  nd_install_wait_ready
  nd_install_controller_self_check
  nd_install_linux_pin
  nd_install_verify_pin
  _nd_inst_end_interruption
}

# nd_install_linux_uninstall: removes the stack, its images and controller,
# and gives back the DNS state recorded before nice-dns. System-wide tweaks
# (PPA pin, sysctl port range, AppArmor, subuid/subgid, cgroup delegation)
# are left in place — they're harmless and may be shared with other Podman
# workloads.
nd_install_linux_uninstall() {
  local R="$ND_INST_ROOT" ref ep sd
  ND_INST_TREE="$ND_INST_SRC"
  nd_install_linux_stop_stack
  systemctl --user disable --now nice-dns-fetch-bridges.service 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/nice-dns-fetch-bridges.service" "$HOME/.local/bin/nice-dns-fetch-bridges"
  ep="$(_nd_inst_controller_entry)"
  if [ -n "$ep" ] && [ -f "$ep" ]; then bash "$ep" uninstall || true; fi
  systemctl --user daemon-reload 2>/dev/null || true
  # The locally built images (localhost/unbound, localhost/pi-hole and the
  # hardened base), their generation tags, and the pulled tor images: those
  # are stored under their full docker.io/sureserver/... reference, which a
  # bare name does not match, so they are named in full.
  for ref in unbound pi-hole pi-hole-hardened-base \
             localhost/unbound:latest localhost/pi-hole:latest localhost/pi-hole-hardened-base:latest \
             docker.io/sureserver/tor-haproxy:latest docker.io/sureserver/tor-socat:latest \
             docker.io/sureserver/pi-hole-hardened:latest \
             $(ND_INST_PLATFORM=linux _nd_inst_generation_refs); do
    podman image rm -f "$ref" 2>/dev/null || true
  done
  # The DNS state before nice-dns: resolv.conf, systemd-resolved, the ipv6
  # sysctls and the NetworkManager/systemd files the pin installed.
  _nd_inst_dns_helper restore
  sudo rm -f "$R/usr/bin/custom-dns-deb"
  if sudo test -f "$R/etc/default/grub.d/99-nice-dns-ipv6.cfg"; then
    sudo rm -f "$R/etc/default/grub.d/99-nice-dns-ipv6.cfg"
    if command -v update-grub >/dev/null 2>&1; then
      sudo update-grub >/dev/null 2>&1 || true
    fi
  fi
  sudo systemctl daemon-reload
  sd="$(nd_install_state_dir)" && rm -f "${sd:?}/current"
}

# nd_install_linux_interrupt_prereqs: host changes that interrupt the running
# stack or host DNS, so they run only after the teardown.
nd_install_linux_interrupt_prereqs() {
  # Disable dns=dnsmasq in NetworkManager if present (conflicts with pi-hole)
  local NM_CONFIG="/etc/NetworkManager/NetworkManager.conf"
  if [ -f "$NM_CONFIG" ] && grep -Eq '^[[:space:]]*dns[[:space:]]*=[[:space:]]*dnsmasq' "$NM_CONFIG"; then
    sudo sed -i -E 's|^[[:space:]]*dns[[:space:]]*=[[:space:]]*dnsmasq|#&|' "$NM_CONFIG"
    sudo systemctl restart NetworkManager
  fi

  # Pick up subuid/subgid and cgroup delegation changes. It stops every
  # running container of this user (podman-system-migrate(1)), so it is not
  # part of preparation.
  podman system migrate

  # Reconcile the rootless firewall driver with the installed netavark's
  # capabilities before the stack starts (see the function comment). After
  # the teardown, which removes the drop-in.
  _nd_inst_linux_netavark_firewall_driver
}

# Podman 5.x defaults the network firewall_driver to "nftables", but the
# netavark nftables driver was only added in netavark 1.9.0. The sejug/podman
# PPA ships Podman 5.x and aardvark-dns but NOT netavark, so on stock Ubuntu the
# resolved netavark stays at 1.4.0 (iptables-only). With that skew every rootless
# podman bridge fails to come up — the pod's infra container exits 125 with
# "netavark: nftables support presently not available", which cascades into
# dependency failures on tor/unbound/pi-hole and the whole stack stays down.
#
# Pin the rootless firewall_driver to whatever the installed netavark can
# actually do. Written as a scoped containers.conf.d drop-in: it never touches
# the system /etc/containers/containers.conf nor the user's own containers.conf,
# and teardown removes it so a later netavark upgrade isn't shadowed.
_nd_inst_linux_netavark_firewall_driver() {
  local drop_in nv_ver
  drop_in="$HOME/.config/containers/containers.conf.d/90-nice-dns-firewall.conf"
  nv_ver=$(podman info --format '{{.Host.NetworkBackendInfo.Version}}' 2>/dev/null \
    | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0")
  # netavark >= 1.9.0 has the nftables driver; leave Podman's default alone.
  if printf '1.9.0\n%s\n' "$nv_ver" | sort -V -C; then
    rm -f "$drop_in"
    return 0
  fi
  mkdir -p "$(dirname "$drop_in")"
  cat > "$drop_in" <<'EOF'
# Installed by nice-dns. netavark < 1.9.0 has no nftables firewall driver, but
# Podman 5.x defaults firewall_driver to "nftables" — the mismatch makes every
# rootless bridge fail with "nftables support presently not available". Pin the
# driver this netavark can actually use. Removed by `install-deb.sh uninstall`.
[network]
firewall_driver = "iptables"
EOF
}

# nd_install_linux_activate_images: points :latest at this generation, so the
# quadlets (Image=localhost/{unbound,pi-hole}:latest) run it unchanged.
nd_install_linux_activate_images() {
  local gen="$ND_INST_GEN" name
  for name in unbound pi-hole; do
    podman tag "localhost/$name:$gen" "localhost/$name:latest" || return 1
  done
  podman tag "localhost/tor-${ND_INST_VARIANT}:$gen" "docker.io/sureserver/tor-${ND_INST_VARIANT}:latest" || return 1
  if [ "$ND_INST_PIHOLE" = hardened ]; then
    podman tag "localhost/pi-hole-hardened-base:$gen" localhost/pi-hole-hardened-base:latest || return 1
  fi
}

# ─────────────────────────── macOS ───────────────────────────────────────────

# nd_install_macos_host_prereqs: Homebrew packages, Rosetta and the runtime.
# A `container` upgrade stops the runtime (and the stack), so it is only
# detected here and applied by nd_install_macos_upgrade_runtime after the
# teardown.
nd_install_macos_host_prereqs() {
  local pkg
  # -- Homebrew + container + Rosetta + git --
  if ! command -v brew >/dev/null; then
    echo "Homebrew not found. Install from https://brew.sh and re-run." >&2
    exit 1
  fi

  brew update

  # Install what's missing AND upgrade what's outdated. The previous form was
  # `brew list ... || brew install`, which only ever installed: once a host had
  # `container` at any version, every later reinstall kept it. Observed in the
  # wild on a host that had been installed months earlier — still running
  # container 0.11.0 while 1.2.2 was current, i.e. five minor releases of
  # networking and lifecycle fixes behind, with the installer reporting success.
  #
  # `brew outdated --quiet` lists only formulae with a newer version available,
  # so an up-to-date host does no work here.
  ND_INST_CONTAINER_UPGRADE=0
  for pkg in git container; do
    if ! brew list --formula "$pkg" >/dev/null 2>&1; then
      brew install --formula "$pkg"
    elif brew outdated --formula --quiet 2>/dev/null | grep -qx "$pkg"; then
      if [ "$pkg" = container ]; then
        # The upgrade stops the runtime, so it is applied in the interruption,
        # where host DNS stays pinned to the stopped stack: download it now
        # (Task 1.2/1.3 bootstrap inventory, release/bootstrap.tsv).
        brew fetch --formula container
        ND_INST_CONTAINER_UPGRADE=1
      else
        brew upgrade --formula "$pkg"
      fi
    fi
  done

  # Apple's container builder is arm64 native, but its VM mounts the host's
  # Rosetta so amd64 binaries can run during multi-arch builds (the builder
  # config sets rosetta:true unconditionally, with no flag to disable it).
  # Install Rosetta so the mount has something to point at; no-op when present.
  if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    sudo softwareupdate --install-rosetta --agree-to-license
  fi

  # -- Bring up the runtime + default kernel --
  CONTAINER_BIN="${CONTAINER_BIN:-/opt/homebrew/bin/container}"
  # First-time start prompts [Y/n] for the kata kernel download; feed `yes` so
  # the install is non-interactive. The subshell swallows the SIGPIPE that
  # hits `yes` when `container` exits, which would otherwise trip pipefail.
  { yes 2>/dev/null || true; } | "$CONTAINER_BIN" system start >/dev/null
}

# nd_install_macos_upgrade_runtime: the deferred `container` upgrade, in the
# interruption window.
nd_install_macos_upgrade_runtime() {
  [ "${ND_INST_CONTAINER_UPGRADE:-0}" = 1 ] || return 0
  if command -v container >/dev/null 2>&1; then
    # Stop the runtime before its binaries are replaced, so the
    # launchd-registered apiserver isn't left pointing at a path brew is
    # about to rewrite. `container system start` below re-registers it.
    container system stop >/dev/null 2>&1 || true
  fi
  # From the bottle fetched in preparation; no update: host DNS is pinned to
  # the stopped stack here (fails closed), so nothing may need the network.
  HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --formula container
  { yes 2>/dev/null || true; } | "$CONTAINER_BIN" system start >/dev/null
}

# nd_install_macos_stage_tree: the build tree, a private copy under $HOME.
nd_install_macos_stage_tree() {
  # Place WORK under $HOME -- Apple Container's builder VM cannot read
  # /var/folders/.../T/ (the macOS default $TMPDIR), so mktemp -d lands in a
  # location the build context transfer can't see, yielding an empty context
  # and "lstat /etc: no such file or directory" during ADD/COPY.
  #
  # A clone already sits under $HOME (the entrypoint put it there). An in-tree
  # checkout is copied, so the macOS-only rewrites below never touch the
  # user's on-disk checkout.
  if [ "$ND_INST_ORIGIN" = checkout ]; then
    ND_INST_WORK="$(mktemp -d "$HOME/.nice-dns-install.XXXXXXXX")" || return 1
    cp -R "$ND_INST_SRC/." "$ND_INST_WORK/nice-dns" || return 1
    ND_INST_TREE="$ND_INST_WORK/nice-dns"
  else
    ND_INST_TREE="$ND_INST_SRC"
  fi
  nd_install_macos_rewrite_tree "$ND_INST_TREE"
}

# -- macOS-only unbound.conf + pihole.toml rewrites (cross-netns) --
# Linux runs pi-hole/unbound/tor-haproxy in a single Podman pod, so they share
# one network namespace and the stock configs (interface/upstream all set to
# 127.0.0.1) Just Work. Apple's `container` 0.11.0 has no pod / shared-netns
# support, so each container gets its own netns and its own IP from `dnsnet`.
# Patch the build tree (NOT the on-disk repo) so the macOS-built images
# bind on / forward to the dnsnet peer IPs. Linux is untouched. Written to a
# temp file and moved into place (no `sed -i ''`), so it runs on either sed.
#
# nd_install_macos_rewrite_tree <tree>
nd_install_macos_rewrite_tree() {
  local _uconf="$1/unbound/etc/unbound.conf" _rconf="$1/unbound/route/forward-route.conf"
  sed -e 's|^    interface: 127\.0\.0\.1$|    interface: 0.0.0.0|' \
      -e 's|^    access-control: 127\.0\.0\.0/8 allow$|    access-control: 127.0.0.0/8 allow\
    access-control: 172.31.240.248/29 allow|' \
      "$_uconf" >"$_uconf.nd-tmp" && mv -f "$_uconf.nd-tmp" "$_uconf" || return 1
  # The forwarder lives in the route include (unbound/route/forward-route.conf,
  # the image default route); unbound.conf only includes it.
  sed -e 's|^    forward-addr: 127\.0\.0\.1@853#tor\.cloudflare-dns\.com$|    forward-addr: 172.31.240.252@853#tor.cloudflare-dns.com|' \
      "$_rconf" >"$_rconf.nd-tmp" && mv -f "$_rconf.nd-tmp" "$_rconf" || return 1

  # Note: pi-hole's bundled pihole.toml hardcodes upstreams = ["127.0.0.1#5335"]
  # for the Linux pod path; on macOS unbound is a peer container at .251. We
  # can't sed the toml at build time — pi-hole runs `pihole -g` during image
  # build and pre-flights the configured upstream, which would fail (no unbound
  # yet). Instead, override at runtime via FTLCONF_dns_upstreams (set on the
  # pi-hole container in nd_install_macos_run_stack).
}

# nd_install_macos_prepare_images: the pulls (proxy, and the hardened base
# when there is no sibling checkout to build it from). Builds wait for the
# _nd_inst_containerfile_base <file>: the image its first FROM names (an
# ARG-named base resolves to the ARG's default).
_nd_inst_containerfile_base() {
  awk '
    /^ARG[ \t]+[A-Za-z_]+=/ { split($2, kv, "="); arg[kv[1]] = kv[2] }
    /^FROM[ \t]/ {
      b = $2
      if (b ~ /^\$\{[A-Za-z_]+\}$/) { n = substr(b, 3, length(b) - 3); b = arg[n] }
      print b; exit
    }' "$1"
}

# _nd_inst_macos_pull_base <ref> [<local name>]: a build base, pulled in
# preparation (and given a plain local name for the builder).
_nd_inst_macos_pull_base() {
  [ -n "$1" ] || { _nd_inst_err "cannot read a build base"; return 1; }
  "$CONTAINER_BIN" image pull "$1" || return 1
  if [ -n "${2:-}" ]; then
    "$CONTAINER_BIN" image tag "$1" "$2" || return 1
    _nd_inst_record_image base "$2" || return 1
  fi
  _nd_inst_manifest_row "$ND_INST_MANIFEST" pulled base "$1"
}

# interruption window.
nd_install_macos_prepare_images() {
  local gen="$ND_INST_GEN" sibling_repo
  # The tor proxy is the one image we don't build — it's pulled from Docker Hub.
  # `container run` has no --pull flag and reuses any locally cached copy without
  # consulting the registry, so an install on a host that ever ran nice-dns would
  # silently keep an old image indefinitely. Observed in practice: a host running
  # a four-month-old tor-haproxy (ConfluxEnabled 0, NumPrimaryGuards 2, timeout
  # server 60s) long after those were fixed upstream, which showed up as multi-
  # second cold DNS latency with nothing wrong in this repo. Pull explicitly, by
  # the reviewed digest in release/images.lock (Task 1.3); :latest moves to it
  # only at activation.
  "$CONTAINER_BIN" image pull "$ND_INST_PINNED_PROXY" || return 1
  "$CONTAINER_BIN" image tag "$ND_INST_PINNED_PROXY" "tor-${ND_INST_VARIANT}:$gen" || return 1
  _nd_inst_record_image proxy "tor-${ND_INST_VARIANT}:$gen" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" pulled proxy "$ND_INST_PINNED_PROXY" || return 1

  # The bases of the local builds, by their locked digests, pulled now while
  # host DNS still answers; the builds run later without --pull (see
  # nd_install_macos_build_images). Apple's builder resolves a local base only
  # by a plain name (fc5e6ec), so each gets one for this generation.
  _nd_inst_macos_pull_base "$ND_INST_PINNED_UNBOUND" "unbound-base:$gen" || return 1
  if [ "$ND_INST_PIHOLE" = standard ]; then
    _nd_inst_macos_pull_base "$ND_INST_PINNED_PIHOLE" "pihole-base:$gen" || return 1
  fi
  _nd_inst_record_blocklist || return 1

  [ "$ND_INST_PIHOLE" = hardened ] || return 0
  # The sibling pi-hole-hardened checkout sits next to the tree this install
  # was started from (never next to the private copy). The hardened base is
  # not published, so there is no fallback.
  echo "▸ Resolving hardened base image…"
  sibling_repo="$(_nd_inst_hardened_sibling)" || return 1
  echo "  • Sibling pi-hole-hardened repo found at $sibling_repo — building it after the stack stops."
  ND_INST_BASE_SIBLING="$sibling_repo"
  _nd_inst_macos_pull_base "$(_nd_inst_containerfile_base "$sibling_repo/Dockerfile")" || return 1
}

# nd_install_macos_bridges: bridges.env, and the proxy's BRIDGEn arguments in
# ND_INST_BRIDGE_ARGS.
nd_install_macos_bridges() {
  local _bridges_file _nbridges=0 _bline
  # Fetch default obfs4 bridges from the Tor Project on first install, then
  # pass them into the container. Idempotent: bridges.env is reused on re-runs.
  "$ND_INST_TREE/scripts/fetch-bridges.sh" || return 1
  # bridges.env is written without surrounding quotes for podman --env-file /
  # systemd EnvironmentFile= compatibility (Linux quadlets), so bash `source`
  # can't be used here — it would split on whitespace inside the obfs4 line.
  # Parse the keys directly with sed instead, taking EVERY BRIDGEn rather than
  # the first three. The image accepts BRIDGE1..16, and >=3 is what Conflux needs
  # for distinct primary guards -- more is better, not worse. Measured on this
  # stack (isolated, alternated, one tor at a time), 3 bridges bootstrapped in a
  # 141s median against 41s for 7, with a much worse tail. bridges.env is ranked
  # fastest-first and that order is preserved here; slots are renumbered
  # contiguously because the image walks BRIDGE1..16 and a gap in the source file
  # would hide everything after it.
  _bridges_file="${XDG_CONFIG_HOME:-$HOME/.config}/nice-dns/bridges.env"
  ND_INST_BRIDGE_ARGS=()
  while IFS= read -r _bline; do
    [[ -n "$_bline" ]] || continue
    (( _nbridges < 16 )) || break
    _nbridges=$(( _nbridges + 1 ))
    ND_INST_BRIDGE_ARGS+=( -e "BRIDGE${_nbridges}=${_bline}" )
  done < <(sed -n 's/^BRIDGE[0-9][0-9]*=//p' "$_bridges_file")
  if (( _nbridges < 3 )); then
    echo "bridges.env yielded $_nbridges bridge(s); need at least 3." >&2
    return 1
  fi
  echo "Using $_nbridges obfs4 bridge(s) from bridges.env."
}

# Reverse every piece of nice-dns state installed by the script: the
# LaunchAgent, sudoers rule, privileged helpers, containers/network,
# and the system DNS pin — plus the Podman-era jobs from installs predating
# commit 7538f02, which no version of this script had ever removed. Homebrew
# packages (container, git) and Rosetta are left in place — they may be
# shared with other tools.
#
# nd_install_macos_teardown <reinstall|uninstall>: a reinstall keeps every
# image (the previous generation is the rollback target, ARCH-08); uninstall
# removes them as before, generation tags included.
nd_install_macos_teardown() {
  local mode="${1:-reinstall}" _a _p _d _legacy_agent c i
  for _a in org.nice-dns.start-container org.nice-dns.bridge-eval; do
    _p="$HOME/Library/LaunchAgents/${_a}.plist"
    launchctl unload "$_p" 2>/dev/null || true
    rm -f "$_p"
  done
  sudo rm -f "$ND_INST_ROOT/etc/sudoers.d/start-container" \
             "$ND_INST_ROOT/usr/local/sbin/start-container.sh" \
             "$ND_INST_ROOT/usr/local/sbin/start-container-root.sh" \
             "$ND_INST_ROOT/usr/local/sbin/nice-dns-bridge-eval.sh"

  # -- Podman-era purge (installs predating commit 7538f02) --------------
  # mac/mac-rules-persist.sh installed four root/user jobs that this script
  # never knew about, so they survived every later reinstall. They are not
  # merely stale:
  #   org.nice-dns.free-port53   boots out com.apple.mDNSResponder at every
  #                              boot, leaving the host with no system
  #                              resolver at all;
  #   com.local.mullvad-pfctl-disable-on-connect
  #                              runs `pfctl -d` once a second, forever
  #                              (KeepAlive + StartInterval 1);
  #   com.local.loopbackalias    aliases 127.0.0.53 onto lo0;
  #   org.startpodman            starts a Podman VM that no longer exists.
  # Observed in the wild on a host installed pre-7538f02: mDNSResponder had
  # been dead across reboots and a gvproxy from the old VM still held :53.
  for _d in org.nice-dns.free-port53 \
            com.local.loopbackalias \
            com.local.mullvad-pfctl-disable-on-connect; do
    sudo launchctl bootout "system/${_d}" 2>/dev/null || true
    sudo rm -f "/Library/LaunchDaemons/${_d}.plist"
  done
  _legacy_agent="$HOME/Library/LaunchAgents/org.startpodman.plist"
  launchctl unload "$_legacy_agent" 2>/dev/null || true
  rm -f "$_legacy_agent"
  sudo rm -f /etc/sudoers.d/start-podman \
             /usr/local/sbin/start-podman.sh \
             /usr/local/sbin/start-podman-root.sh \
             /usr/local/sbin/mullvad-pfctl-disable-on-connect
  sudo ifconfig lo0 -alias 127.0.0.53 2>/dev/null || true

  # Undo free-port53's damage. bootout only removes the service from the
  # running domain — the SIP-protected plist is intact, so re-bootstrapping
  # restores the resolver without a reboot. No-op when it is already loaded.
  if ! sudo launchctl print system/com.apple.mDNSResponder >/dev/null 2>&1; then
    sudo launchctl bootstrap system \
      /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist 2>/dev/null || true
  fi

  # Stop the old Podman stack if it is still up; gvproxy squats :53 and will
  # fight the new pi-hole for it.
  if command -v podman >/dev/null 2>&1; then
    podman machine stop >/dev/null 2>&1 || true
  fi

  # Container CLI may be absent on a half-installed/fresh host — tolerate.
  local bin="${CONTAINER_BIN:-container}"
  if command -v "$bin" >/dev/null 2>&1; then
    for c in pi-hole unbound tor-haproxy tor-socat; do
      "$bin" stop "$c" >/dev/null 2>&1 || true
      "$bin" rm   "$c" >/dev/null 2>&1 || true
    done
    if [ "$mode" = uninstall ]; then
      # Drop the images too on uninstall, not just the containers. Both the
      # bare and registry-qualified names are removed because the local builds
      # are tagged bare (`-t unbound:<generation>`, re-tagged :latest) while
      # the pulled images carry their full docker.io/... reference.
      for i in pi-hole unbound pi-hole-hardened-base \
               pi-hole:latest unbound:latest pi-hole-hardened-base:latest \
               docker.io/sureserver/tor-haproxy:latest \
               docker.io/sureserver/tor-socat:latest \
               docker.io/sureserver/pi-hole-hardened:latest \
               $(ND_INST_PLATFORM=macos _nd_inst_generation_refs); do
        "$bin" image rm "$i" >/dev/null 2>&1 || true
      done
    fi
    "$bin" network rm dnsnet >/dev/null 2>&1 || true
  fi

  # Host DNS is not touched here: during a reinstall every service keeps its
  # pin (it fails closed until the new stack answers), and uninstall gives
  # back the recorded servers through the root helper (nd_install_macos_uninstall).
}

# _nd_inst_macos_stop_new: the rollback's first step, the new stack goes.
_nd_inst_macos_stop_new() {
  local p c bin="${CONTAINER_BIN:-container}"
  for p in start-container health health-bridges; do
    launchctl unload "$HOME/Library/LaunchAgents/org.nice-dns.$p.plist" 2>/dev/null || true
  done
  for c in pi-hole unbound tor-haproxy tor-socat; do
    "$bin" stop "$c" >/dev/null 2>&1 || true
    "$bin" rm "$c" >/dev/null 2>&1 || true
  done
  "$bin" network rm dnsnet >/dev/null 2>&1 || true
}

# nd_install_macos_activate: records the owned DNS state, then interrupts,
# builds, activates and pins, rolling back on any failure (see the
# transaction notes).
nd_install_macos_activate() {
  _nd_inst_dns_helper snapshot
  _nd_inst_begin_interruption
  nd_install_hold_controller
  nd_install_macos_teardown reinstall
  nd_install_macos_upgrade_runtime
  nd_install_macos_build_images
  nd_install_macos_activate_images
  nd_install_macos_run_stack
  nd_install_wait_ready
  # persist.sh installs the controller, runs the installed copy's self-check
  # and only then loads the start-container agent, whose first run pins every
  # network service: that load is the cutover on macOS. The self-check and the
  # pin below re-assert both (idempotent) before the pin is verified. From
  # here a first install's rollback restores rather than discards (restore
  # leaves a service already at its recorded servers alone).
  ND_INST_PINNED=1
  "$ND_INST_TREE/mac/persist.sh" "$ND_INST_VARIANT"
  nd_install_controller_self_check
  _nd_inst_dns_helper post
  nd_install_verify_pin
  _nd_inst_end_interruption
}

# nd_install_macos_uninstall: removes the stack, its agents, helpers, images
# and controller, and gives back every network service's DNS servers recorded
# before nice-dns.
nd_install_macos_uninstall() {
  local ep sd
  ND_INST_TREE="$ND_INST_SRC"
  nd_install_macos_teardown uninstall
  ep="$(_nd_inst_controller_entry)"
  if [ -n "$ep" ] && [ -f "$ep" ]; then bash "$ep" uninstall || true; fi
  _nd_inst_dns_helper restore
  sd="$(nd_install_state_dir)" && rm -f "${sd:?}/current"
}

# nd_install_macos_build_images: the local builds, in the interruption window.
#
# The macOS exception to "build before interrupting": Apple's `container
# build` starts a buildkit container on the default network, and that wedges
# the running stack's dnsnet within seconds (field evidence 2026-09-25). So on
# macOS the builds run only once the stack's containers are stopped; the
# pulls, bridge fetch and source staging stay in preparation.
nd_install_macos_build_images() {
  local gen="$ND_INST_GEN"
  cd "$ND_INST_TREE" || return 1
  # -- Build local images --
  # --dns 1.1.1.1 because Apple's container builder VM's default DNS forwarding
  # is unreliable when the host network's DNS is censoring or partial; the
  # pi-hole image build does an upstream pihole -g which needs working DNS.
  #
  # No --pull: these builds run while host DNS is pinned to the stopped stack
  # (fail closed), so the builder could not reach a registry through it. The
  # bases were pulled fresh in preparation (nd_install_macos_prepare_images):
  # both Containerfiles build on a floating :latest tag (sureserver/hardened-
  # unbound, pihole/pihole), and without that pull the builder silently reuses
  # whatever base it cached the first time — so a reinstall months later can
  # still produce an image built on a months-old base while reporting success.
  #
  # --no-cache is the other half, and --pull alone is not enough. The builder's
  # layer cache outlives the images themselves: deleting an image and rebuilding
  # still replays cached RUN layers, so their *output* is whatever the first
  # build produced. That matters here because our RUN steps fetch from the
  # network — pihole/Containerfile runs `pihole -g` to download the gravity
  # blocklists and `apk -U upgrade` to apply security updates, and
  # unbound/Containerfile runs post-install.sh. Cached, a reinstall yields an
  # image whose blocklists and package updates are as old as the first install.
  # The cost is a slower install; the alternative is an installer that claims
  # to have built a current image and hasn't.
  #
  # The standard and hardened entrypoints build with the same flags.
  "$CONTAINER_BIN" builder start >/dev/null 2>&1 || true
  if [ "$ND_INST_PIHOLE" = hardened ] && [ -n "${ND_INST_BASE_SIBLING:-}" ]; then
    echo "  • Building the hardened base from $ND_INST_BASE_SIBLING."
    "$CONTAINER_BIN" build "${ND_INST_MACOS_BUILD_FLAGS[@]}" -t "pi-hole-hardened-base:$gen" "$ND_INST_BASE_SIBLING" || return 1
    _nd_inst_record_image hardened-base "pi-hole-hardened-base:$gen" || return 1
  fi
  "$CONTAINER_BIN" build "${ND_INST_MACOS_BUILD_FLAGS[@]}" --build-arg "BASE_IMAGE=unbound-base:$gen" \
    -t "unbound:$gen" unbound/ || return 1
  _nd_inst_record_image unbound "unbound:$gen" || return 1
  if [ "$ND_INST_PIHOLE" = hardened ]; then
    # Apple's builder resolves a local base only by its plain name, hence the
    # build arg (see pihole-hardened/Containerfile). With --pull the builder
    # would fetch this local-only base from a registry (fc5e6ec).
    "$CONTAINER_BIN" build "${ND_INST_MACOS_BUILD_FLAGS[@]}" --build-arg "BASE_IMAGE=pi-hole-hardened-base:$gen" \
      -t "pi-hole:$gen" -f pihole-hardened/Containerfile . || return 1
  else
    "$CONTAINER_BIN" build "${ND_INST_MACOS_BUILD_FLAGS[@]}" --build-arg "BASE_IMAGE=pihole-base:$gen" \
      -t "pi-hole:$gen" pihole/ || return 1
  fi
  _nd_inst_record_image pi-hole "pi-hole:$gen" || return 1

  # Builder VM isn't needed once images are built; reclaim ~2 GB RAM. It will
  # auto-start again on the next `container build`.
  "$CONTAINER_BIN" builder stop >/dev/null 2>&1 || true
}

# nd_install_macos_activate_images: points :latest at this generation.
nd_install_macos_activate_images() {
  local gen="$ND_INST_GEN" name
  for name in unbound pi-hole; do
    "$CONTAINER_BIN" image tag "$name:$gen" "$name:latest" || return 1
  done
  "$CONTAINER_BIN" image tag "tor-${ND_INST_VARIANT}:$gen" "docker.io/sureserver/tor-${ND_INST_VARIANT}:latest" || return 1
  if [ "$ND_INST_PIHOLE" = hardened ]; then
    "$CONTAINER_BIN" image tag "pi-hole-hardened-base:$gen" pi-hole-hardened-base:latest || return 1
  fi
}

# nd_install_macos_run_stack: the network and containers, in IP-allocation order.
nd_install_macos_run_stack() {
  # -- Create network and start containers in IP-allocation order --
  "$CONTAINER_BIN" network create --subnet 172.31.240.248/29 dnsnet >/dev/null

  "$CONTAINER_BIN" run -d --name pi-hole --network dnsnet \
    -c 1 -m 256M \
    -e TZ=Europe/London \
    -e DNS1=172.31.240.251#5335 \
    -e FTLCONF_dns_upstreams=172.31.240.251#5335 \
    -e DISABLE_GITHUB_UPDATES=true \
    pi-hole:latest >/dev/null

  "$CONTAINER_BIN" run -d --name unbound --network dnsnet \
    -c 1 -m 256M \
    unbound:latest >/dev/null

  "$CONTAINER_BIN" run -d --name "tor-${ND_INST_VARIANT}" --network dnsnet \
    -c 1 -m 512M \
    "${ND_INST_BRIDGE_ARGS[@]}" \
    "docker.io/sureserver/tor-${ND_INST_VARIANT}:latest" >/dev/null
}
