# ============================================================================
# ~/.bashrc — symlink target from ~/.dotfiles/home/.bashrc
#
# bash + ble.sh port of the old .zshrc:
#   antidote plugins          -> ble.sh (autosuggest, syntax highlight, menu
#                                completion) + small ports below (extract, ...)
#   fzf-tab                   -> ble.sh menu-complete + fzf integration
#   starship transient prompt -> bleopt prompt_ps1_final
# Everything degrades gracefully if ble.sh or any tool is missing.
# ============================================================================

# Non-interactive shells (scp, ssh host cmd, scripts) stop here.
case $- in *i*) ;; *) return ;; esac

# ─── PATH ──────────────────────────────────────────────────────────────────
_path_prepend() {
  case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac
}
_path_prepend /usr/local/bin
_path_prepend "$HOME/bin"
_path_prepend "$HOME/.local/bin"
export PATH
unset -f _path_prepend

# Old system bash (macOS 3.2)? hop into a newer one bootstrap installed.
if (( BASH_VERSINFO[0] < 4 )) && [[ $SHLVL == 1 && -x "$HOME/.local/bin/bash" ]]; then
  exec "$HOME/.local/bin/bash" -l
fi

# ─── ble.sh (must be sourced first, attached last) ─────────────────────────
# --noattach: load now so later init (starship, atuin, fzf) can detect it,
# then `ble-attach` at the very end of this file.
_blesh="${BLESH_DIR:-$HOME/.local/share/blesh}/ble.sh"
if [[ -f "$_blesh" ]]; then
  source "$_blesh" --noattach          # reads ~/.blerc
fi
unset _blesh
_has_ble() { [[ ${BLE_VERSION-} ]]; }

# ─── history ───────────────────────────────────────────────────────────────
HISTFILE="$HOME/.bash_history"
HISTSIZE=1000000
HISTFILESIZE=1000000
HISTCONTROL=ignoreboth:erasedups       # HIST_IGNORE_ALL_DUPS + HIST_IGNORE_SPACE
HISTTIMEFORMAT='%F %T  '               # EXTENDED_HISTORY
shopt -s histappend histverify cmdhist lithist
# SHARE_HISTORY: ble.sh does this itself (bleopt history_share in ~/.blerc);
# plain bash needs the PROMPT_COMMAND dance.
if ! _has_ble; then
  PROMPT_COMMAND="history -a; history -c; history -r${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi

# ─── general options ───────────────────────────────────────────────────────
shopt -s autocd cdspell dirspell checkwinsize globstar extglob nocaseglob 2>/dev/null
# interactive comments are on by default in bash; no beeping:
bind 'set bell-style none'
bind 'set completion-ignore-case on'
bind 'set colored-stats on'
bind 'set show-all-if-ambiguous on'
# AUTO_PUSHD has no bash equivalent (zoxide's cd below replaces most of it).

# ─── bash-completion ───────────────────────────────────────────────────────
if ! shopt -oq posix; then
  if [[ -f /usr/share/bash-completion/bash_completion ]]; then
    . /usr/share/bash-completion/bash_completion
  elif [[ -f /etc/bash_completion ]]; then
    . /etc/bash_completion
  elif [[ -f /opt/homebrew/etc/profile.d/bash_completion.sh ]]; then
    . /opt/homebrew/etc/profile.d/bash_completion.sh
  fi
fi

[[ -x /usr/bin/lesspipe ]] && eval "$(SHELL=/bin/sh lesspipe)"

# ─── prompt: starship + transient ──────────────────────────────────────────
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init bash)"
  # Transient prompt: after Enter, collapse the old prompt to just "❯ cmd".
  # (needs ble.sh; harmless otherwise)
  if _has_ble; then
    bleopt prompt_ps1_final=$'\e[32m❯\e[m '
    bleopt prompt_rps1_final=
  fi
fi

# ─── modern CLI integrations ───────────────────────────────────────────────
# zoxide: smarter cd; usage `z foo` jumps to most-used dir matching foo
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash --cmd cd)"

# direnv: auto-load .envrc on cd
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"

# fzf: Ctrl+T (files), Alt+C (cd), Ctrl+R (history; atuin overrides below),
# and `**<TAB>` fuzzy completion.
if command -v fzf >/dev/null 2>&1; then
  if _has_ble; then
    ble-import integration/fzf-key-bindings
    ble-import integration/fzf-completion
  elif [[ -f "$HOME/.fzf.bash" ]]; then
    source "$HOME/.fzf.bash"
  fi
fi

# atuin: shell history with sync; rebinds Ctrl+R. Opt-in: only installed by
# `WITH_ATUIN=1 bootstrap.sh`, so this is a no-op on machines without it.
# Must come after fzf so it wins Ctrl+R. Works with ble.sh natively
# (without ble.sh it needs bash-preexec, so skip it then).
if command -v atuin >/dev/null 2>&1 && { _has_ble || [[ ${bash_preexec_imported-} ]]; }; then
  eval "$(atuin init bash --disable-up-arrow)"   # keep up-arrow as plain history
fi

# uv completions (OMZ uv plugin)
command -v uv  >/dev/null 2>&1 && eval "$(uv generate-shell-completion bash 2>/dev/null)"
command -v uvx >/dev/null 2>&1 && eval "$(uvx --generate-shell-completion bash 2>/dev/null)"

# ─── aliases ───────────────────────────────────────────────────────────────
# Modern replacements (only if installed)
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first'
  alias ll='eza -l --group-directories-first --git'
  alias la='eza -la --group-directories-first --git'
  alias lt='eza --tree --level=2 --group-directories-first'
else
  alias ls='ls --color=auto --group-directories-first'
  alias ll='ls -lh'
  alias la='ls -lAh'
fi
command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never --style=plain'
alias grep='grep --color=auto'

# Slurm
alias q='squeue'
alias myq='squeue -u $USER -o "%.18i %14P %50j %.8u %.4t %.10l %.10M %.6D %R"'
sout() { scontrol show jobid -dd "$1" | grep StdOut | cut -d= -f2 | xargs tail; }
serr() { scontrol show jobid -dd "$1" | grep StdErr | cut -d= -f2 | xargs tail; }
wout() { scontrol show jobid -dd "$1" | grep StdOut | cut -d= -f2 | xargs watch tail; }
werr() { scontrol show jobid -dd "$1" | grep StdErr | cut -d= -f2 | xargs watch tail; }
vout() { vim "$(scontrol show jobid -dd "$1" | grep StdOut | cut -d= -f2)"; }
verr() { vim "$(scontrol show jobid -dd "$1" | grep StdErr | cut -d= -f2)"; }

# Conda (legacy envs)
alias cda='conda deactivate'
ca()  { conda activate "$1"; }

# uv shortcuts
alias uvr='uv run'
alias uvs='uv sync'
alias uva='uv add'
alias uvi='uv init'

# Git (explicit ones + the OMZ git-plugin aliases that actually get used)
alias gs='git status'
alias gd='git diff'
alias gdc='git diff --cached'
alias gl='git log --oneline --graph --decorate -20'
alias gp='git pull --ff-only'
alias gpu='git push'
alias gco='git checkout'
alias gcb='git checkout -b'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit -v'
alias gcmsg='git commit -m'
alias gst='git status'
alias gb='git branch'
alias gf='git fetch'
alias gsw='git switch'
alias gsta='git stash push'
alias gstp='git stash pop'

# Misc QoL
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias g='git'
alias v='vim'
alias rg='rg --hidden --glob=!.git'

# OMZ `history`, `cp`, `python` plugin leftovers
alias h='history'
hs()  { history | grep -i -- "$@"; }
alias cpv='rsync -pogbr -hhh --backup-dir=/tmp/rsync -e /dev/null --progress'
alias pyfind='find . -name "*.py"'
pygrep() { grep -nr --include="*.py" -- "$@" .; }
pyclean() {
  find "${@:-.}" -type f -name '*.py[co]' -delete
  find "${@:-.}" -type d -name __pycache__ -delete
}

# ─── helpers ported from OMZ plugins ───────────────────────────────────────
# Clipboard sink: pbcopy / wl-copy / xclip / xsel, else OSC52 (works over ssh).
_clip() {
  if   command -v pbcopy   >/dev/null 2>&1; then pbcopy
  elif command -v wl-copy  >/dev/null 2>&1 && [[ -n ${WAYLAND_DISPLAY-} ]]; then wl-copy
  elif command -v xclip    >/dev/null 2>&1 && [[ -n ${DISPLAY-} ]]; then xclip -selection clipboard
  elif command -v xsel     >/dev/null 2>&1 && [[ -n ${DISPLAY-} ]]; then xsel --clipboard --input
  else printf '\e]52;c;%s\a' "$(base64 | tr -d '\n')" > /dev/tty
  fi
}
copypath() { local p; p="$(realpath "${1:-.}")" && printf %s "$p" | _clip && echo "copied: $p"; }
copyfile() { [[ -f "$1" ]] || { echo "usage: copyfile <file>"; return 1; }; _clip < "$1" && echo "copied $1"; }
# copybuffer (Ctrl+O): copy the current command line to the clipboard
_copybuffer() { printf %s "$READLINE_LINE" | _clip; }
bind -x '"\C-o": _copybuffer' 2>/dev/null

# extract: unpack almost any archive
extract() {
  local f
  (( $# )) || { echo "usage: extract <archive>..."; return 1; }
  for f in "$@"; do
    [[ -f "$f" ]] || { echo "extract: '$f' is not a file" >&2; continue; }
    case "${f,,}" in
      *.tar.gz|*.tgz)   tar xzvf "$f" ;;
      *.tar.bz2|*.tbz2) tar xjvf "$f" ;;
      *.tar.xz|*.txz)   tar xJvf "$f" ;;
      *.tar.zst)        tar --zstd -xvf "$f" ;;
      *.tar)            tar xvf "$f" ;;
      *.gz)             gunzip -k "$f" ;;
      *.bz2)            bunzip2 -k "$f" ;;
      *.xz)             unxz -k "$f" ;;
      *.zst)            unzstd "$f" ;;
      *.zip|*.whl|*.jar) unzip "$f" ;;
      *.7z)             7z x "$f" ;;
      *.rar)            unrar x "$f" ;;
      *.deb)            ar x "$f" ;;
      *) echo "extract: don't know how to extract '$f'" >&2 ;;
    esac
  done
}

# Quickly ssh-add the github key (needed once per session if not using ssh-agent)
ghkey() {
  eval "$(ssh-agent -s)" >/dev/null
  ssh-add "$HOME/.ssh/id_ed25519"
}

# Move to a project's worktree quickly
gw() {
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo"; return 1; }
  cd "$root"
}

# ─── machine-local overrides (untracked) ───────────────────────────────────
# Put per-machine tweaks (cluster modules, weird PATH, etc.) in ~/.bashrc.local
[[ -f "$HOME/.bashrc.local" ]] && source "$HOME/.bashrc.local"

# ─── ble.sh: attach (must be last) ─────────────────────────────────────────
[[ ${BLE_VERSION-} ]] && ble-attach
unset -f _has_ble
