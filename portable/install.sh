#!/usr/bin/env bash
# Standalone component installer (ai-stack adapter). Reads ./component.env next to this file.
# Modes: --preflight | --dry-run | --prepare | --verify | --activate --yes
# Default/no mode = --dry-run. Never starts services unless --activate --yes AND AI_STACK_ACTIVATE=1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/component.env"
MODE=--dry-run; YES=0
PREFIX="${AI_STACK_PREFIX:-$HOME/.local/share/ai-stack}"
CONF="${AI_STACK_CONFIG:-$HOME/.config/ai-stack}/$NAME"
while [ $# -gt 0 ]; do case "$1" in
  --preflight|--dry-run|--prepare|--verify|--activate) MODE=$1;;
  --yes) YES=1;; --prefix) PREFIX=$2; shift;;
  -h|--help) sed -n 2,5p "$0"; exit 0;;
  *) echo "unknown arg $1" >&2; exit 2;; esac; shift; done
SRC="$PREFIX/src/$NAME"; UNITDIR="$PREFIX/units"; APPDIR="$PREFIX/app/$NAME"
DRY=0; [ "$MODE" = --dry-run ] && DRY=1
run(){ if [ $DRY = 1 ]; then printf 'DRY:'; printf ' %q' "$@"; echo; else "$@"; fi; }
log(){ echo "[$NAME] $*"; }

preflight(){
  local miss=0 t
  for t in $REQUIRES; do command -v "$t" >/dev/null 2>&1 || { log "MISSING prerequisite: $t"; miss=1; }; done
  if [ -n "${NODE_VERSION:-}" ] && command -v node >/dev/null; then
    [ "$(node --version)" = "v$NODE_VERSION" ] || { log "node $(node --version) != required v$NODE_VERSION"; miss=1; }; fi
  if [ -n "${PORT:-}" ] && command -v ss >/dev/null && ss -Hltn "sport = :$PORT" 2>/dev/null | grep -q .; then
    log "WARNING port 127.0.0.1:$PORT already in use"; fi
  [ $miss = 0 ] && log "preflight OK" || { log "preflight FAILED"; return 3; }
}

fetch_source(){
  [ -n "${SOURCE_REPO:-}" ] || return 0
  run mkdir -p "$SRC"
  if [ $DRY = 0 ] && [ -d "$SRC/.git" ] && [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" = "$SOURCE_COMMIT" ]; then log "source already at $SOURCE_COMMIT"; return; fi
  run git -C "$SRC" init -q
  run git -C "$SRC" fetch -q --depth 1 "https://github.com/$SOURCE_REPO.git" "$SOURCE_COMMIT"
  run git -C "$SRC" checkout -q --detach FETCH_HEAD
  [ $DRY = 1 ] || [ "$(git -C "$SRC" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || { log "commit mismatch"; return 4; }
}

render(){ # substitute @VAR@ tokens from env; fails on leftovers
  local out; out=$(sed -e "s#@SRC@#$SRC#g" -e "s#@APPDIR@#$APPDIR#g" -e "s#@CONF@#$CONF#g" -e "s#@PREFIX@#$PREFIX#g" \
    -e "s#@PORT@#${PORT:-}#g" -e "s#@BUN@#${BUN_BIN:-}#g" -e "s#@NODE@#${NODE_BIN:-}#g" -e "s#@NAME@#$NAME#g" "$1")
  if grep -q '@[A-Z]*@' <<<"$out"; then log "unrendered token in $1"; return 5; fi
  printf '%s\n' "$out"
}

prepare(){
  preflight || [ $DRY = 1 ]
  BUN_BIN=$(command -v bun || true); NODE_BIN=$(command -v node || true)
  fetch_source
  run mkdir -p "$APPDIR" "$UNITDIR" "$CONF"
  if [ -n "${SETUP:-}" ]; then log "setup: $SETUP"; local wd="$APPDIR"; [ -n "${SOURCE_REPO:-}" ] && wd="$SRC"
    run bash -c "cd \"\$1\" && $SETUP" _ "$wd" "$APPDIR"; fi
  local f base
  for f in "$HERE"/templates/*; do [ -e "$f" ] || continue; base=$(basename "$f")
    case "$base" in
      *.service) if [ $DRY = 1 ]; then log "would render $UNITDIR/$base (DISABLED)"; else render "$f" > "$UNITDIR/$base"; fi;;
      *.example) [ -e "$CONF/${base%.example}" ] && log "keep existing $CONF/${base%.example}" || run install -m 600 "$f" "$CONF/${base%.example}";;
      *) if [ $DRY = 1 ]; then log "would render $CONF/$base"; else render "$f" > "$CONF/$base"; fi;;
    esac; done
  [ $DRY = 1 ] && { log "dry-run complete: nothing changed"; return 0; }
  log "prepared; units are NOT enabled. Run --verify next."
}

verify(){
  local bad=0 u exe wd k
  for u in "$UNITDIR"/*.service; do [ -e "$u" ] || continue
    grep -q "^# component: $NAME$" "$u" || continue
    exe=$(sed -n 's/^ExecStart=//p' "$u" | awk '{print $1}')
    [ -x "$exe" ] || { log "ExecStart not executable: $exe"; bad=1; }
    wd=$(sed -n 's/^WorkingDirectory=//p' "$u"); [ -z "$wd" ] || [ -d "$wd" ] || { log "WorkingDirectory missing: $wd"; bad=1; }
    grep -Eq '0\.0\.0\.0|--host +::' "$u" && { log "non-loopback bind in $u"; bad=1; }
  done
  for p in ${VERIFY_PATHS:-}; do p=${p//@SRC@/$SRC}; p=${p//@APPDIR@/$APPDIR}; p=${p//@CONF@/$CONF}; [ -e "$p" ] || { log "missing $p"; bad=1; }; done
  for k in ${SECRET_KEYS:-}; do grep -Eq "^$k=.+" "$CONF/$NAME.env" 2>/dev/null || { log "secret $k not set in $CONF/$NAME.env (owner must provision)"; bad=1; }; done
  [ -n "${HEALTH:-}" ] && log "health (not called): $HEALTH"
  [ $bad = 0 ] && log "verify OK" || { log "verify FAILED"; return 6; }
}

activate(){
  [ $YES = 1 ] && [ "${AI_STACK_ACTIVATE:-}" = 1 ] || { log "refusing: need --activate --yes and AI_STACK_ACTIVATE=1"; return 7; }
  verify
  if [ -n "${COMPOSE:-}" ]; then docker compose --env-file "$CONF/$NAME.env" -f "$CONF/compose.yml" up -d; return; fi
  [ -n "${UNITS:-}" ] || { log "no daemon for this component (on-demand CLI)"; return 0; }
  mkdir -p "$HOME/.config/systemd/user"; for u in $UNITS; do cp "$UNITDIR/$u" "$HOME/.config/systemd/user/"; done
  systemctl --user daemon-reload; for u in $UNITS; do systemctl --user enable --now "$u"; done
}
case $MODE in --preflight) preflight;; --dry-run|--prepare) prepare;; --verify) verify;; --activate) activate;; esac
