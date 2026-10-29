#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Eric's server bootstrap
#
# Quickstart on a fresh machine:
#   curl -fsSL https://raw.githubusercontent.com/EricZQu/dotfiles/main/bootstrap.sh | bash
#
# Or with overrides:
#   REPO_URL=https://github.com/EricZQu/dotfiles.git \
#   GITHUB_EMAIL=ericqu@berkeley.edu \
#   bash bootstrap.sh
#
# Nothing is installed with sudo: every tool lands under $HOME (~/.local/bin,
# ~/.pixi, ...), so it can self-update and never clashes with root-owned copies.
#
# Env flags (all optional, set to 1 to skip):
#   SKIP_TOOLS          fzf/zoxide/eza/bat/ripgrep/jq
#   SKIP_UV             uv install
#   SKIP_HF             huggingface cli
#   SKIP_CLAUDE_CODE    claude code cli
#   SKIP_CODEX          openai codex cli
#   SKIP_HERDR          herdr (agent multiplexer)
#   SKIP_DIRENV         direnv
#   SKIP_ATUIN_REGISTER skip the interactive register/login step
#   SKIP_MOSH           mosh
#   SKIP_GLOBUS         globus connect personal
#   SKIP_GLOBUS_AUTH    install globus but don't pause for setup key
#   SKIP_SSH            github ssh keygen
#   SKIP_CHSH           don't try chsh; rely on .bashrc trampoline
#   ASSUME_YES=1        non-interactive mode (skip all interactive steps)
#
# Opt-in flags (set to 1 to enable):
#   WITH_ATUIN          atuin shell history (+ sync login)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/EricZQu/dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
GITHUB_EMAIL="${GITHUB_EMAIL:-ericqu@berkeley.edu}"

# ---- helpers --------------------------------------------------------------
c_blue=$'\033[1;34m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'
c_grn=$'\033[1;32m'; c_dim=$'\033[2m';     c_rst=$'\033[0m'

log()    { printf '%s[bootstrap]%s %s\n' "$c_blue" "$c_rst" "$*"; }
warn()   { printf '%s[bootstrap]%s %s\n' "$c_yel"  "$c_rst" "$*" >&2; }
err()    { printf '%s[bootstrap]%s %s\n' "$c_red"  "$c_rst" "$*" >&2; }
ok()     { printf '%s[bootstrap]%s %s\n' "$c_grn"  "$c_rst" "$*"; }
section(){ printf '\n%s═══ %s ═══%s\n' "$c_blue" "$*" "$c_rst"; }

have()      { command -v "$1" >/dev/null 2>&1; }
# $1 is on PATH and owned by us, i.e. not a root-owned sudo/apt/npm -g install
have_own()  { local p; p="$(command -v "$1" 2>/dev/null)" && [[ -O "$p" ]]; }
have_sudo() { have sudo && sudo -n true 2>/dev/null; }
is_linux()  { [[ "$(uname -s)" = "Linux" ]]; }
is_macos()  { [[ "$(uname -s)" = "Darwin" ]]; }
interactive(){ [[ -z "${ASSUME_YES:-}" ]] && { : >/dev/tty; } 2>/dev/null; }
ask()       { local p="$1" reply; read -r -p "$p" reply </dev/tty; printf '%s\n' "$reply"; }
confirm()   {
  interactive || return 0
  local p="$1" reply
  read -r -p "$p [Y/n] " reply </dev/tty
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# Everything installs into $HOME; under sudo that means root's home, or
# root-owned files in yours that later updates can't touch.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  err "don't run bootstrap with sudo — it installs into your home and needs no root"
  exit 1
fi

# Detect arch for binary downloads
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH_SHORT=x86_64;  ARCH_NICE=amd64 ;;
  aarch64|arm64) ARCH_SHORT=aarch64; ARCH_NICE=arm64 ;;
  *) warn "unknown arch '$ARCH' — some binary downloads may fail"
     ARCH_SHORT="$ARCH"; ARCH_NICE="$ARCH" ;;
esac

# OS-aware Rust-toolchain target triple (used by eza, bat, ripgrep, delta releases)
if [[ "$(uname -s)" = "Darwin" ]]; then
  RELEASE_TAG="${ARCH_SHORT}-apple-darwin"
else
  RELEASE_TAG="${ARCH_SHORT}-unknown-linux-musl"
fi

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
case ":$PATH:" in *":$LOCAL_BIN:"*) ;; *) export PATH="$LOCAL_BIN:$PATH" ;; esac

# Package install via Homebrew on macOS (no sudo). Deliberately never apt:
# sudo installs are root-owned, can't self-update, and clash with user-local
# copies — so on Linux this returns 1 and callers fall through to a user-space
# install under ~/.local.
pkg_install() {
  is_macos && have brew && brew install "$@" >/dev/null 2>&1
}

# pixi: conda-forge packages as single-user installs (no sudo, no conda needed).
# Provides zsh and mosh on Linux machines that don't have them.
ensure_pixi() {
  have pixi && return 0
  log "installing pixi (single binary, no sudo)"
  # NO_PATH_UPDATE: otherwise it appends to ~/.zshrc, a symlink into this repo
  curl -fsSL https://pixi.sh/install.sh | PIXI_NO_PATH_UPDATE=1 bash >/dev/null 2>&1 || return 1
  [[ -x "$HOME/.pixi/bin/pixi" ]] && {
    export PATH="$HOME/.pixi/bin:$PATH"
    ln -sfn "$HOME/.pixi/bin/pixi" "$LOCAL_BIN/pixi"
  }
  have pixi
}

# Generic: download a tarball from a URL, extract a single binary into ~/.local/bin
# usage: install_release_binary <name> <url> <path-inside-archive> [archive-type]
install_release_binary() {
  local name="$1" url="$2" inner="$3" type="${4:-tgz}"
  local tmp; tmp="$(mktemp -d)"
  log "downloading $name from $url"
  if ! curl -fsSL "$url" -o "$tmp/archive"; then
    warn "download failed for $name"; rm -rf "$tmp"; return 1
  fi
  case "$type" in
    tgz|tar.gz) tar -xzf "$tmp/archive" -C "$tmp" ;;
    zip)        unzip -q "$tmp/archive" -d "$tmp" ;;
    raw)        mv "$tmp/archive" "$tmp/$(basename "$inner")" ;;
    *) warn "unknown archive type $type"; rm -rf "$tmp"; return 1 ;;
  esac
  if [[ -f "$tmp/$inner" ]]; then
    install -m 0755 "$tmp/$inner" "$LOCAL_BIN/$name"
    ok "installed $name → $LOCAL_BIN/$name"
  else
    warn "could not find $inner in $name archive"; rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
}

backup_if_real() {
  # If $1 exists and is NOT already a symlink into our dotfiles, back it up.
  local f="$1"
  [[ -e "$f" || -L "$f" ]] || return 0
  if [[ -L "$f" ]]; then
    local target; target="$(readlink "$f")"
    [[ "$target" == "$DOTFILES_DIR/"* ]] && return 0
  fi
  local bak="$f.bootstrap.bak.$(date +%s)"
  mv "$f" "$bak"
  warn "backed up $f → $bak"
}

# ============================================================================
# 0. clone the dotfiles repo (so home/* is available for symlinking)
# ============================================================================
clone_dotfiles() {
  section "dotfiles repo"
  if [[ -d "$DOTFILES_DIR/.git" ]]; then
    log "dotfiles repo present at $DOTFILES_DIR; pulling"
    git -C "$DOTFILES_DIR" pull --ff-only --quiet || warn "pull failed"
  elif [[ -d "$DOTFILES_DIR" ]]; then
    # Running this script from inside the cloned repo? Use it in place.
    if [[ -f "$DOTFILES_DIR/bootstrap.sh" ]]; then
      log "using existing dir $DOTFILES_DIR (no .git, leaving alone)"
    else
      err "$DOTFILES_DIR exists but is not the dotfiles repo"; exit 1
    fi
  else
    log "cloning $REPO_URL → $DOTFILES_DIR"
    git clone --depth=1 "$REPO_URL" "$DOTFILES_DIR"
  fi
}

# ============================================================================
# 1. zsh
# ============================================================================
install_zsh() {
  section "zsh"
  if have zsh; then ok "zsh present: $(zsh --version | head -1)"; return; fi
  if pkg_install zsh; then ok "installed zsh via brew"; return; fi
  if ensure_pixi && pixi global install zsh >/dev/null 2>&1; then
    ln -sfn "$HOME/.pixi/bin/zsh" "$LOCAL_BIN/zsh"
    ok "installed zsh via pixi → $LOCAL_BIN/zsh"
    return
  fi
  warn "could not install zsh without sudo; ask your sysadmin"
}

# ============================================================================
# 2. antidote (zsh plugin manager — replaces oh-my-zsh framework, but loads OMZ plugins)
# ============================================================================
install_antidote() {
  section "antidote"
  local dest="$HOME/.antidote"
  if [[ -d "$dest/.git" ]]; then
    log "antidote present; pulling"
    git -C "$dest" pull --ff-only --quiet || true
  else
    log "cloning antidote → $dest"
    git clone --depth=1 https://github.com/mattmc3/antidote.git "$dest"
  fi
  ok "antidote ready"
}

# ============================================================================
# 3. starship
# ============================================================================
install_starship() {
  section "starship"
  if have starship; then ok "starship present: $(starship --version | head -1)"; return; fi
  log "installing starship → $LOCAL_BIN"
  curl -fsSL https://starship.rs/install.sh | sh -s -- --bin-dir "$LOCAL_BIN" --yes >/dev/null
  ok "starship installed"
}

# ============================================================================
# 4. modern CLI tools (jq, fzf, zoxide, eza, bat, ripgrep)
# ============================================================================
install_jq() {
  have jq && return
  pkg_install jq && return
  is_macos && { warn "jq: install Homebrew, then 'brew install jq'"; return 1; }
  install_release_binary jq \
    "https://github.com/jqlang/jq/releases/latest/download/jq-linux-${ARCH_NICE}" "" raw
}

install_fzf() {
  have fzf && return
  log "installing fzf"
  if [[ ! -d "$HOME/.fzf" ]]; then
    git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
  fi
  "$HOME/.fzf/install" --no-update-rc --key-bindings --completion >/dev/null
  # symlink into ~/.local/bin so PATH picks it up everywhere
  ln -sfn "$HOME/.fzf/bin/fzf" "$LOCAL_BIN/fzf"
  ok "fzf installed"
}

install_zoxide() {
  have zoxide && return
  log "installing zoxide"
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
    | sh -s -- --bin-dir "$LOCAL_BIN" >/dev/null
  ok "zoxide installed"
}

install_eza() {
  have eza && return
  log "installing eza"
  pkg_install eza && return
  is_macos && { warn "eza: install Homebrew, then 'brew install eza'"; return 1; }
  install_release_binary eza \
    "https://github.com/eza-community/eza/releases/latest/download/eza_${RELEASE_TAG}.tar.gz" eza
}

install_bat() {
  have bat && return
  log "installing bat"
  if pkg_install bat; then
    # Debian/Ubuntu rename to batcat to avoid conflict
    have batcat && ! have bat && ln -sfn "$(command -v batcat)" "$LOCAL_BIN/bat"
    return
  fi
  is_macos && { warn "bat: install Homebrew, then 'brew install bat'"; return 1; }
  local ver; ver="$(curl -fsSL https://api.github.com/repos/sharkdp/bat/releases/latest | grep -oE '"tag_name":\s*"v[^"]+"' | head -1 | grep -oE 'v[0-9.]+')"
  [[ -z "$ver" ]] && { warn "couldn't get bat version"; return 1; }
  install_release_binary bat \
    "https://github.com/sharkdp/bat/releases/download/${ver}/bat-${ver}-${RELEASE_TAG}.tar.gz" \
    "bat-${ver}-${RELEASE_TAG}/bat"
}

install_ripgrep() {
  have rg && return
  log "installing ripgrep"
  pkg_install ripgrep && return
  is_macos && { warn "ripgrep: install Homebrew, then 'brew install ripgrep'"; return 1; }
  local ver; ver="$(curl -fsSL https://api.github.com/repos/BurntSushi/ripgrep/releases/latest | grep -oE '"tag_name":\s*"[^"]+"' | head -1 | grep -oE '[0-9.]+')"
  [[ -z "$ver" ]] && { warn "couldn't get ripgrep version"; return 1; }
  install_release_binary rg \
    "https://github.com/BurntSushi/ripgrep/releases/download/${ver}/ripgrep-${ver}-${RELEASE_TAG}.tar.gz" \
    "ripgrep-${ver}-${RELEASE_TAG}/rg"
}

install_delta() {
  have delta && return
  log "installing git-delta"
  pkg_install git-delta && return
  is_macos && { warn "delta: install Homebrew, then 'brew install git-delta'"; return 1; }
  local ver; ver="$(curl -fsSL https://api.github.com/repos/dandavison/delta/releases/latest | grep -oE '"tag_name":\s*"[^"]+"' | head -1 | grep -oE '[0-9.]+')"
  [[ -z "$ver" ]] && { warn "couldn't get delta version"; return 1; }
  install_release_binary delta \
    "https://github.com/dandavison/delta/releases/download/${ver}/delta-${ver}-${RELEASE_TAG}.tar.gz" \
    "delta-${ver}-${RELEASE_TAG}/delta"
}

install_tools() {
  [[ "${SKIP_TOOLS:-0}" = "1" ]] && return
  section "modern CLI tools"
  install_jq      || warn "jq install failed"
  install_fzf     || warn "fzf install failed"
  install_zoxide  || warn "zoxide install failed"
  install_eza     || warn "eza install failed"
  install_bat     || warn "bat install failed"
  install_ripgrep || warn "ripgrep install failed"
  install_delta   || warn "delta install failed (git diff falls back to default pager)"
}

# ============================================================================
# 5. direnv + atuin
# ============================================================================
install_direnv() {
  [[ "${SKIP_DIRENV:-0}" = "1" ]] && return
  section "direnv"
  if have direnv; then ok "direnv present: $(direnv --version)"; return; fi
  pkg_install direnv && return || true
  log "installing direnv → $LOCAL_BIN"
  curl -sfL https://direnv.net/install.sh | bin_path="$LOCAL_BIN" bash
  ok "direnv installed"
}

install_atuin() {
  [[ "${WITH_ATUIN:-0}" = "1" ]] || return 0   # opt-in
  section "atuin"

  # Pre-create config dirs so atuin's installer doesn't auto-register
  mkdir -p "$HOME/.config/atuin" "$HOME/.local/share/atuin"

  if have atuin; then
    ok "atuin present: $(atuin --version)"
  else
    log "installing atuin"
    local _tmp; _tmp="$(mktemp)"
    if curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh -o "$_tmp"; then
      # ATUIN_NO_REGISTRATION blocks installer's auto-registration step.
      # Even when honored, the installer still creates a local encryption key
      # at ~/.local/share/atuin/key — we delete that below so login uses
      # the real key entered by the user.
      if interactive; then
        ATUIN_NO_REGISTRATION=1 sh "$_tmp" --no-modify-path </dev/tty || warn "atuin installer exited non-zero"
      else
        ATUIN_NO_REGISTRATION=1 sh "$_tmp" --no-modify-path </dev/null >/dev/null 2>&1 || warn "atuin installer exited non-zero"
      fi
    else
      warn "could not download atuin installer"
    fi
    rm -f "$_tmp"
    [[ -x "$HOME/.atuin/bin/atuin" ]] && ln -sfn "$HOME/.atuin/bin/atuin" "$LOCAL_BIN/atuin"

    # Delete the auto-generated local key. atuin login will replace it with
    # the real key from your existing account, preventing silent mismatch.
    if [[ -f "$HOME/.local/share/atuin/key" ]]; then
      rm -f "$HOME/.local/share/atuin/key"
      log "removed auto-generated atuin key (login will install the real one)"
    fi
  fi

  if ! have atuin; then
    warn "atuin not on PATH after install; skipping login flow"
    return
  fi

  # Import existing zsh history into local atuin DB (idempotent; atuin dedupes)
  [[ -f "$HOME/.zsh_history" ]] && atuin import zsh >/dev/null 2>&1 || true

  if [[ "${SKIP_ATUIN_REGISTER:-0}" = "1" ]] || ! interactive; then
    log "skipping atuin login (run 'atuin login' manually)"
    return
  fi

  # Already logged in AND syncing cleanly? Skip.
  if atuin status 2>&1 | grep -qi 'logged in' && atuin sync >/dev/null 2>&1; then
    ok "atuin already logged in and syncing cleanly"
    return
  fi

  echo
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " Atuin sync setup"
  echo
  echo " You'll be prompted for username, password, and your encryption key."
  echo " The key is the 24-word mnemonic (or k4.lid... base64) from when you"
  echo " first registered. If you don't have it, save it from 1Password now."
  echo
  echo " (Choose 's' to skip and use atuin locally; you can run 'atuin login'"
  echo "  manually later, or 'atuin register' if this is your first machine.)"
  echo "═══════════════════════════════════════════════════════════════════════"
  local choice; choice="$(ask 'log in now? [Y/s]: ')"
  case "$choice" in
    s|S|skip)
      log "skipping atuin login; run 'atuin login' (or 'atuin register') later"
      ;;
    *)
      atuin login </dev/tty
      # 'atuin login' already does an initial sync; a second sync here can
      # trip atuin's client-side rate limit and exit non-zero even on success.
      # Run sync best-effort (visible output), then verify via 'atuin status'.
      atuin sync || true
      if atuin status 2>&1 | grep -qi 'logged in'; then
        ok "atuin login succeeded"
      else
        warn "atuin login may have failed; check 'atuin status'"
      fi
      ;;
  esac
}

# ============================================================================
# 6. mosh (mobile shell)
# ============================================================================
install_mosh() {
  [[ "${SKIP_MOSH:-0}" = "1" ]] && return
  section "mosh"
  if have mosh-server || have mosh; then ok "mosh present"; return; fi

  # 1. brew on Mac
  if pkg_install mosh; then ok "installed mosh via brew"; return; fi

  # 2. pixi (conda-forge installer, no sudo, no existing conda needed)
  if ensure_pixi; then
    if pixi global install mosh >/dev/null 2>&1; then
      [[ -x "$HOME/.pixi/bin/mosh" ]] && ln -sfn "$HOME/.pixi/bin/mosh" "$LOCAL_BIN/mosh"
      [[ -x "$HOME/.pixi/bin/mosh-server" ]] && ln -sfn "$HOME/.pixi/bin/mosh-server" "$LOCAL_BIN/mosh-server"
      [[ -x "$HOME/.pixi/bin/mosh-client" ]] && ln -sfn "$HOME/.pixi/bin/mosh-client" "$LOCAL_BIN/mosh-client"
      ok "installed mosh via pixi"
      return
    fi
  fi

  # 3. source build (last resort — needs autoconf/protoc available)
  log "attempting source build of mosh into ~/.local"
  local need=(autoconf automake make g++ pkg-config protoc)
  local missing=()
  for t in "${need[@]}"; do have "$t" || missing+=("$t"); done
  if (( ${#missing[@]} )); then
    warn "mosh source build needs: ${missing[*]} — skipping. Plain ssh works fine."
    return
  fi
  local tmp; tmp="$(mktemp -d)"
  (
    cd "$tmp"
    curl -fsSL https://github.com/mobile-shell/mosh/releases/latest/download/mosh-latest.tar.gz -o mosh.tgz
    tar xzf mosh.tgz
    cd mosh-*/
    ./configure --prefix="$HOME/.local" >/dev/null
    make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null
    make install >/dev/null
  ) && ok "built mosh from source" || warn "mosh build failed; plain ssh works fine"
  rm -rf "$tmp"
}

# ============================================================================
# 7. python toolchain (uv) and adjacents (hf, claude)
# ============================================================================
install_uv() {
  [[ "${SKIP_UV:-0}" = "1" ]] && return
  section "uv"
  if have uv; then ok "uv present: $(uv --version)"; return; fi
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
  ok "uv installed"
}

install_hf() {
  [[ "${SKIP_HF:-0}" = "1" ]] && return
  section "huggingface cli"
  if have hf; then ok "hf cli present"; return; fi

  # uv tool: isolated venv on a uv-managed python, so no python3-venv or other
  # system packages needed. Links hf into ~/.local/bin.
  if have uv; then
    uv tool install --quiet huggingface_hub >/dev/null 2>&1 || true
    have hf && { ok "hf installed via uv tool (update: uv tool upgrade huggingface_hub)"; return; }
  fi

  # Fallback: official installer (venv in ~/.hf-cli; needs python3 with venv)
  log "trying the official hf installer"
  if curl -LsSf https://hf.co/cli/install.sh | bash -s -- --no-modify-path 2>&1 | tail -5; then
    have hf && { ok "hf installed"; return; }
  fi

  warn "hf install failed. Try: uv tool install huggingface_hub"
}

# ============================================================================
# 7b. coding agents (claude, codex) + herdr — all self-updating single-user
#     installs into ~/.local/bin
# ============================================================================
# An old sudo install stays on disk but is shadowed: ~/.local/bin is first on PATH.
warn_root_owned() {
  warn "$1 at $(command -v "$1") is root-owned (old sudo install?); installing a user-local copy that shadows it"
  if [[ -n "${2:-}" ]]; then warn "  remove the old one when convenient: $2"; fi
}

install_claude_code() {
  [[ "${SKIP_CLAUDE_CODE:-0}" = "1" ]] && return
  section "claude code"
  if have_own claude; then ok "claude code present"; return; fi
  have claude && warn_root_owned claude "sudo npm uninstall -g @anthropic-ai/claude-code"
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 || true
  if [[ -x "$LOCAL_BIN/claude" ]]; then ok "claude code installed"; else warn "claude install failed"; fi
}

install_codex() {
  [[ "${SKIP_CODEX:-0}" = "1" ]] && return
  section "codex"
  if have_own codex; then ok "codex present"; return; fi
  have codex && warn_root_owned codex "sudo npm uninstall -g @openai/codex"
  # On seeing another codex on PATH, the installer appends a PATH block to the
  # rc file for $SHELL. SHELL=/bin/sh steers that to ~/.profile, away from
  # ~/.zshrc (a symlink into this repo).
  curl -fsSL https://chatgpt.com/codex/install.sh \
    | CODEX_NON_INTERACTIVE=1 SHELL=/bin/sh sh >/dev/null 2>&1 || true
  if [[ -x "$LOCAL_BIN/codex" ]]; then ok "codex installed (update: codex update)"; else warn "codex install failed"; fi
}

install_herdr() {
  [[ "${SKIP_HERDR:-0}" = "1" ]] && return
  section "herdr"
  if have_own herdr; then ok "herdr present"; return; fi
  have herdr && warn_root_owned herdr
  curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR="$LOCAL_BIN" sh >/dev/null 2>&1 || true
  if [[ -x "$LOCAL_BIN/herdr" ]]; then ok "herdr installed (update: herdr update)"; else warn "herdr install failed"; fi
}

# ============================================================================
# 8. globus connect personal — install + semi-interactive auth
# ============================================================================
install_globus() {
  [[ "${SKIP_GLOBUS:-0}" = "1" ]] && return
  section "globus connect personal"
  local dest="$HOME/.local/share/globus"
  local exe="$dest/globusconnectpersonal"
  if [[ -x "$exe" ]]; then
    ok "globus already installed at $dest"
  else
    mkdir -p "$dest"
    local tmp; tmp="$(mktemp -d)"
    log "downloading globus connect personal"
    curl -fsSL https://downloads.globus.org/globus-connect-personal/linux/stable/globusconnectpersonal-latest.tgz \
      -o "$tmp/gcp.tgz"
    tar xzf "$tmp/gcp.tgz" -C "$tmp"
    # Move the inner directory contents into $dest
    local inner; inner="$(find "$tmp" -maxdepth 1 -type d -name 'globusconnectpersonal-*' | head -1)"
    [[ -d "$inner" ]] || { warn "globus archive shape unexpected"; rm -rf "$tmp"; return 1; }
    cp -r "$inner"/* "$dest/"
    rm -rf "$tmp"
    chmod +x "$exe"
    # Also drop a launcher in $LOCAL_BIN
    cat > "$LOCAL_BIN/gcp" <<EOF
#!/usr/bin/env bash
exec "$exe" "\$@"
EOF
    chmod +x "$LOCAL_BIN/gcp"
    ok "globus installed at $dest (launcher: gcp)"
  fi

  if [[ "${SKIP_GLOBUS_AUTH:-0}" = "1" ]] || ! interactive; then
    log "skipping globus auth (run: gcp -setup <KEY> manually)"
    return
  fi

  # Already auth'd?
  if [[ -f "$dest/config-paths" || -f "$HOME/.globusonline/lta/config-paths" ]]; then
    ok "globus already configured"
    return
  fi

  echo
  echo "════════════════════════════════════════════════════════════════════"
  echo "Globus needs a one-time setup key to register this machine."
  echo
  echo "  1. Go to: https://app.globus.org/file-manager/gcp"
  echo "  2. Click 'Add a new endpoint' (or 'Create new')"
  echo "  3. Name it (e.g.  'eric-$(hostname -s)' )"
  echo "  4. Copy the setup key shown"
  echo
  echo "  (Or skip with: SKIP_GLOBUS_AUTH=1 — you can run 'gcp -setup KEY' later)"
  echo "════════════════════════════════════════════════════════════════════"
  local key; key="$(ask 'paste setup key (blank to skip): ')"
  if [[ -n "$key" ]]; then
    "$exe" -setup "$key" </dev/tty
    ok "globus configured. Start with: gcp -start &"
  else
    log "skipped globus auth"
  fi
}

# ============================================================================
# 9. github ssh key
# ============================================================================
setup_github_ssh() {
  [[ "${SKIP_SSH:-0}" = "1" ]] && return
  section "github ssh key"
  local key="$HOME/.ssh/id_ed25519"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [[ -f "$key" ]]; then
    ok "ssh key already exists at $key"
  else
    log "generating ed25519 key for $GITHUB_EMAIL"
    ssh-keygen -t ed25519 -C "$GITHUB_EMAIL" -f "$key" -N "" </dev/tty
  fi
  # Don't leave the agent dangling — let zsh/ssh-agent plugin manage it later.
  echo
  echo "Public key (add at https://github.com/settings/keys):"
  echo "─────────────────────────────────────────────────────"
  cat "$key.pub"
  echo "─────────────────────────────────────────────────────"
}

# ============================================================================
# 10. symlink home/* into $HOME
# ============================================================================
link_dotfiles() {
  section "symlinking dotfiles"
  local src="$DOTFILES_DIR/home"
  [[ -d "$src" ]] || { err "no home/ dir in $DOTFILES_DIR"; exit 1; }

  # Prune dangling links to files since removed from home/ (e.g. .tmux.conf)
  local d l
  while IFS= read -r -d '' d; do
    for l in "$HOME${d#$src}"/{.,}*; do
      [[ -L "$l" && ! -e "$l" && "$(readlink "$l")" == "$src/"* ]] || continue
      rm -f "$l"
      log "removed stale link $l"
    done
  done < <(find "$src" -type d -print0)

  # Walk all files in src; skip directories themselves (we recreate them)
  while IFS= read -r -d '' f; do
    local rel="${f#$src/}"
    local dst="$HOME/$rel"
    mkdir -p "$(dirname "$dst")"
    backup_if_real "$dst"
    ln -sfn "$f" "$dst"
    printf '  %s%s%s → %s\n' "$c_dim" "$dst" "$c_rst" "$f"
  done < <(find "$src" -type f -print0)
  ok "all dotfiles symlinked"
}

# ============================================================================
# 11. .bashrc trampoline (for servers where chsh isn't allowed)
# ============================================================================
write_bashrc_trampoline() {
  section "bashrc trampoline"
  local marker="# >>> bootstrap zsh trampoline >>>"
  local bashrc="$HOME/.bashrc"
  [[ -f "$bashrc" ]] || touch "$bashrc"
  if grep -qF "$marker" "$bashrc"; then ok ".bashrc trampoline already in place"; return; fi
  cat >> "$bashrc" <<'EOF'

# >>> bootstrap zsh trampoline >>>
# Auto-launch zsh on interactive logins where it's not the default shell
case $- in *i*) ;; *) return ;; esac
# a pixi-installed zsh lives in ~/.local/bin, which may not be on PATH yet here
_zsh="$(command -v zsh || echo "$HOME/.local/bin/zsh")"
if [ -x "$_zsh" ] && [ -z "$ZSH_VERSION" ] && [ "$SHLVL" = "1" ]; then
  exec "$_zsh" -l
fi
unset _zsh
# <<< bootstrap zsh trampoline <<<
EOF
  ok "added zsh trampoline to ~/.bashrc"
}

# ============================================================================
# 12. set zsh as default shell (if possible)
# ============================================================================
set_zsh_default() {
  [[ "${SKIP_CHSH:-0}" = "1" ]] && return
  section "default shell"
  local zsh_path; zsh_path="$(command -v zsh || true)"
  [[ -z "$zsh_path" ]] && { warn "zsh not found, skipping"; return; }
  if [[ "${SHELL:-}" = "$zsh_path" ]]; then ok "zsh already default"; return; fi

  # chsh prompts for your user password (not sudo). On clusters with LDAP/SSO,
  # users typically don't have a local password, so chsh hangs forever.
  # Skip chsh unless we have sudo (which means root can chsh without password).
  if ! have_sudo; then
    log "no sudo (and no local password expected); skipping chsh — .bashrc trampoline handles it"
    return
  fi

  if grep -qx "$zsh_path" /etc/shells 2>/dev/null && have chsh; then
    log "running sudo chsh -s $zsh_path for $USER"
    sudo chsh -s "$zsh_path" "$USER" 2>/dev/null \
      && ok "default shell changed; takes effect on next login" \
      || warn "chsh failed; .bashrc trampoline will handle it"
  else
    log "chsh not usable here; .bashrc trampoline will handle it"
  fi
}


# ============================================================================
# 10a. version-gated gitconfig keys → ~/.gitconfig.local
#      Tracked .gitconfig is conservative (works on old git); bootstrap upgrades
#      to features that need a newer git, written to the per-machine include.
# ============================================================================
setup_gitconfig_local() {
  section "gitconfig (version-gated)"
  if ! have git; then
    warn "git not on PATH; skipping version-gated gitconfig"
    return
  fi
  local v; v="$(git --version | awk '{print $3}')"
  local local_cfg="$HOME/.gitconfig.local"
  # merge.conflictStyle=zdiff3 needs git >= 2.35; older git aborts on it.
  local style="diff3"
  if printf '%s\n%s\n' "2.35" "$v" | sort -V -C; then
    style="zdiff3"
  fi
  git config --file "$local_cfg" merge.conflictstyle "$style"
  ok "git $v → merge.conflictstyle=$style (in $local_cfg)"
}

# ============================================================================
# 10b. merge statusLine config into ~/.claude/settings.json (CC owns this file,
#      so we don't symlink it — we patch it idempotently).
# ============================================================================
patch_claude_settings() {
  section "claude code statusline"
  local f="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  if ! have jq; then
    warn "jq not installed; skipping settings.json patch (statusline won't display)"
    return
  fi
  [[ -f "$f" ]] || echo '{}' > "$f"
  local tmp; tmp="$(mktemp)"
  jq '.statusLine = {type: "command", command: "bash ~/.claude/statusline.sh", padding: 0}' \
    "$f" > "$tmp" && mv "$tmp" "$f"
  ok "patched $f with statusLine -> ~/.claude/statusline.sh"
}

# ============================================================================
# main
# ============================================================================
main() {
  printf '\n%s========================================%s\n' "$c_blue" "$c_rst"
  printf '%s   Bootstrap starting on %s%s\n' "$c_blue" "$(hostname)" "$c_rst"
  printf '%s   sudo: %s | interactive: %s%s\n' "$c_blue" \
    "$(have_sudo && echo yes || echo no)" \
    "$(interactive && echo yes || echo no)" "$c_rst"
  printf '%s========================================%s\n' "$c_blue" "$c_rst"

  clone_dotfiles
  install_zsh
  install_antidote
  install_starship
  install_tools
  install_direnv
  install_uv
  install_hf
  install_claude_code
  install_codex
  install_herdr
  install_atuin       # opt-in (WITH_ATUIN=1); after zsh history is around
  install_mosh
  install_globus
  setup_github_ssh
  link_dotfiles
  setup_gitconfig_local
  patch_claude_settings
  write_bashrc_trampoline
  set_zsh_default

  printf '\n%s✓ done.%s start a new shell or run: %sexec zsh -l%s\n' \
    "$c_grn" "$c_rst" "$c_yel" "$c_rst"
}

main "$@"
