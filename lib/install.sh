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
ND_INST_MACOS_BUILD_FLAGS=(--pull --no-cache --dns 1.1.1.1)
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

# _nd_inst_generation_refs: every image ref any recorded generation tagged.
_nd_inst_generation_refs() {
  local sd d
  sd="$(nd_install_state_dir)" || return 0
  [ -d "$sd/generations" ] && [ ! -L "$sd" ] && [ ! -L "$sd/generations" ] || return 0
  for d in "$sd/generations"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    nd_install_manifest_images "$d/prepare.tsv" 2>/dev/null | awk -F '\t' '{ print $2 }'
  done
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
  # network create dnsnet` fails with "netavark: not found".
  sudo apt-get install -yq --no-install-recommends git podman netavark aardvark-dns catatonit

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
  if ! grep -q "^$USER:" /etc/subuid 2>/dev/null; then
    sudo usermod --add-subuids 100000-165535 "$USER"
  fi
  if ! grep -q "^$USER:" /etc/subgid 2>/dev/null; then
    sudo usermod --add-subgids 100000-165535 "$USER"
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
  local gen="$ND_INST_GEN" proxy="docker.io/sureserver/tor-${ND_INST_VARIANT}:latest"
  cd "$ND_INST_TREE" || return 1
  # --dns 1.1.1.1 ensures the pi-hole image build's `pihole -g` precheck
  # always succeeds, even on hosts whose default resolver is partial.
  #
  # --pull=newer re-fetches the FROM base when the registry has a newer one.
  # Both Containerfiles build on a floating :latest tag (sureserver/hardened-
  # unbound, pihole/pihole) and podman build defaults to --pull=missing, which
  # reuses a cached base forever — so a reinstall could keep producing images
  # built on a months-old base. "newer" rather than "always" so an unchanged
  # base costs a digest check instead of a full re-download. (A base that
  # exists only locally, such as the hardened base, still builds: with
  # --pull=newer podman suppresses pull errors when a local image exists.)
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
  fi
  podman build "${ND_INST_LINUX_BUILD_FLAGS[@]}" -t "localhost/unbound:$gen" unbound/ || return 1
  _nd_inst_record_image unbound "localhost/unbound:$gen" || return 1
  if [ "$ND_INST_PIHOLE" = hardened ]; then
    # Hardened-base Pi-hole: pihole-hardened/Containerfile `FROM`s the hardened
    # base and layers on the gravity DB, allowlist seeds, and post-install.sh
    # lockdown. The build context is the repo root.
    podman build "${ND_INST_LINUX_BUILD_FLAGS[@]}" --build-arg "BASE_IMAGE=localhost/pi-hole-hardened-base:$gen" \
      -t "localhost/pi-hole:$gen" -f pihole-hardened/Containerfile . || return 1
  else
    podman build "${ND_INST_LINUX_BUILD_FLAGS[@]}" -t "localhost/pi-hole:$gen" pihole/ || return 1
  fi
  _nd_inst_record_image pi-hole "localhost/pi-hole:$gen" || return 1
  # The proxy is pulled, not built. Its generation tag keeps the image this
  # generation ran for rollback after a later pull moves :latest.
  podman pull "$proxy" || return 1
  podman tag "$proxy" "localhost/tor-${ND_INST_VARIANT}:$gen" || return 1
  _nd_inst_record_image proxy "localhost/tor-${ND_INST_VARIANT}:$gen" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" pulled proxy "$proxy"
}

# Build (or pull-and-tag) the hardened Pi-hole base under its generation tag,
# before the downstream pihole-hardened/Containerfile build.
_nd_inst_linux_hardened_base() {
  local base_img="localhost/pi-hole-hardened-base:$ND_INST_GEN"
  local sibling_repo remote="docker.io/sureserver/pi-hole-hardened:latest"
  sibling_repo="$(cd "$ND_INST_SRC/.." && pwd)/pi-hole-hardened"

  echo "▸ Resolving hardened base image…"
  if [[ -f "$sibling_repo/Dockerfile" && -f "$sibling_repo/post-install.sh" ]]; then
    echo "  • Sibling pi-hole-hardened repo found at $sibling_repo — building locally."
    podman build "${ND_INST_LINUX_BUILD_FLAGS[@]}" -t "$base_img" "$sibling_repo" || return 1
  else
    echo "  • No sibling pi-hole-hardened/ checkout — pulling $remote."
    if podman pull "$remote"; then
      podman tag "$remote" "$base_img" || return 1
      _nd_inst_manifest_row "$ND_INST_MANIFEST" pulled hardened-base "$remote" || return 1
    else
      echo "ERROR: could not build or pull the hardened base." >&2
      echo "  Either:" >&2
      echo "   - clone https://github.com/sureserverman/pi-hole-hardened next to nice-dns/, OR" >&2
      echo "   - wait for sureserver/pi-hole-hardened:latest to publish on Docker Hub." >&2
      return 1
    fi
  fi
  _nd_inst_record_image hardened-base "$base_img"
}

# Reverse every piece of nice-dns state installed by the script (user-mode
# quadlets, containers/network, the system-level custom-dns-deb unit, and a
# stale resolv.conf pointer). System-wide tweaks (PPA pin, sysctl,
# AppArmor, subuid/subgid, cgroup delegation) are left in place — they're
# harmless and may be shared with other Podman workloads.
#
# nd_install_linux_teardown <reinstall|uninstall>: a reinstall keeps every
# image (the previous generation is the rollback target, ARCH-08); uninstall
# removes them as before, generation tags included.
nd_install_linux_teardown() {
  local mode="${1:-reinstall}" svc name ref
  # Remove the resolv.conf pinners before swapping resolv.conf below. The
  # NetworkManager dispatcher hook re-runs custom-dns-deb on any NM event and
  # otherwise writes 127.0.0.1 back in the window before the removals further
  # down (seen 14 s after the swap, with no stack left to answer), so every
  # apt/git/pull in the install then fails to resolve.
  sudo systemctl disable --now custom-dns-deb.service 2>/dev/null || true
  sudo rm -f /etc/NetworkManager/dispatcher.d/90-nice-dns-pin /usr/bin/custom-dns-deb

  # Swap /etc/resolv.conf to public resolvers so apt-get and git still work
  # during install, and so the host keeps DNS after uninstall.
  if grep -qxF 'nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 9.9.9.9\nnameserver 1.1.1.1\nnameserver 1.0.0.1\n' \
      | sudo tee /etc/resolv.conf >/dev/null
  fi

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

  # Containers, network (images only on uninstall)
  podman pod rm -f nice-dns 2>/dev/null || true
  for name in tor-socat tor-haproxy unbound pi-hole; do
    podman rm -f "$name" 2>/dev/null || true
  done
  if [ "$mode" = uninstall ]; then
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
  fi
  podman network rm dnsnet 2>/dev/null || true

  # System-level custom-dns-deb.service
  sudo systemctl disable --now custom-dns-deb.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/custom-dns-deb.service /usr/bin/custom-dns-deb
  sudo rm -f /etc/NetworkManager/conf.d/90-nice-dns.conf \
    /etc/NetworkManager/dispatcher.d/90-nice-dns-pin \
    /etc/sysctl.d/99-nice-dns-disable-ipv6.conf \
    /etc/default/grub.d/99-nice-dns-ipv6.cfg
  sudo systemctl daemon-reload
  sudo systemctl reload NetworkManager 2>/dev/null || true
  sudo sysctl --system >/dev/null 2>&1 || true
  if command -v update-grub >/dev/null 2>&1; then
    sudo update-grub >/dev/null 2>&1 || true
  fi
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
  brew upgrade --formula container
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
# interruption window.
nd_install_macos_prepare_images() {
  local gen="$ND_INST_GEN" proxy="docker.io/sureserver/tor-${ND_INST_VARIANT}:latest"
  local sibling_repo remote="docker.io/sureserver/pi-hole-hardened:latest"
  # The tor proxy is the one image we don't build — it's pulled from Docker Hub.
  # `container run` has no --pull flag and reuses any locally cached copy without
  # consulting the registry, so an install on a host that ever ran nice-dns would
  # silently keep an old image indefinitely. Observed in practice: a host running
  # a four-month-old tor-haproxy (ConfluxEnabled 0, NumPrimaryGuards 2, timeout
  # server 60s) long after those were fixed upstream, which showed up as multi-
  # second cold DNS latency with nothing wrong in this repo. Pull explicitly so
  # every install starts from the current published image; this mirrors what
  # install-deb.sh already does with `podman pull`.
  "$CONTAINER_BIN" image pull "$proxy" || return 1
  "$CONTAINER_BIN" image tag "$proxy" "tor-${ND_INST_VARIANT}:$gen" || return 1
  _nd_inst_record_image proxy "tor-${ND_INST_VARIANT}:$gen" || return 1
  _nd_inst_manifest_row "$ND_INST_MANIFEST" pulled proxy "$proxy" || return 1

  [ "$ND_INST_PIHOLE" = hardened ] || return 0
  # The sibling pi-hole-hardened checkout sits next to the tree this install
  # was started from (never next to the private copy).
  sibling_repo="$(cd "$ND_INST_SRC/.." && pwd)/pi-hole-hardened"
  echo "▸ Resolving hardened base image…"
  if [[ -f "$sibling_repo/Dockerfile" && -f "$sibling_repo/post-install.sh" ]]; then
    echo "  • Sibling pi-hole-hardened repo found at $sibling_repo — building it after the stack stops."
    ND_INST_BASE_SIBLING="$sibling_repo"
    return 0
  fi
  echo "  • No sibling pi-hole-hardened/ checkout — pulling $remote."
  if "$CONTAINER_BIN" image pull "$remote"; then
    "$CONTAINER_BIN" image tag "$remote" "pi-hole-hardened-base:$gen" || return 1
    _nd_inst_record_image hardened-base "pi-hole-hardened-base:$gen" || return 1
    _nd_inst_manifest_row "$ND_INST_MANIFEST" pulled hardened-base "$remote" || return 1
    return 0
  fi
  echo "ERROR: could not build or pull the hardened base." >&2
  echo "  Either:" >&2
  echo "   - clone https://github.com/sureserverman/pi-hole-hardened next to nice-dns/, OR" >&2
  echo "   - wait for sureserver/pi-hole-hardened:latest to publish on Docker Hub." >&2
  return 1
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
  sudo rm -f /etc/sudoers.d/start-container \
             /usr/local/sbin/start-container.sh \
             /usr/local/sbin/start-container-root.sh \
             /usr/local/sbin/nice-dns-bridge-eval.sh

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

  # Restore DNS to DHCP defaults on every active network service.
  networksetup -listallnetworkservices 2>/dev/null | sed '1d' \
    | { grep -v '^\*' || true; } \
    | while read -r svc; do
        sudo networksetup -setdnsservers "$svc" Empty 2>/dev/null || true
      done
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
  # --pull re-fetches the FROM base on every install. Both Containerfiles build
  # on a floating :latest tag (sureserver/hardened-unbound, pihole/pihole), and
  # without this the builder silently reuses whatever base it cached the first
  # time — so a reinstall months later can still produce an image built on a
  # months-old base while reporting success.
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
  "$CONTAINER_BIN" build "${ND_INST_MACOS_BUILD_FLAGS[@]}" -t "unbound:$gen" unbound/ || return 1
  _nd_inst_record_image unbound "unbound:$gen" || return 1
  if [ "$ND_INST_PIHOLE" = hardened ]; then
    # Apple's builder resolves a local base only by its plain name, hence the
    # build arg (see pihole-hardened/Containerfile).
    "$CONTAINER_BIN" build "${ND_INST_MACOS_BUILD_FLAGS[@]}" --build-arg "BASE_IMAGE=pi-hole-hardened-base:$gen" \
      -t "pi-hole:$gen" -f pihole-hardened/Containerfile . || return 1
  else
    "$CONTAINER_BIN" build "${ND_INST_MACOS_BUILD_FLAGS[@]}" -t "pi-hole:$gen" pihole/ || return 1
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
