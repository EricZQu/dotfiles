#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Eric's server bootstrap
#
# Quickstart on a fresh machine:
#   curl -fsSL https://raw.githubusercontent.com/ericqu/dotfiles/main/bootstrap.sh | bash
#
# Or with overrides:
#   REPO_URL=https://github.com/ericqu/dotfiles.git \
#   GITHUB_EMAIL=ericqu@berkeley.edu \
#   bash bootstrap.sh
#
# Env flags (all optional, set to 1 to skip):
#   SKIP_TOOLS          fzf/zoxide/eza/bat/ripgrep/jq
#   SKIP_UV             uv install
#   SKIP_HF             huggingface cli
#   SKIP_CLAUDE_CODE    claude code cli
#   SKIP_DIRENV         direnv
#   SKIP_ATUIN          atuin
#   SKIP_ATUIN_REGISTER skip the interactive register/login step
#   SKIP_MOSH           mosh
#   SKIP_GLOBUS         globus connect personal
#   SKIP_GLOBUS_AUTH    install globus but don't pause for setup key
#   SKIP_SSH            github ssh keygen
#   SKIP_CHSH           don't try chsh; rely on .bashrc trampoline
#   ASSUME_YES=1        non-interactive mode (skip all interactive steps)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/ericqu/dotfiles.git}"
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
have_sudo() { have sudo && sudo -n true 2>/dev/null; }
is_linux()  { [[ "$(uname -s)" = "Linux" ]]; }
is_macos()  { [[ "$(uname -s)" = "Darwin" ]]; }
interactive(){ [[ -z "${ASSUME_YES:-}" && -t 0 && -t 1 ]]; }
ask()       { local p="$1" reply; read -r -p "$p" reply </dev/tty; printf '%s\n' "$reply"; }
confirm()   {
  interactive || return 0
  local p="$1" reply
  read -r -p "$p [Y/n] " reply </dev/tty
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# Detect arch for binary downloads
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH_GNU=x86_64-unknown-linux-gnu;  ARCH_MUSL=x86_64-unknown-linux-musl ;;
  aarch64|arm64) ARCH_GNU=aarch64-unknown-linux-gnu; ARCH_MUSL=aarch64-unknown-linux-musl ;;
  *) warn "unknown arch '$ARCH' — some binary downloads may fail" ;;
esac

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
case ":$PATH:" in *":$LOCAL_BIN:"*) ;; *) export PATH="$LOCAL_BIN:$PATH" ;; esac

# Try sudo apt install, fall back silently
apt_install() {
  have_sudo || return 1
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
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
  if apt_install zsh; then ok "installed zsh via apt"; return; fi
  if is_macos && have brew; then brew install zsh && return; fi
  warn "could not install zsh and don't have permissions; ask sysadmin"
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
  if apt_install jq; then return; fi
  install_release_binary jq \
    "https://github.com/jqlang/jq/releases/latest/download/jq-linux-${ARCH/aarch64/arm64}" "" raw
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
  apt_install eza && return || true
  # GH releases (musl static)
  install_release_binary eza \
    "https://github.com/eza-community/eza/releases/latest/download/eza_${ARCH_MUSL}.tar.gz" eza
}

install_bat() {
  have bat && return
  log "installing bat"
  apt_install bat && {
    # Debian/Ubuntu rename to batcat to avoid conflict
    have batcat && ! have bat && ln -sfn "$(command -v batcat)" "$LOCAL_BIN/bat"
    return
  } || true
  # Fall back to GH releases
  local ver; ver="$(curl -fsSL https://api.github.com/repos/sharkdp/bat/releases/latest | grep -oE '"tag_name":\s*"v[^"]+"' | head -1 | grep -oE 'v[0-9.]+')"
  [[ -z "$ver" ]] && { warn "couldn't get bat version"; return 1; }
  install_release_binary bat \
    "https://github.com/sharkdp/bat/releases/download/${ver}/bat-${ver}-${ARCH_MUSL}.tar.gz" \
    "bat-${ver}-${ARCH_MUSL}/bat"
}

install_ripgrep() {
  have rg && return
  log "installing ripgrep"
  apt_install ripgrep && return || true
  local ver; ver="$(curl -fsSL https://api.github.com/repos/BurntSushi/ripgrep/releases/latest | grep -oE '"tag_name":\s*"[^"]+"' | head -1 | grep -oE '[0-9.]+')"
  [[ -z "$ver" ]] && { warn "couldn't get ripgrep version"; return 1; }
  install_release_binary rg \
    "https://github.com/BurntSushi/ripgrep/releases/download/${ver}/ripgrep-${ver}-${ARCH_MUSL}.tar.gz" \
    "ripgrep-${ver}-${ARCH_MUSL}/rg"
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
}

# ============================================================================
# 5. direnv + atuin
# ============================================================================
install_direnv() {
  [[ "${SKIP_DIRENV:-0}" = "1" ]] && return
  section "direnv"
  if have direnv; then ok "direnv present: $(direnv --version)"; return; fi
  apt_install direnv && return || true
  log "installing direnv → $LOCAL_BIN"
  curl -sfL https://direnv.net/install.sh | bin_path="$LOCAL_BIN" bash
  ok "direnv installed"
}

install_atuin() {
  [[ "${SKIP_ATUIN:-0}" = "1" ]] && return
  section "atuin"
  if have atuin; then ok "atuin present: $(atuin --version)"; else
    log "installing atuin"
    curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh -s -- --no-modify-path >/dev/null
    # The installer puts it at ~/.atuin/bin/atuin
    [[ -x "$HOME/.atuin/bin/atuin" ]] && ln -sfn "$HOME/.atuin/bin/atuin" "$LOCAL_BIN/atuin"
  fi

  # Import existing zsh history into atuin DB (safe to re-run; atuin dedupes)
  [[ -f "$HOME/.zsh_history" ]] && atuin import zsh >/dev/null 2>&1 || true

  if [[ "${SKIP_ATUIN_REGISTER:-0}" = "1" ]] || ! interactive; then
    log "skipping atuin register (run 'atuin register' or 'atuin login' manually)"
    return
  fi

  # Check if already logged in by trying a sync
  if atuin status 2>&1 | grep -qi 'logged in'; then
    ok "atuin already logged in on this machine"
    return
  fi

  echo
  echo "Atuin sync setup. Choose:"
  echo "  [1] register a new account"
  echo "  [2] login to existing account"
  echo "  [3] skip (local-only history)"
  local choice; choice="$(ask 'choice [1/2/3]: ')"
  case "$choice" in
    1) atuin register </dev/tty ;;
    2) atuin login </dev/tty ;;
    *) log "skipping atuin login; you can run 'atuin register' or 'atuin login' later" ;;
  esac
}

# ============================================================================
# 6. mosh (mobile shell)
# ============================================================================
install_mosh() {
  [[ "${SKIP_MOSH:-0}" = "1" ]] && return
  section "mosh"
  if have mosh-server || have mosh; then ok "mosh present"; return; fi
  if apt_install mosh; then ok "installed mosh via apt"; return; fi
  if is_macos && have brew; then brew install mosh && return; fi

  # Try conda-forge if conda is around — clean way to get mosh without sudo
  if have conda; then
    log "trying mosh from conda-forge"
    if conda install -y -n base -c conda-forge mosh >/dev/null 2>&1; then
      ok "installed mosh via conda-forge"
      return
    fi
  fi

  # Build from source as last resort
  log "attempting source build of mosh into ~/.local"
  local need=(autoconf automake make g++ pkg-config protoc)
  local missing=()
  for t in "${need[@]}"; do have "$t" || missing+=("$t"); done
  if (( ${#missing[@]} )); then
    warn "mosh source build needs: ${missing[*]} — skipping. Install via your sysadmin or use plain ssh."
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
  ) && ok "built mosh from source" || warn "mosh build failed; you can use plain ssh"
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
  curl -LsSf https://hf.co/cli/install.sh | bash >/dev/null 2>&1 || warn "hf install failed"
  have hf && ok "hf installed"
}

install_claude_code() {
  [[ "${SKIP_CLAUDE_CODE:-0}" = "1" ]] && return
  section "claude code"
  if have claude; then ok "claude code present"; return; fi
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 || warn "claude install failed"
  have claude && ok "claude code installed"
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
if [ -x "$(command -v zsh)" ] && [ -z "$ZSH_VERSION" ] && [ "$SHLVL" = "1" ]; then
  exec zsh -l
fi
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
  if grep -qx "$zsh_path" /etc/shells 2>/dev/null && have chsh; then
    log "running chsh -s $zsh_path"
    chsh -s "$zsh_path" </dev/tty 2>/dev/null \
      && ok "default shell changed; takes effect on next login" \
      || warn "chsh failed; .bashrc trampoline will handle it"
  else
    log "chsh not usable here; .bashrc trampoline will handle it"
  fi
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
  install_atuin       # after zsh history is around
  install_mosh
  install_globus
  setup_github_ssh
  link_dotfiles
  write_bashrc_trampoline
  set_zsh_default

  printf '\n%s✓ done.%s start a new shell or run: %sexec zsh -l%s\n' \
    "$c_grn" "$c_rst" "$c_yel" "$c_rst"
}

main "$@"
