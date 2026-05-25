#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
KEEP_CONFIG=0
PURGE=0
FORCE=0

LUNAVIM_INSTALL_DIR="${LUNAVIM_INSTALL_DIR:-${LUNAVIM_BASE_DIR:-${LUNARVIM_BASE_DIR:-${LVIM_INSTALL_DIR:-"$HOME/.local/share/lunavim"}}}}"
LUNAVIM_RUNTIME_DIR="${LUNAVIM_RUNTIME_DIR:-${LUNARVIM_RUNTIME_DIR:-"$HOME/.local/share/lunavim"}}"
LUNAVIM_BIN_DIR="${LUNAVIM_BIN_DIR:-${LVIM_BIN_DIR:-"$HOME/.local/bin"}}"
LUNAVIM_CONFIG_DIR="${LUNAVIM_CONFIG_DIR:-${LUNARVIM_CONFIG_DIR:-${LVIM_CONFIG_DIR:-"$HOME/.config/lvim"}}}"
LUNAVIM_CACHE_DIR="${LUNAVIM_CACHE_DIR:-${LUNARVIM_CACHE_DIR:-"$HOME/.cache/lvim"}}"

LAUNCHER_PATH="$LUNAVIM_BIN_DIR/lvim"

REMOVED=()
KEPT=()

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--keep-config] [--purge] [--force] [--yes] [--dry-run] [-h|--help]

Remove LunaVim from this system.

By default removes:
  ~/.local/share/lunavim   (install checkout and plugin runtime)
  ~/.local/bin/lvim        (launcher, only if it matches LunaVim's template)

Options:
  --keep-config   Never touch ~/.config/lvim/ (default already skips it;
                  use with --purge to keep the user config).
  --purge         Also remove ~/.config/lvim/ and ~/.cache/lvim/.
  --force         Remove the lvim launcher even if it does not match
                  LunaVim's template (e.g. a LunarVim-fork launcher).
                  By default a foreign launcher is left untouched.
  --yes           Skip all confirmation prompts.
  --dry-run       Print the removal plan without touching disk.
  -h, --help      Print this help.

Environment:
  LUNAVIM_INSTALL_DIR  Install checkout path (default: ~/.local/share/lunavim)
  LUNAVIM_RUNTIME_DIR  Plugin runtime path (default: ~/.local/share/lunavim)
  LUNAVIM_BIN_DIR      Launcher directory (default: ~/.local/bin)
  LUNAVIM_CONFIG_DIR   User config directory (default: ~/.config/lvim)
  LUNAVIM_CACHE_DIR    Cache directory (default: ~/.cache/lvim)

Compatibility:
  LUNARVIM_BASE_DIR, LUNARVIM_RUNTIME_DIR, LUNARVIM_CONFIG_DIR,
  LUNARVIM_CACHE_DIR and LVIM_* are accepted as legacy aliases.
USAGE
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while (($#)); do
    case "$1" in
      --keep-config)
        KEEP_CONFIG=1
        ;;
      --purge)
        PURGE=1
        ;;
      --force)
        FORCE=1
        ;;
      --yes | -y)
        ASSUME_YES=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

launcher_is_lunavim() {
  local target="$1"

  [[ -f "$target" ]] || return 1

  # The installer's `write_launcher` (scripts/install.sh) emits a stable
  # template whose final exec line and init-file assignment are LunaVim-
  # specific. Match both to distinguish a LunaVim launcher from a foreign
  # `lvim` left behind by LunarVim or one of its forks (which use a
  # different launcher
  # body, e.g. invoking a `lvim` wrapper from inside the install dir rather
  # than `exec nvim -u init.lua`).
  grep -Fq 'LVIM_INIT_FILE="$LVIM_BASE_DIR/init.lua"' "$target" 2>/dev/null &&
    grep -Fq 'exec nvim -u "$LVIM_INIT_FILE" "$@"' "$target" 2>/dev/null
}

confirm() {
  local prompt="$1"
  local reply

  if (( ASSUME_YES )) || (( DRY_RUN )); then
    return 0
  fi

  printf '%s [Y/n] ' "$prompt"
  if ! read -r reply; then
    return 1
  fi

  case "$reply" in
    '' | y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
  esac
}

remove_path() {
  local path="$1"
  local kind="$2"

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    log "Skipping $kind: $path (not present)"
    KEPT+=("$path (not present)")
    return
  fi

  if ! confirm "Remove $kind at $path?"; then
    log "Keeping $kind: $path"
    KEPT+=("$path")
    return
  fi

  if (( DRY_RUN )); then
    log "dry-run: would remove $kind: $path"
  else
    log "Removing $kind: $path"
    rm -rf -- "$path"
  fi
  REMOVED+=("$path")
}

print_summary() {
  log ""
  log "Uninstall summary:"
  if (( ${#REMOVED[@]} )); then
    log "  Removed:"
    local item
    for item in "${REMOVED[@]}"; do
      log "    - $item"
    done
  else
    log "  Removed: (nothing)"
  fi

  if (( ${#KEPT[@]} )); then
    log "  Kept:"
    local item
    for item in "${KEPT[@]}"; do
      log "    - $item"
    done
  else
    log "  Kept: (nothing)"
  fi

  if (( DRY_RUN )); then
    log ""
    log "Dry-run: no files were actually modified."
  fi
}

main() {
  parse_args "$@"

  log "LunaVim uninstaller"
  if (( DRY_RUN )); then
    log "Mode: dry-run (no files will be removed)"
  fi
  log ""

  remove_path "$LUNAVIM_INSTALL_DIR" "install directory"
  if [[ "$LUNAVIM_RUNTIME_DIR" != "$LUNAVIM_INSTALL_DIR" ]]; then
    remove_path "$LUNAVIM_RUNTIME_DIR" "plugin runtime directory"
  fi

  if [[ -e "$LAUNCHER_PATH" || -L "$LAUNCHER_PATH" ]] \
    && ! launcher_is_lunavim "$LAUNCHER_PATH" \
    && (( ! FORCE )); then
    warn "Refusing to remove $LAUNCHER_PATH: does not match LunaVim's launcher template."
    warn "  This is likely a launcher from LunarVim or one of its forks. Remove it"
    warn "  manually (or rerun with --force) if you really want it gone."
    KEPT+=("$LAUNCHER_PATH (foreign launcher)")
  else
    remove_path "$LAUNCHER_PATH" "launcher"
  fi

  if (( PURGE )); then
    if (( KEEP_CONFIG )); then
      log "Keeping user config at $LUNAVIM_CONFIG_DIR (--keep-config)"
      KEPT+=("$LUNAVIM_CONFIG_DIR")
    else
      remove_path "$LUNAVIM_CONFIG_DIR" "user config"
    fi
    remove_path "$LUNAVIM_CACHE_DIR" "cache"
  else
    if (( KEEP_CONFIG )); then
      log "Keeping user config at $LUNAVIM_CONFIG_DIR (--keep-config)"
    else
      log "Keeping user config at $LUNAVIM_CONFIG_DIR (use --purge to remove)"
    fi
    KEPT+=("$LUNAVIM_CONFIG_DIR")
    log "Keeping cache at $LUNAVIM_CACHE_DIR (use --purge to remove)"
    KEPT+=("$LUNAVIM_CACHE_DIR")
  fi

  print_summary
}

main "$@"
