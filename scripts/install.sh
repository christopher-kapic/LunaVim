#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
FORCE=0
# Capture the user's literal LUNARVIM_* env values before the alias chain below
# folds them into LUNAVIM_*; detect_prior_install needs to see whether the user
# explicitly pointed LUNARVIM_* at a prior install, separately from whatever
# defaults the alias chain settles on.
LUNARVIM_RUNTIME_DIR_INPUT="${LUNARVIM_RUNTIME_DIR:-}"
LUNARVIM_BASE_DIR_INPUT="${LUNARVIM_BASE_DIR:-}"
LUNAVIM_INSTALL_DIR="${LUNAVIM_INSTALL_DIR:-${LUNAVIM_BASE_DIR:-${LUNARVIM_BASE_DIR:-${LVIM_INSTALL_DIR:-"$HOME/.local/share/lunavim"}}}}"
LUNAVIM_REPO_URL="${LUNAVIM_REPO_URL:-${LVIM_REPO_URL:-"https://github.com/christopher-kapic/LunaVim.git"}}"
LUNAVIM_BIN_DIR="${LUNAVIM_BIN_DIR:-${LVIM_BIN_DIR:-"$HOME/.local/bin"}}"
LUNAVIM_CONFIG_DIR="${LUNAVIM_CONFIG_DIR:-${LUNARVIM_CONFIG_DIR:-${LVIM_CONFIG_DIR:-"$HOME/.config/lvim"}}}"
LUNAVIM_RUNTIME_DIR="${LUNAVIM_RUNTIME_DIR:-${LUNARVIM_RUNTIME_DIR:-"$HOME/.local/share/lunavim"}}"
LUNAVIM_CACHE_DIR="${LUNAVIM_CACHE_DIR:-${LUNARVIM_CACHE_DIR:-"$HOME/.cache/lvim"}}"

LVIM_INSTALL_DIR="$LUNAVIM_INSTALL_DIR"
LVIM_REPO_URL="$LUNAVIM_REPO_URL"
LVIM_BIN_DIR="$LUNAVIM_BIN_DIR"
LVIM_CONFIG_DIR="$LUNAVIM_CONFIG_DIR"
LVIM_CONFIG_FILE="$LVIM_CONFIG_DIR/config.lua"

usage() {
  cat <<'USAGE'
Usage: install.sh [--force] [--dry-run] [-h|--help]

Install or update LunaVim for Linux/macOS.

Options:
  --force      Overwrite the lvim launcher even if a prior LunarVim (or
               a LunarVim fork) install or a foreign lvim launcher is
               detected. By default the
               installer refuses to overwrite and prints removal guidance.
  --dry-run    Print the install plan without touching disk.
  -h, --help   Print this help.

Environment:
  LUNAVIM_INSTALL_DIR  Install checkout path (default: ~/.local/share/lunavim)
  LUNAVIM_REPO_URL     Git repository URL to clone
  LUNAVIM_BIN_DIR      Launcher destination directory (default: ~/.local/bin)
  LUNAVIM_CONFIG_DIR   User config directory (default: ~/.config/lvim)

Compatibility:
  LUNAVIM_BASE_DIR and LUNARVIM_BASE_DIR are accepted as install directory aliases.
  LUNARVIM_CONFIG_DIR, LUNARVIM_RUNTIME_DIR, and LUNARVIM_CACHE_DIR are accepted as legacy aliases.
  LVIM_* installer variables are accepted as legacy installer aliases.
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

run() {
  if (( DRY_RUN )); then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --force)
        FORCE=1
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

detect_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Linux | Darwin)
      log "Detected supported OS: $os"
      ;;
    *)
      die "unsupported OS: $os. LunaVim installer currently supports Linux and macOS only."
      ;;
  esac
}

version_at_least_0_11() {
  local version="$1"
  local major minor patch

  IFS=. read -r major minor patch <<<"$version"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"

  if (( major > 0 )); then
    return 0
  fi
  if (( major == 0 && minor >= 11 )); then
    return 0
  fi
  return 1
}

check_prerequisites() {
  if ! command -v git >/dev/null 2>&1; then
    die "git is required but was not found on PATH"
  fi

  if ! command -v nvim >/dev/null 2>&1; then
    die "Neovim is required but nvim was not found on PATH"
  fi

  local version_line version
  version_line="$(nvim --version | head -1)"
  version="$(grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$version_line" | head -1)"

  if [[ -z "$version" ]]; then
    die "could not parse Neovim version from: $version_line"
  fi

  if ! version_at_least_0_11 "$version"; then
    die "LunaVim requires Neovim >= 0.11; found $version_line"
  fi

  log "Prerequisites found: git, Neovim $version"
}

detect_prior_install() {
  local found=()
  local launcher="$LVIM_BIN_DIR/lvim"
  local xdg_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  local seen_dirs=" "
  local legacy_dir

  # LunarVim and its forks both default to $XDG_DATA_HOME/lunarvim. Also honor
  # the user's LUNARVIM_RUNTIME_DIR_INPUT / LUNARVIM_BASE_DIR_INPUT (the literal
  # values they set, captured before the LUNAVIM_* alias chain absorbed them) —
  # those point at where the prior install lives. If any such directory is on
  # disk, the LunaVim launcher would shadow `lvim` and confuse the user about
  # which distribution owns the binary. Skip only LVIM_INSTALL_DIR so re-runs
  # against an already-installed LunaVim don't flag LunaVim itself.
  for legacy_dir in \
    "$xdg_data_home/lunarvim" \
    "${LUNARVIM_RUNTIME_DIR_INPUT:-}" \
    "${LUNARVIM_BASE_DIR_INPUT:-}"; do
    [[ -z "$legacy_dir" ]] && continue
    [[ "$legacy_dir" == "$LVIM_INSTALL_DIR" ]] && continue
    [[ "$seen_dirs" == *" $legacy_dir "* ]] && continue
    seen_dirs+="$legacy_dir "
    if [[ -e "$legacy_dir" ]]; then
      found+=("$legacy_dir (prior LunarVim or LunarVim-fork install directory)")
    fi
  done

  if [[ -L "$launcher" ]]; then
    local target
    target="$(readlink -f -- "$launcher" 2>/dev/null || true)"
    if [[ -z "$target" || "$target" != "$LVIM_INSTALL_DIR"* ]]; then
      found+=("$launcher -> ${target:-<unreadable>} (does not point into $LVIM_INSTALL_DIR)")
    fi
  elif [[ -f "$launcher" ]] && ! launcher_matches_install_dir "$launcher"; then
    found+=("$launcher (foreign launcher; does not match LunaVim's template for $LVIM_INSTALL_DIR)")
  fi

  if (( ! ${#found[@]} )); then
    return 0
  fi

  if (( FORCE )); then
    warn "Detected prior LunarVim (or LunarVim-fork) install or foreign lvim launcher; continuing because --force was given:"
    local item
    for item in "${found[@]}"; do
      warn "  - $item"
    done
    return 0
  fi

  warn "Detected prior LunarVim (or LunarVim-fork) install or foreign lvim launcher:"
  local item
  for item in "${found[@]}"; do
    warn "  - $item"
  done
  warn ""
  warn "Remove these paths before installing LunaVim (see the Installation section in"
  warn "README.md for the exact commands), or rerun with --force to overwrite the launcher."
  die "refusing to overwrite an existing lvim install without --force"
}

ensure_checkout() {
  if [[ -d "$LVIM_INSTALL_DIR/.git" ]]; then
    log "Updating existing LunaVim checkout at $LVIM_INSTALL_DIR"
    if (( DRY_RUN )); then
      log "dry-run: git -C $LVIM_INSTALL_DIR pull --ff-only"
      log "dry-run: unchanged checkouts would report: already up to date"
    else
      git -C "$LVIM_INSTALL_DIR" pull --ff-only
    fi
  elif [[ -e "$LVIM_INSTALL_DIR" ]]; then
    die "$LVIM_INSTALL_DIR exists but is not a git checkout"
  else
    log "Cloning LunaVim into $LVIM_INSTALL_DIR"
    run git clone "$LVIM_REPO_URL" "$LVIM_INSTALL_DIR"
  fi
}

install_launcher() {
  local target="$LVIM_BIN_DIR/lvim"
  local temp_launcher

  run mkdir -p "$LVIM_BIN_DIR"

  if launcher_matches_install_dir "$target"; then
    log "$target already up to date"
  else
    log "Installing launcher to $target"
    if (( DRY_RUN )); then
      log "dry-run: would write launcher for $LVIM_INSTALL_DIR"
    else
      temp_launcher="$(mktemp)"
      write_launcher "$temp_launcher"
      mv "$temp_launcher" "$target"
    fi
  fi

  run chmod +x "$target"

  case ":$PATH:" in
    *":$LVIM_BIN_DIR:"*) ;;
    *) warn "$LVIM_BIN_DIR is not on PATH. Add: export PATH=\"$LVIM_BIN_DIR:\$PATH\"" ;;
  esac
}

launcher_matches_install_dir() {
  local target="$1"
  local quoted_install_dir
  local quoted_runtime_dir
  local quoted_config_dir
  local quoted_cache_dir

  [[ -f "$target" ]] || return 1
  quoted_install_dir="$(shell_quote "$LVIM_INSTALL_DIR")"
  quoted_runtime_dir="$(shell_quote "$LUNAVIM_RUNTIME_DIR")"
  quoted_config_dir="$(shell_quote "$LUNAVIM_CONFIG_DIR")"
  quoted_cache_dir="$(shell_quote "$LUNAVIM_CACHE_DIR")"

  grep -Fq "LVIM_BASE_DIR=$quoted_install_dir" "$target" 2>/dev/null &&
    grep -Fq "LVIM_RUNTIME_DIR=$quoted_runtime_dir" "$target" 2>/dev/null &&
    grep -Fq "LVIM_CONFIG_DIR=$quoted_config_dir" "$target" 2>/dev/null &&
    grep -Fq "LVIM_CACHE_DIR=$quoted_cache_dir" "$target" 2>/dev/null &&
    grep -Fq 'LVIM_INIT_FILE="$LVIM_BASE_DIR/init.lua"' "$target" 2>/dev/null &&
    grep -Fq 'exec nvim -u "$LVIM_INIT_FILE" "$@"' "$target" 2>/dev/null
}

write_launcher() {
  local target="$1"
  local quoted_install_dir

  quoted_install_dir="$(shell_quote "$LVIM_INSTALL_DIR")"

  cat >"$target" <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

LVIM_BASE_DIR=$quoted_install_dir
LVIM_RUNTIME_DIR=$(shell_quote "$LUNAVIM_RUNTIME_DIR")
LVIM_CONFIG_DIR=$(shell_quote "$LUNAVIM_CONFIG_DIR")
LVIM_CACHE_DIR=$(shell_quote "$LUNAVIM_CACHE_DIR")
LVIM_INIT_FILE="\$LVIM_BASE_DIR/init.lua"

export LUNAVIM_BASE_DIR="\${LUNAVIM_BASE_DIR:-\${LUNARVIM_BASE_DIR:-\$LVIM_BASE_DIR}}"
export LUNAVIM_RUNTIME_DIR="\${LUNAVIM_RUNTIME_DIR:-\${LUNARVIM_RUNTIME_DIR:-\$LVIM_RUNTIME_DIR}}"
export LUNAVIM_CONFIG_DIR="\${LUNAVIM_CONFIG_DIR:-\${LUNARVIM_CONFIG_DIR:-\$LVIM_CONFIG_DIR}}"
export LUNAVIM_CACHE_DIR="\${LUNAVIM_CACHE_DIR:-\${LUNARVIM_CACHE_DIR:-\$LVIM_CACHE_DIR}}"

export LUNARVIM_BASE_DIR="\${LUNARVIM_BASE_DIR:-\$LUNAVIM_BASE_DIR}"
export LUNARVIM_RUNTIME_DIR="\${LUNARVIM_RUNTIME_DIR:-\$LUNAVIM_RUNTIME_DIR}"
export LUNARVIM_CONFIG_DIR="\${LUNARVIM_CONFIG_DIR:-\$LUNAVIM_CONFIG_DIR}"
export LUNARVIM_CACHE_DIR="\${LUNARVIM_CACHE_DIR:-\$LUNAVIM_CACHE_DIR}"

exec nvim -u "\$LVIM_INIT_FILE" "\$@"
LAUNCHER
}

shell_quote() {
  local value="$1"

  printf "'%s'" "${value//\'/\'\\\'\'}"
}

write_starter_config() {
  if [[ -f "$LVIM_CONFIG_FILE" ]]; then
    log "$LVIM_CONFIG_FILE already up to date"
    return
  fi

  log "Creating starter config at $LVIM_CONFIG_FILE"
  run mkdir -p "$LVIM_CONFIG_DIR"

  if (( DRY_RUN )); then
    log "dry-run: would write starter Lua config"
    return
  fi

  cat >"$LVIM_CONFIG_FILE" <<'CONFIG'
-- LunaVim user configuration
-- This file is loaded after LunaVim defaults.
-- Keep overrides small and Lua-first.

-- Leader key used by LunaVim keymaps.
lvim.leader = "space"

-- Pick a colorscheme installed by your plugin set.
-- lvim.colorscheme = "tokyonight"

-- Disable a builtin module when you prefer your own setup.
-- lvim.builtin.telescope.active = false

-- Format on save accepts a boolean or a table in LunaVim.
-- lvim.format_on_save = true

-- Add user plugins after the core LunaVim spec.
lvim.plugins = {
  -- {
  --   "folke/todo-comments.nvim",
  --   event = "BufReadPost",
  --   opts = {},
  -- },
}

-- Extend builtin options in-place when a module supports it.
-- lvim.builtin.nvimtree.setup.view.width = 36

-- Put project-specific Lua below this line.
-- Use :LvimReload after editing this file.
CONFIG
}

main() {
  parse_args "$@"
  detect_os
  check_prerequisites
  detect_prior_install
  ensure_checkout
  install_launcher
  write_starter_config

  log ""
  log "LunaVim install complete."
  log "Next steps:"
  log "  1. Run: lvim"
  log "  2. Let LunaVim bootstrap plugins."
  log "  3. Run: :checkhealth"
}

main "$@"
