#!/usr/bin/env bash
# =============================================================================
# setup-valhalla-pi.sh
#
# One-shot installer for a fully offline Valhalla routing stack on a
# Raspberry Pi (or any 64-bit Debian-family machine). No containers: everything
# runs natively as systemd services under one directory.
#
#   What you get, all behind ONE web port (default 8100):
#     - Valhalla routing engine          (turn-by-turn routes, isochrones)
#     - Vector map tiles with POIs       (built from OpenStreetMap by planetiler)
#     - Photon place/address/POI search  (optional, prebuilt country index)
#     - The official Valhalla web app    (patched to use only the local services)
#
#   Quick start (run as root):
#     sudo bash setup-valhalla-pi.sh --region north-america/us/illinois
#
#   The region is a Geofabrik path: browse https://download.geofabrik.de and
#   take the part of the URL between the host name and "-latest.osm.pbf".
#   Examples: europe/andorra   north-america/us/texas   europe/germany/berlin
#
#   It is safe to re-run: finished steps are skipped, interrupted downloads
#   resume. It does not touch other web servers or services on the machine:
#   internal services bind to 127.0.0.1 only and every port is checked first.
#
#   Requirements: 64-bit OS (arm64 or amd64), Debian 12+/Raspberry Pi OS,
#   4 GB RAM minimum (8 GB recommended), and an SSD is strongly recommended.
#   A Pi can build a city, state or small country. Do NOT try a continent.
# =============================================================================
set -Eeuo pipefail

# ---- pinned component versions ----------------------------------------------
PYVALHALLA_VERSION="3.9.1"
PLANETILER_VERSION="0.10.2"
PMTILES_VERSION="1.31.2"
PHOTON_VERSION="1.3.0"
PHOTON_DB_VERSION="1.0"
NODE_MAJOR="24"
WEB_APP_REPO="https://github.com/valhalla/web-app.git"
WEB_APP_COMMIT="5bc5b9336f1e7ac054b0f4e0da4de166ea91614e"
PHOTON_MIRROR="https://download1.graphhopper.com/public"
GEOFABRIK="https://download.geofabrik.de"

# ---- defaults (override with flags) -----------------------------------------
REGION=""
SEARCH="auto"
DATA_DIR="/opt/valhalla-stack"
WEB_PORT=""
CENTER=""
ASSUME_YES=0
NO_START=0
PREBUILT=""
PREBUILT_PMTILES=""
ACTION="install"
SERVICE_USER="valhalla"
UNITS=(valhalla-routing valhalla-tiles valhalla-photon)
NGINX_SITE="valhalla-stack"

usage() {
  cat <<'USAGE'
Usage: sudo bash setup-valhalla-pi.sh --region <geofabrik-path> [options]

  --region PATH     Geofabrik region, e.g. north-america/us/illinois (required
                    on the first run, remembered afterwards)
  --search PATH     Photon search index to download: "auto" (default, derived
                    from the region), "none" to skip search, or an explicit
                    path such as north-america/usa or europe/germany
  --data-dir DIR    Where everything lives (default /opt/valhalla-stack).
                    Point this at an SSD if you have one.
  --web-port N      Port for the web interface (default 8100, or the next
                    free port if that one is taken)
  --center LAT,LON  Initial map position (default: middle of the region)
  --yes             Do not ask for confirmation
  --no-start        Install everything but do not enable or start services
  --prebuilt SRC    Skip the builds and use routing and map tiles made on a
                    bigger machine. SRC is a folder holding valhalla_tiles.tar
                    and one .pmtiles file, or a URL serving valhalla_tiles.tar
                    and basemap.pmtiles. Use with --search (e.g. north-america).
  --uninstall       Stop and remove the services and the nginx site
  -h, --help        Show this help
USAGE
}

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local code=$? line=$1
  printf '\n\033[1;31mSetup stopped (exit %s) near line %s.\033[0m\n' "$code" "$line" >&2
  echo "Fix the problem above and run the same command again: finished steps are skipped." >&2
  exit "$code"
}
trap 'on_error $LINENO' ERR

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local answer=""
  if [ -r /dev/tty ]; then
    read -r -p "$1 [y/N] " answer </dev/tty || true
  fi
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --region)    REGION="${2:?--region needs a value}"; shift 2 ;;
      --search)    SEARCH="${2:?--search needs a value}"; shift 2 ;;
      --data-dir)  DATA_DIR="${2:?--data-dir needs a value}"; shift 2 ;;
      --web-port)  WEB_PORT="${2:?--web-port needs a value}"; shift 2 ;;
      --center)    CENTER="${2:?--center needs a value}"; shift 2 ;;
      --yes|-y)    ASSUME_YES=1; shift ;;
      --no-start)  NO_START=1; shift ;;
      --prebuilt)  PREBUILT="${2:?--prebuilt needs a folder or URL}"; shift 2 ;;
      --uninstall) ACTION="uninstall"; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) usage; die "Unknown option: $1" ;;
    esac
  done
  REGION="${REGION#/}"; REGION="${REGION%/}"; REGION="${REGION%-latest.osm.pbf}"
  DATA_DIR="${DATA_DIR%/}"
}

# ---- platform ----------------------------------------------------------------
detect_platform() {
  command -v apt-get >/dev/null || die "This script needs a Debian-family system (apt-get not found)."
  case "$(dpkg --print-architecture)" in
    arm64) ARCH_GO="arm64";  ARCH_NODE="arm64"; ARCH_UV="aarch64"; ARCH_JDK="aarch64" ;;
    amd64) ARCH_GO="x86_64"; ARCH_NODE="x64";   ARCH_UV="x86_64";  ARCH_JDK="x64" ;;
    *) die "Unsupported architecture '$(dpkg --print-architecture)'. A 64-bit OS is required (on a Pi: install the 64-bit Raspberry Pi OS)." ;;
  esac
  RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  CPUS=$(nproc)
}

remote_size() { # prints the Content-Length of a URL, or nothing if it does not exist
  { curl -fsIL --max-time 30 "$1" 2>/dev/null || true; } | awk '/^HTTP/ {status=$2; size=""} tolower($1)=="content-length:" {size=$2} END {if (status+0 < 200 || status+0 >= 400) size=""; gsub(/\r/,"",size); print size}'
}

port_in_use() {
  # Capture first: with pipefail, an early-exiting grep could make a busy port look free.
  local listening
  listening=$(ss -Htln 2>/dev/null | awk '{print $4}' | sed 's/.*://' || true)
  grep -qx "$1" <<<"$listening"
}

pick_port() { # first free TCP port at or above $1, skipping ports already chosen ($2...)
  local port=$1; shift
  while port_in_use "$port" || [[ " $* " == *" $port "* ]]; do port=$((port + 1)); done
  echo "$port"
}

derive_search() {
  case "$REGION" in
    north-america/us|north-america/us/*) echo "north-america/usa" ;;
    */*) echo "$REGION" | cut -d/ -f1-2 ;;
    *)   echo "$REGION" ;;
  esac
}

photon_url() { echo "$PHOTON_MIRROR/$1/photon-db-${1##*/}-${PHOTON_DB_VERSION}-latest.tar.bz2"; }

# ---- uninstall ---------------------------------------------------------------
uninstall() {
  log "Removing services"
  for unit in "${UNITS[@]}"; do
    systemctl disable --now "$unit.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/$unit.service"
  done
  systemctl daemon-reload 2>/dev/null || true
  rm -f "/etc/nginx/sites-enabled/$NGINX_SITE" "/etc/nginx/sites-available/$NGINX_SITE"
  if command -v nginx >/dev/null && nginx -t 2>/dev/null; then systemctl reload nginx 2>/dev/null || true; fi
  info "Services and the nginx site are removed. Installed packages (nginx, java) were left alone."
  if [ -d "$DATA_DIR" ]; then
    if confirm "Also delete ALL data in $DATA_DIR (map, routing and search data)?"; then
      rm -rf "$DATA_DIR"
      userdel "$SERVICE_USER" 2>/dev/null || true
      info "Deleted $DATA_DIR."
    else
      info "Kept $DATA_DIR."
    fi
  fi
}

# ---- planning ----------------------------------------------------------------
plan() {
  command -v curl >/dev/null || { apt-get update -qq; apt-get install -y -qq curl ca-certificates; }

  STATE_FILE="$DATA_DIR/stack.env"
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    if [ -n "$REGION" ] && [ "$REGION" != "$SAVED_REGION" ]; then
      die "$DATA_DIR already holds region '$SAVED_REGION'. Run with --uninstall first, or use a different --data-dir."
    fi
    REGION="$SAVED_REGION"
    if [ "$SEARCH" = "auto" ]; then SEARCH="$SAVED_SEARCH"; fi
    if [ -z "$WEB_PORT" ]; then WEB_PORT="$SAVED_WEB_PORT"; fi
    if [ -z "$PREBUILT" ]; then PREBUILT="${SAVED_PREBUILT:-}"; fi
  fi

  PBF_BYTES=0
  PREBUILT_MB=0
  if [ -n "$PREBUILT" ]; then
    # Prebuilt mode: routing and map tiles were built on a bigger machine.
    PREBUILT="${PREBUILT%/}"
    if [ "$SEARCH" = "auto" ] && [ -z "$REGION" ]; then
      die "With --prebuilt, say which search index to use: --search north-america (or a country path, or none)."
    fi
    REGION="${REGION:-prebuilt}"
    case "$( [ -f "$DATA_DIR/valhalla/.build-complete" ] && echo done || echo "$PREBUILT" )" in
      done) ;; # already installed on an earlier run: the source is no longer needed
      http://*|https://*)
        local routing_bytes tiles_bytes
        routing_bytes=$(remote_size "$PREBUILT/valhalla_tiles.tar")
        tiles_bytes=$(remote_size "$PREBUILT/basemap.pmtiles")
        [ -n "$routing_bytes" ] || die "Not found: $PREBUILT/valhalla_tiles.tar"
        [ -n "$tiles_bytes" ] || die "Not found: $PREBUILT/basemap.pmtiles"
        PREBUILT_MB=$(((routing_bytes + tiles_bytes) / 1000000))
        ;;
      *)
        [ -f "$PREBUILT/valhalla_tiles.tar" ] || die "Not found: $PREBUILT/valhalla_tiles.tar"
        PREBUILT_PMTILES=$(find "$PREBUILT" -maxdepth 1 -name '*.pmtiles' | sort)
        [ -n "$PREBUILT_PMTILES" ] || die "No .pmtiles file found in $PREBUILT"
        [ "$(wc -l <<<"$PREBUILT_PMTILES")" = 1 ] || die "More than one .pmtiles file in $PREBUILT: keep only the one to use."
        # no extra space is needed when the files are on the same disk (they are hard-linked)
        if [ "$(stat -c %d "$PREBUILT")" != "$(mkdir -p "$DATA_DIR" && stat -c %d "$DATA_DIR")" ]; then
          PREBUILT_MB=$(du -cm "$PREBUILT/valhalla_tiles.tar" "$PREBUILT_PMTILES" | awk 'END {print $1}')
        fi
        ;;
    esac
  else
    [ -n "$REGION" ] || { usage; die "--region is required (or --prebuilt to use data built elsewhere)."; }
    PBF_URL="$GEOFABRIK/$REGION-latest.osm.pbf"
    PBF_BYTES=$(remote_size "$PBF_URL")
    [ -n "$PBF_BYTES" ] || die "Region '$REGION' was not found at $PBF_URL. Check the path on https://download.geofabrik.de"
  fi

  if [ "$SEARCH" = "auto" ]; then SEARCH=$(derive_search); fi
  PHOTON_BYTES=0
  if [ "$SEARCH" != "none" ]; then
    PHOTON_BYTES=$(remote_size "$(photon_url "$SEARCH")")
    if [ -z "$PHOTON_BYTES" ]; then
      warn "No prebuilt Photon search index found for '$SEARCH' ($(photon_url "$SEARCH"))."
      warn "Continuing WITHOUT search. Browse $PHOTON_MIRROR and re-run with --search <path> to add it."
      SEARCH="none"; PHOTON_BYTES=0
    fi
  fi

  local pbf_mb=$((PBF_BYTES / 1000000)) photon_mb=$((PHOTON_BYTES / 1000000))
  # rough peak: OSM file + routing build + tile build temp files; search archive + extracted index
  NEED_MB=$((pbf_mb * 12 + PREBUILT_MB + photon_mb * 27 / 10 + 4000))
  mkdir -p "$DATA_DIR"
  FREE_MB=$(df -Pm "$DATA_DIR" | awk 'NR==2 {print $4}')

  log "Plan"
  if [ -n "$PREBUILT" ]; then info "Prebuilt data:   $PREBUILT  (nothing is built on this machine)"
  else info "Region:          $REGION  (OSM extract: ${pbf_mb} MB)"; fi
  if [ "$SEARCH" = "none" ]; then info "Search:          disabled"
  else info "Search index:    $SEARCH  (download: ${photon_mb} MB)"; fi
  info "Install dir:     $DATA_DIR"
  info "Machine:         $(dpkg --print-architecture), ${CPUS} cores, ${RAM_MB} MB RAM"
  info "Disk:            about ${NEED_MB} MB needed at peak, ${FREE_MB} MB free"

  [ "$RAM_MB" -ge 3500 ] || warn "Less than 4 GB RAM: builds may be killed and search will be slow. Use a small region."
  if [ "$pbf_mb" -gt 1500 ] && [ "$RAM_MB" -lt 15000 ]; then
    warn "This region is large (${pbf_mb} MB) for ${RAM_MB} MB of RAM. The routing build may run out of memory or take many hours."
  fi
  if [ "$SEARCH" != "none" ] && [ "$RAM_MB" -lt 7000 ]; then
    warn "Photon search wants about 2 GB RAM of its own. On this machine consider --search none."
  fi
  if [ "$FREE_MB" -lt "$NEED_MB" ]; then
    warn "Probably not enough free disk space in $DATA_DIR."
  fi
  confirm "Proceed with the installation?" || die "Cancelled."
}

# ---- step: packages ------------------------------------------------------------
java_major() {
  local banner
  banner=$("$1" -version 2>&1 || true)
  awk -F'"' '/version/ && !seen {split($2, v, "."); print v[1]; seen=1}' <<<"$banner"
}

install_packages() {
  log "Installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git unzip xz-utils lbzip2 iproute2 python3 python3-venv >/dev/null

  if ! dpkg -s nginx >/dev/null 2>&1; then
    # Fresh nginx: keep apt from starting it on port 80 (something else, such as
    # a kiwix server, may already live there) and drop its default site.
    local policy_created=0
    if [ ! -e /usr/sbin/policy-rc.d ]; then
      printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d; policy_created=1
    fi
    local nginx_ok=1
    apt-get install -y -qq nginx >/dev/null || nginx_ok=0
    if [ "$policy_created" = 1 ]; then rm -f /usr/sbin/policy-rc.d; fi
    [ "$nginx_ok" = 1 ] || die "Could not install nginx."
    rm -f /etc/nginx/sites-enabled/default
    info "Installed nginx (its default port-80 site is disabled; only the Valhalla site is served)."
  else
    info "nginx is already installed: adding one extra site, existing sites are untouched."
  fi

  # Java 21+ is needed by planetiler and Photon.
  JAVA=""
  if command -v java >/dev/null && [ "$(java_major java)" -ge 21 ] 2>/dev/null; then
    JAVA=$(command -v java)
  else
    for pkg in openjdk-21-jre-headless openjdk-25-jre-headless; do
      local candidate
      candidate=$(apt-cache policy "$pkg" 2>/dev/null || true)
      if grep -q 'Candidate: [0-9]' <<<"$candidate"; then
        apt-get install -y -qq "$pkg" >/dev/null
        local jvm_dir
        jvm_dir=$(ls -d /usr/lib/jvm/java-"$(echo "$pkg" | cut -d- -f2)"-openjdk-* 2>/dev/null | head -1 || true)
        if [ -n "$jvm_dir" ]; then JAVA="$jvm_dir/bin/java"; fi
        break
      fi
    done
  fi
  if [ -z "$JAVA" ] || [ ! -x "$JAVA" ]; then
    if [ ! -x "$DATA_DIR/runtime/jre/bin/java" ]; then
      info "No Java 21+ package available: downloading the Eclipse Temurin 21 runtime"
      mkdir -p "$DATA_DIR/runtime/jre"
      curl -fL --retry 5 -o "$DATA_DIR/build/jre.tar.gz" \
        "https://api.adoptium.net/v3/binary/latest/21/ga/linux/$ARCH_JDK/jre/hotspot/normal/eclipse"
      tar -xzf "$DATA_DIR/build/jre.tar.gz" -C "$DATA_DIR/runtime/jre" --strip-components=1
      rm -f "$DATA_DIR/build/jre.tar.gz"
    fi
    JAVA="$DATA_DIR/runtime/jre/bin/java"
  fi
  info "Java: $JAVA (version $(java_major "$JAVA"))"
}

# ---- step: ports and saved state ---------------------------------------------
choose_ports() {
  if [ -n "${SAVED_VALHALLA_PORT:-}" ]; then
    VALHALLA_PORT=$SAVED_VALHALLA_PORT; TILES_PORT=$SAVED_TILES_PORT; PHOTON_PORT=$SAVED_PHOTON_PORT
    [ -n "$WEB_PORT" ] || WEB_PORT=$SAVED_WEB_PORT
  else
    local wanted=${WEB_PORT:-8100}
    WEB_PORT=$(pick_port "$wanted")
    [ "$WEB_PORT" = "$wanted" ] || info "Port $wanted is in use, the web interface will use $WEB_PORT instead."
    VALHALLA_PORT=$(pick_port 8002 "$WEB_PORT")
    TILES_PORT=$(pick_port 8003 "$WEB_PORT" "$VALHALLA_PORT")
    PHOTON_PORT=$(pick_port 2322 "$WEB_PORT" "$VALHALLA_PORT" "$TILES_PORT")
  fi
  cat > "$STATE_FILE" <<EOF
SAVED_REGION="$REGION"
SAVED_PREBUILT="$PREBUILT"
SAVED_SEARCH="$SEARCH"
SAVED_WEB_PORT="$WEB_PORT"
SAVED_VALHALLA_PORT="$VALHALLA_PORT"
SAVED_TILES_PORT="$TILES_PORT"
SAVED_PHOTON_PORT="$PHOTON_PORT"
EOF
  info "Ports: web $WEB_PORT (public); routing $VALHALLA_PORT, tiles $TILES_PORT, search $PHOTON_PORT (127.0.0.1 only)"
}

# ---- step: downloads -----------------------------------------------------------
fetch() { # fetch URL DEST  (resumable)
  curl -fL --retry 5 --retry-delay 5 -C - -o "$2" "$1"
}

place_file() { # hard-link when on the same disk (instant, no extra space), otherwise copy
  ln -f "$1" "$2" 2>/dev/null || cp "$1" "$2"
}

install_prebuilt() {
  local routing="$DATA_DIR/valhalla/valhalla_tiles.tar" tiles="$DATA_DIR/tiles/basemap.pmtiles"
  if [ -f "$DATA_DIR/valhalla/.build-complete" ] && [ -s "$routing" ] && [ -s "$tiles" ]; then
    info "Prebuilt routing and map tiles already in place."; return
  fi
  log "Installing prebuilt routing and map tiles from $PREBUILT"
  case "$PREBUILT" in
    http://*|https://*)
      if [ ! -s "$routing" ]; then fetch "$PREBUILT/valhalla_tiles.tar" "$routing.part"; mv "$routing.part" "$routing"; fi
      if [ ! -s "$tiles" ]; then fetch "$PREBUILT/basemap.pmtiles" "$tiles.part"; mv "$tiles.part" "$tiles"; fi
      ;;
    *)
      place_file "$PREBUILT/valhalla_tiles.tar" "$routing"
      place_file "$PREBUILT_PMTILES" "$tiles"
      ;;
  esac
  touch "$DATA_DIR/valhalla/.build-complete"
}

download_osm() {
  PBF="$DATA_DIR/osm/region.osm.pbf"
  if [ -f "$PBF" ] && [ "$(stat -c %s "$PBF")" = "$PBF_BYTES" ]; then info "OSM extract already downloaded."; return; fi
  log "Downloading OpenStreetMap extract ($((PBF_BYTES / 1000000)) MB)"
  fetch "$PBF_URL" "$PBF" || { rm -f "$PBF"; fetch "$PBF_URL" "$PBF"; }
  [ "$(stat -c %s "$PBF")" = "$PBF_BYTES" ] || { rm -f "$PBF"; die "OSM download is incomplete or the file changed upstream. Run the script again."; }
}

install_tools() {
  log "Installing Valhalla, planetiler, pmtiles and Photon"
  local bin="$DATA_DIR/bin" rt="$DATA_DIR/runtime"

  if [ ! -x "$bin/pmtiles" ]; then
    curl -fL --retry 5 -o "$DATA_DIR/build/pmtiles.tar.gz" \
      "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_Linux_${ARCH_GO}.tar.gz"
    tar -xzf "$DATA_DIR/build/pmtiles.tar.gz" -C "$bin" pmtiles
    rm -f "$DATA_DIR/build/pmtiles.tar.gz"
  fi
  [ -f "$bin/planetiler.jar" ] || { fetch "https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/planetiler.jar" "$bin/planetiler.jar.part" && mv "$bin/planetiler.jar.part" "$bin/planetiler.jar"; }
  if [ "$SEARCH" != "none" ] && [ ! -f "$bin/photon.jar" ]; then
    fetch "https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar" "$bin/photon.jar.part" && mv "$bin/photon.jar.part" "$bin/photon.jar"
  fi

  # Valhalla ships prebuilt binaries inside its Python wheel (needs Python 3.12+).
  if [ ! -x "$rt/venv/bin/valhalla_service" ]; then
    rm -rf "$rt/venv"
    if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)'; then
      python3 -m venv "$rt/venv"
      "$rt/venv/bin/pip" install --quiet --disable-pip-version-check "pyvalhalla==${PYVALHALLA_VERSION}"
    else
      info "System Python is older than 3.12: using a private Python 3.12 (via uv)"
      curl -fL --retry 5 -o "$DATA_DIR/build/uv.tar.gz" \
        "https://github.com/astral-sh/uv/releases/latest/download/uv-${ARCH_UV}-unknown-linux-gnu.tar.gz"
      tar -xzf "$DATA_DIR/build/uv.tar.gz" -C "$DATA_DIR/build" --strip-components=1
      export UV_PYTHON_INSTALL_DIR="$rt/python" UV_CACHE_DIR="$DATA_DIR/build/uv-cache"
      "$DATA_DIR/build/uv" venv --quiet --python 3.12 "$rt/venv"
      "$DATA_DIR/build/uv" pip install --quiet --python "$rt/venv/bin/python" "pyvalhalla==${PYVALHALLA_VERSION}"
      rm -rf "$DATA_DIR/build/uv" "$DATA_DIR/build/uvx" "$DATA_DIR/build/uv.tar.gz" "$DATA_DIR/build/uv-cache"
    fi
  fi
  VALHALLA_BIN=$("$rt/venv/bin/python" -m valhalla print_bin_path)
  [ -x "$VALHALLA_BIN/valhalla_service" ] || die "Valhalla binaries not found in $VALHALLA_BIN"
  info "Valhalla $PYVALHALLA_VERSION binaries: $VALHALLA_BIN"
}

# ---- step: routing tiles ---------------------------------------------------------
build_routing() {
  local dir="$DATA_DIR/valhalla" venv="$DATA_DIR/runtime/venv"
  VALHALLA_CONFIG="$dir/valhalla.json"
  if [ ! -f "$VALHALLA_CONFIG" ]; then
    PATH="$venv/bin:$PATH" valhalla_build_config \
      --mjolnir-tile-dir "$dir/valhalla_tiles" \
      --mjolnir-tile-extract "$dir/valhalla_tiles.tar" \
      --mjolnir-admin "$dir/admins.sqlite" \
      --mjolnir-timezone "$dir/timezones.sqlite" \
      --httpd-service-listen "tcp://127.0.0.1:${VALHALLA_PORT}" > "$VALHALLA_CONFIG.part"
    mv "$VALHALLA_CONFIG.part" "$VALHALLA_CONFIG"
  fi
  if [ -f "$dir/valhalla_tiles.tar" ] && [ -f "$dir/.build-complete" ]; then info "Routing tiles already built."; return; fi

  log "Building Valhalla routing tiles (the slow part: minutes for a city, hours for a big state)"
  rm -rf "$dir/valhalla_tiles" "$dir/valhalla_tiles.tar" "$dir/admins.sqlite"
  mkdir -p "$dir/valhalla_tiles"
  info "Note: 'admin_access ... Ignore if not using a planet extract' errors below are normal for a regional extract."
  "$VALHALLA_BIN/valhalla_build_admins" -c "$VALHALLA_CONFIG" "$PBF" \
    || warn "Admin boundary build failed: routing still works, but without per-country driving rules."
  "$VALHALLA_BIN/valhalla_build_tiles" -c "$VALHALLA_CONFIG" "$PBF"
  PATH="$venv/bin:$PATH" valhalla_build_extract -c "$VALHALLA_CONFIG" -v
  [ -s "$dir/valhalla_tiles.tar" ] || die "Routing tile archive was not created."
  rm -rf "$dir/valhalla_tiles"
  touch "$dir/.build-complete"
  info "Routing tiles: $(du -h "$dir/valhalla_tiles.tar" | cut -f1)"
}

# ---- step: map tiles ---------------------------------------------------------------
build_map_tiles() {
  local out="$DATA_DIR/tiles/basemap.pmtiles" work="$DATA_DIR/build/planetiler"
  if [ -s "$out" ]; then info "Map tiles already built."; return; fi
  log "Building vector map tiles with planetiler"
  local heap_mb=$((RAM_MB / 2)); [ "$heap_mb" -lt 1024 ] && heap_mb=1024
  mkdir -p "$work"
  ( cd "$work" && "$JAVA" "-Xmx${heap_mb}m" -jar "$DATA_DIR/bin/planetiler.jar" \
      --osm-path="$PBF" --download --force \
      --download-dir="$work/sources" --tmpdir="$work/tmp" \
      --output="$DATA_DIR/tiles/basemap.partial.pmtiles" )
  mv "$DATA_DIR/tiles/basemap.partial.pmtiles" "$out"
  rm -rf "$work"
  info "Map tiles: $(du -h "$out" | cut -f1)"
}

# ---- step: map style, fonts, sprites (all served locally) ---------------------------
install_map_assets() {
  local map="$DATA_DIR/web/map" tmp="$DATA_DIR/build/style"
  if [ -f "$map/style.json" ] && [ -f "$map/sprites/ofm.png" ] && [ -d "$map/fonts/Noto Sans Regular" ]; then
    info "Map style, fonts and sprites already installed."; return
  fi
  log "Installing map style, fonts and sprites"
  mkdir -p "$tmp" "$map/sprites" "$map/fonts"
  curl -fsL --retry 5 -o "$tmp/liberty.json" "https://tiles.openfreemap.org/styles/liberty"
  local sprite
  sprite=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sprite"])' "$tmp/liberty.json")
  for suffix in .json .png @2x.json @2x.png; do
    curl -fsL --retry 5 -o "$map/sprites/ofm$suffix" "$sprite$suffix"
  done
  curl -fL --retry 5 -o "$tmp/fonts.zip" "https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip"
  python3 - "$tmp/liberty.json" "$map/style.json" "$tmp/fonts.txt" <<'PY'
import json, sys
src, out, fonts_out = sys.argv[1:4]
style = json.load(open(src, encoding="utf-8"))
style["name"] = "Local (offline)"
style["sources"] = {
    "openmaptiles": {
        "type": "vector",
        # __ORIGIN__ is replaced by nginx with the address the browser used
        "tiles": ["__ORIGIN__/tiles/basemap/{z}/{x}/{y}.mvt"],
        "minzoom": 0,
        "maxzoom": 14,
        "attribution": '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors, © <a href="https://openmaptiles.org/">OpenMapTiles</a>',
    }
}
style["sprite"] = "__ORIGIN__/map/sprites/ofm"
style["glyphs"] = "__ORIGIN__/map/fonts/{fontstack}/{range}.pbf"
# keep only layers drawn from the tiles we host (drops the online relief raster)
style["layers"] = [l for l in style["layers"] if l.get("source") in (None, "openmaptiles")]
fonts = set()
def collect(value):
    if isinstance(value, str):
        fonts.add(value)
    elif isinstance(value, list):
        for item in value:
            collect(item)
    elif isinstance(value, dict):
        for item in value.values():
            collect(item)
for layer in style["layers"]:
    collect(layer.get("layout", {}).get("text-font"))
json.dump(style, open(out, "w", encoding="utf-8"))
open(fonts_out, "w").write("".join(font + "\n" for font in sorted(fonts)))
PY
  unzip -q -o "$tmp/fonts.zip" -d "$tmp/fonts"
  while IFS= read -r font; do
    if [ -d "$tmp/fonts/$font" ]; then cp -r "$tmp/fonts/$font" "$map/fonts/"; fi
  done < "$tmp/fonts.txt"
  [ -d "$map/fonts/Noto Sans Regular" ] || die "Map fonts were not installed correctly."
  rm -rf "$tmp"
}

# ---- step: search index --------------------------------------------------------------
install_search_index() {
  [ "$SEARCH" = "none" ] && return
  local dir="$DATA_DIR/photon"
  if [ -f "$dir/.index-ready" ]; then info "Search index already installed."; return; fi
  log "Downloading the Photon search index for $SEARCH ($((PHOTON_BYTES / 1000000)) MB)"
  fetch "$(photon_url "$SEARCH")" "$dir/photon-db.tar.bz2"
  log "Unpacking the search index (this takes a while on a Pi)"
  rm -rf "$dir/photon_data"
  lbzip2 -dc "$dir/photon-db.tar.bz2" | tar -x -C "$dir"
  [ -d "$dir/photon_data" ] || die "The search index archive did not contain photon_data."
  rm -f "$dir/photon-db.tar.bz2"
  touch "$dir/.index-ready"
}

# ---- step: web app -----------------------------------------------------------------------
region_center() { # "lat,lon" from the bounds stored in the PMTiles header
  python3 - "$DATA_DIR/tiles/basemap.pmtiles" <<'PY'
import struct, sys
try:
    header = open(sys.argv[1], "rb").read(127)
    min_lon, min_lat, max_lon, max_lat = (v / 1e7 for v in struct.unpack_from("<iiii", header, 102))
    if header[:7] != b"PMTiles" or max_lon - min_lon > 300:
        raise ValueError("no usable bounds")
    print(f"{(min_lat + max_lat) / 2:.5f},{(min_lon + max_lon) / 2:.5f}")
except Exception:
    print("")
PY
}

write_web_patch() {
  cat > "$1" <<'WEB_APP_PATCH_EOF'
diff --git a/src/components/map/constants.ts b/src/components/map/constants.ts
index 86d6856..d13a8db 100644
--- a/src/components/map/constants.ts
+++ b/src/components/map/constants.ts
@@ -22,6 +22,12 @@ export const CUSTOM_STYLE_STORAGE_KEY = 'customMapStyle';
 const assetPath = (path: string) => `${import.meta.env.BASE_URL}${path}`;
 
 export const MAP_STYLES = [
+  {
+    // Self-hosted vector tiles, fonts and sprites (served by the local nginx).
+    id: 'local',
+    label: 'Local (offline)',
+    style: '/map/style.json',
+  },
   {
     id: 'shortbread',
     label: 'Shortbread',
diff --git a/src/components/map/index.tsx b/src/components/map/index.tsx
index afac3c5..891300b 100644
--- a/src/components/map/index.tsx
+++ b/src/components/map/index.tsx
@@ -156,7 +156,7 @@ export const MapComponent = () => {
 
   const resolvedMapStyle = useMemo(() => {
     if (currentMapStyle === 'custom') {
-      return customStyleData ?? getMapStyleUrl('shortbread');
+      return customStyleData ?? getMapStyleUrl(DEFAULT_MAP_STYLE_ID);
     }
     return getMapStyleUrl(currentMapStyle);
   }, [
diff --git a/src/utils/base-url.ts b/src/utils/base-url.ts
index 48385a7..8c89cc3 100644
--- a/src/utils/base-url.ts
+++ b/src/utils/base-url.ts
@@ -2,9 +2,16 @@ import { z } from 'zod';
 
 const BASE_URL_STORAGE_KEY = 'valhalla_base_url';
 
-const DEFAULT_BASE_URL =
+// Local build: a VITE_VALHALLA_URL starting with "/" is resolved against the
+// origin the app is served from, so it works under any hostname or proxy.
+const ENV_BASE_URL: string =
   import.meta.env.VITE_VALHALLA_URL || 'https://valhalla1.openstreetmap.de';
 
+const DEFAULT_BASE_URL =
+  ENV_BASE_URL.startsWith('/') && typeof window !== 'undefined'
+    ? `${window.location.origin}${ENV_BASE_URL}`
+    : ENV_BASE_URL;
+
 const baseUrlSchema = z
   .string()
   .trim()
diff --git a/src/utils/nominatim.ts b/src/utils/nominatim.ts
index 846a34d..d4523cb 100644
--- a/src/utils/nominatim.ts
+++ b/src/utils/nominatim.ts
@@ -1,27 +1,94 @@
 import type { NominationResponse } from '@/components/types';
 
-export const NOMINATIM_URL = `${import.meta.env.VITE_NOMINATIM_URL}/search`;
-export const NOMINATIME_URL_REVERSE = `${import.meta.env.VITE_NOMINATIM_URL}/reverse`;
+// Local build: geocoding is served by a self-hosted Photon instance instead of
+// Nominatim. Photon answers in GeoJSON, so the responses are mapped into the
+// Nominatim shape the rest of the app expects.
+const PHOTON_URL = import.meta.env.VITE_NOMINATIM_URL || '/photon';
+
+export const NOMINATIM_URL = `${PHOTON_URL}/api`;
+export const NOMINATIME_URL_REVERSE = `${PHOTON_URL}/reverse`;
+
+interface PhotonFeature {
+  geometry: { coordinates: [number, number] };
+  properties: Record<string, string | number | number[] | undefined>;
+}
+
+const OSM_TYPES: Record<string, string> = {
+  N: 'node',
+  W: 'way',
+  R: 'relation',
+};
+
+const photonToNominatim = (feature: PhotonFeature): NominationResponse => {
+  const p = feature.properties;
+  const str = (key: string) => (p[key] === undefined ? '' : String(p[key]));
+  const streetLine = [str('housenumber'), str('street')]
+    .filter((s) => s.length > 0)
+    .join(' ');
+  const parts = [
+    str('name'),
+    streetLine,
+    str('district'),
+    str('city'),
+    str('county'),
+    str('state'),
+    str('postcode'),
+    str('country'),
+  ].filter((s) => s.length > 0);
+  // drop consecutive duplicates (e.g. a city whose name equals its county)
+  const displayName = parts
+    .filter((s, i) => i === 0 || s !== parts[i - 1])
+    .join(', ');
+  const [lon, lat] = feature.geometry.coordinates;
+
+  return {
+    place_id: Number(p.osm_id) || 0,
+    licence: 'Data © OpenStreetMap contributors, ODbL 1.0',
+    osm_type: OSM_TYPES[str('osm_type')] ?? str('osm_type'),
+    osm_id: Number(p.osm_id) || 0,
+    lat: lat.toString(),
+    lon: lon.toString(),
+    class: str('osm_key'),
+    type: str('osm_value'),
+    place_rank: 0,
+    importance: 0,
+    addresstype: str('type'),
+    name: str('name'),
+    display_name: displayName,
+    address: {
+      suburb: str('district'),
+      town: str('city'),
+      state: str('state'),
+      region: str('county'),
+      postcode: str('postcode'),
+      country: str('country'),
+    } as NominationResponse['address'],
+    boundingbox: [],
+  };
+};
 
 export const forward_geocode = async (userInput: string) => {
   const params = new URLSearchParams({
     q: userInput,
-    format: 'json',
-    limit: '5',
+    limit: '8',
   });
   const response = await fetch(`${NOMINATIM_URL}?${params}`);
 
   if (!response.ok) {
     throw new Error(`Could not fetch resource`);
   }
-  const data: NominationResponse = await response.json();
+  const collection: { features?: PhotonFeature[] } = await response.json();
+  const data: NominationResponse[] = (collection.features ?? []).map(
+    photonToNominatim
+  );
   return { data };
 };
+
 export const reverse_geocode = async (lon: number, lat: number) => {
   const params = new URLSearchParams({
     lon: lon.toString(),
     lat: lat.toString(),
-    format: 'json',
+    limit: '1',
   });
   const response = await fetch(`${NOMINATIME_URL_REVERSE}?${params}`);
 
@@ -29,7 +96,13 @@ export const reverse_geocode = async (lon: number, lat: number) => {
     throw new Error(`Could not fetch resource`);
   }
 
-  const data: NominationResponse = await response.json();
+  const collection: { features?: PhotonFeature[] } = await response.json();
+  const first = collection.features?.[0];
+  // Mirror Nominatim's "nothing here" answer so the caller falls back to
+  // showing the raw coordinates.
+  const data = (
+    first ? photonToNominatim(first) : { error: 'Unable to geocode' }
+  ) as NominationResponse;
   return { data };
 };
 
WEB_APP_PATCH_EOF
}

build_web_app() {
  local html="$DATA_DIR/web/html" work="$DATA_DIR/build/web"
  if [ -f "$html/index.html" ] && [ -f "$html/.built-$WEB_APP_COMMIT" ]; then info "Web app already built."; return; fi
  log "Building the Valhalla web app (downloads Node.js into a temporary folder)"
  rm -rf "$work"; mkdir -p "$work"
  local node_file
  local node_sums
  node_sums=$(curl -fsL --retry 5 "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt")
  node_file=$(awk -v a="linux-${ARCH_NODE}.tar.xz" '$2 ~ a"$" && !seen {print $2; seen=1}' <<<"$node_sums")
  [ -n "$node_file" ] || die "Could not find a Node.js $NODE_MAJOR download for this machine."
  curl -fL --retry 5 -o "$work/node.tar.xz" "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/$node_file"
  mkdir -p "$work/node" && tar -xJf "$work/node.tar.xz" -C "$work/node" --strip-components=1
  rm -f "$work/node.tar.xz"

  git clone --quiet "$WEB_APP_REPO" "$work/app"
  git -C "$work/app" -c advice.detachedHead=false checkout --quiet "$WEB_APP_COMMIT"
  write_web_patch "$work/local.patch"
  git -C "$work/app" apply --whitespace=nowarn "$work/local.patch"

  local center="$CENTER"
  [ -n "$center" ] || center=$(region_center)
  [ -n "$center" ] || center="39.8283,-98.5795"
  cat > "$work/app/.env.production.local" <<EOF
VITE_VALHALLA_URL=/valhalla
VITE_NOMINATIM_URL=/photon
VITE_CENTER_COORDS="$center"
VITE_DEFAULT_COSTING_MODEL=car
VITE_CLIENT_ID=local-web-app
EOF
  (
    cd "$work/app"
    export PATH="$work/node/bin:$PATH" HOME="$work/home" npm_config_update_notifier=false HUSKY=0
    mkdir -p "$HOME"
    npm ci --no-audit --no-fund --loglevel=error || npm install --no-audit --no-fund --loglevel=error
    NODE_ENV=production npm run build
  )
  [ -f "$work/app/build/index.html" ] || die "The web app build produced no output."
  rm -rf "$html"; mkdir -p "$html"
  cp -r "$work/app/build/." "$html/"
  touch "$html/.built-$WEB_APP_COMMIT"
  rm -rf "$work"
}

# ---- step: services --------------------------------------------------------------------------
write_units() {
  log "Writing systemd services and the nginx site"
  local threads=$CPUS photon_heap=1024
  [ "$RAM_MB" -ge 7000 ] && photon_heap=2048

  cat > /etc/systemd/system/valhalla-routing.service <<EOF
[Unit]
Description=Valhalla routing engine (offline stack)
After=network.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$DATA_DIR/valhalla
ExecStart=$VALHALLA_BIN/valhalla_service $VALHALLA_CONFIG $threads
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/valhalla-tiles.service <<EOF
[Unit]
Description=Vector map tile server (offline Valhalla stack)
After=network.target

[Service]
User=$SERVICE_USER
ExecStart=$DATA_DIR/bin/pmtiles serve $DATA_DIR/tiles --interface=127.0.0.1 --port=$TILES_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  if [ "$SEARCH" != "none" ]; then
    cat > /etc/systemd/system/valhalla-photon.service <<EOF
[Unit]
Description=Photon search (offline Valhalla stack)
After=network.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$DATA_DIR/photon
ExecStart=$JAVA -Xmx${photon_heap}m --add-modules jdk.incubator.vector --enable-native-access=ALL-UNNAMED -jar $DATA_DIR/bin/photon.jar serve -listen-ip 127.0.0.1 -listen-port $PHOTON_PORT -data-dir $DATA_DIR/photon
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  else
    rm -f /etc/systemd/system/valhalla-photon.service
  fi

  cat > "/etc/nginx/sites-available/$NGINX_SITE" <<'NGINX'
# Offline Valhalla stack: single entry point. Generated by setup-valhalla-pi.sh
map $http_x_forwarded_proto $valhalla_stack_scheme {
    default $scheme;
    https   https;
}

server {
    listen @WEB_PORT@;
    listen [::]:@WEB_PORT@;
    server_name _;

    gzip on;
    gzip_types application/json application/javascript text/css image/svg+xml;

    root @DATA_DIR@/web/html;
    index index.html;

    # Web app (single page app: unknown paths fall back to index.html)
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Map style: the placeholder becomes whatever address the browser used,
    # so it works by IP, by hostname, or behind a reverse proxy.
    location = /map/style.json {
        alias @DATA_DIR@/web/map/style.json;
        default_type application/json;
        sub_filter_types application/json;
        sub_filter_once off;
        sub_filter '__ORIGIN__' '$valhalla_stack_scheme://$http_host';
        add_header Cache-Control "no-cache";
    }

    # Fonts and sprites
    location /map/ {
        alias @DATA_DIR@/web/map/;
        expires 30d;
    }

    # Vector map tiles
    location /tiles/ {
        proxy_pass http://127.0.0.1:@TILES_PORT@/;
        expires 1d;
    }

    # Valhalla routing API
    location /valhalla/ {
        proxy_pass http://127.0.0.1:@VALHALLA_PORT@/;
        proxy_read_timeout 300s;
        client_max_body_size 20m;
    }

    # Photon search API
    location /photon/ {
        proxy_pass http://127.0.0.1:@PHOTON_PORT@/;
    }
}
NGINX
  sed -i -e "s|@WEB_PORT@|$WEB_PORT|g" -e "s|@DATA_DIR@|$DATA_DIR|g" -e "s|@TILES_PORT@|$TILES_PORT|g" \
         -e "s|@VALHALLA_PORT@|$VALHALLA_PORT|g" -e "s|@PHOTON_PORT@|$PHOTON_PORT|g" "/etc/nginx/sites-available/$NGINX_SITE"
  ln -sf "/etc/nginx/sites-available/$NGINX_SITE" "/etc/nginx/sites-enabled/$NGINX_SITE"
  nginx -t 2>/dev/null || { nginx -t; die "The nginx configuration test failed. Nothing was reloaded."; }
}

wait_for() { # wait_for NAME URL SECONDS
  local waited=0
  until curl -fs --max-time 5 -o /dev/null "$2"; do
    waited=$((waited + 5))
    [ "$waited" -ge "$3" ] && { warn "$1 is not answering yet (check: journalctl -u $4 -n 50)"; return 0; }
    sleep 5
  done
  info "$1: OK"
}

start_services() {
  if [ "$NO_START" = 1 ]; then
    info "--no-start given: services are installed but not enabled or started."
    return
  fi
  log "Starting services"
  systemctl daemon-reload
  systemctl enable --now valhalla-routing.service valhalla-tiles.service >/dev/null 2>&1
  systemctl restart valhalla-routing.service valhalla-tiles.service
  if [ "$SEARCH" != "none" ]; then
    systemctl enable --now valhalla-photon.service >/dev/null 2>&1
  fi
  systemctl enable nginx >/dev/null 2>&1 || true
  if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl start nginx; fi

  local base="http://127.0.0.1:$WEB_PORT"
  wait_for "Web interface" "$base/" 30 nginx
  wait_for "Map tiles" "$base/tiles/basemap/0/0/0.mvt" 60 valhalla-tiles
  wait_for "Routing" "$base/valhalla/status" 120 valhalla-routing
  [ "$SEARCH" = "none" ] || wait_for "Search" "$base/photon/status" 300 valhalla-photon
}

summary() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  log "Done"
  info "Open:      http://${ip:-<this-machine>}:$WEB_PORT"
  info "Data:      $DATA_DIR  ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1))"
  info "Services:  systemctl status valhalla-routing valhalla-tiles$([ "$SEARCH" = "none" ] || echo ' valhalla-photon')"
  info "Logs:      journalctl -u valhalla-routing -f"
  info "Remove:    sudo bash $0 --uninstall"
  info "The OSM extract in $DATA_DIR/osm is only needed for rebuilds and can be deleted to save space."
}

main() {
  parse_args "$@"
  [ "$(id -u)" = 0 ] || die "Please run as root: sudo bash $0 $*"
  if [ "$ACTION" = "uninstall" ]; then uninstall; exit 0; fi

  detect_platform
  plan
  mkdir -p "$DATA_DIR"/{osm,valhalla,tiles,photon,web/html,web/map,bin,runtime,build}
  exec > >(tee -a "$DATA_DIR/setup.log") 2>&1

  install_packages
  choose_ports
  id "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"

  if [ -n "$PREBUILT" ]; then install_prebuilt; else download_osm; fi
  install_tools
  build_routing
  build_map_tiles
  install_map_assets
  install_search_index
  build_web_app

  chown -R "$SERVICE_USER": "$DATA_DIR"/{valhalla,tiles,photon}
  chmod 755 "$DATA_DIR" "$DATA_DIR/web" "$DATA_DIR/web/html" "$DATA_DIR/web/map"
  write_units
  start_services
  summary
}

main "$@"
