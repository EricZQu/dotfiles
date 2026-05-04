# ============================================================================
# ~/.zshrc — symlink target from ~/.dotfiles/home/.zshrc
# ============================================================================

# ─── PATH ──────────────────────────────────────────────────────────────────
typeset -U path
path=("$HOME/.local/bin" "$HOME/bin" "/usr/local/bin" $path)
export PATH

# ─── history ───────────────────────────────────────────────────────────────
HISTFILE="$HOME/.zsh_history"
HISTSIZE=1000000
SAVEHIST=1000000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS \
       HIST_VERIFY EXTENDED_HISTORY INC_APPEND_HISTORY

# ─── general options ───────────────────────────────────────────────────────
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT
setopt INTERACTIVE_COMMENTS NO_BEEP

# ─── antidote (plugin manager) ─────────────────────────────────────────────
ANTIDOTE_HOME="$HOME/.antidote"
if [[ -f "$ANTIDOTE_HOME/antidote.zsh" ]]; then
  source "$ANTIDOTE_HOME/antidote.zsh"
  # Compile a static plugin file (faster than dynamic load on every shell)
  zsh_plugins="$HOME/.zsh_plugins.zsh"
  if [[ ! "$zsh_plugins" -nt "$HOME/.zsh_plugins.txt" ]]; then
    antidote bundle <"$HOME/.zsh_plugins.txt" >"$zsh_plugins"
  fi
  source "$zsh_plugins"
fi

# ─── prompt: starship + transient ──────────────────────────────────────────
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"

  # Save starship's PROMPT/RPROMPT (which are command-substitution strings,
  # not rendered text — zsh re-runs the substitutions every prompt cycle).
  _starship_full_prompt="$PROMPT"
  _starship_full_rprompt="$RPROMPT"

  # Before each new prompt, restore PROMPT to the substitution string.
  # This undoes our transient swap so the next prompt is full again.
  _starship_restore_prompt() {
    PROMPT="$_starship_full_prompt"
    RPROMPT="$_starship_full_rprompt"
  }
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _starship_restore_prompt

  # On line submit, swap to the minimal transient prompt and redraw,
  # so scrollback shows just ❯ <command>.
  _starship_transient() {
    if [[ $PROMPT != '%F{green}❯%f ' ]]; then
      PROMPT='%F{green}❯%f '
      RPROMPT=''
      zle .reset-prompt 2>/dev/null
    fi
  }
  zle-line-finish() { _starship_transient }
  zle -N zle-line-finish
  TRAPINT() { _starship_transient; return $(( 128 + $1 )) }
fi

# ─── modern CLI integrations ───────────────────────────────────────────────
# zoxide: smarter cd; usage `z foo` jumps to most-used dir matching foo
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh --cmd cd)"

# direnv: auto-load .envrc on cd
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"

# atuin: shell history with sync; rebinds Ctrl+R
if command -v atuin >/dev/null 2>&1; then
  eval "$(atuin init zsh --disable-up-arrow)"   # keep up-arrow as plain history
fi

# fzf: fuzzy finder; provides Ctrl+R (overridden by atuin) and Ctrl+T (file picker)
[[ -f "$HOME/.fzf.zsh" ]] && source "$HOME/.fzf.zsh"

# ─── completion config ─────────────────────────────────────────────────────
# fzf-tab: fuzzy menu for tab completion
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath 2>/dev/null || ls -la $realpath'
zstyle ':fzf-tab:*' switch-group ',' '.'

# ─── aliases ───────────────────────────────────────────────────────────────
# Modern replacements (only if installed)
command -v eza >/dev/null 2>&1 && {
  alias ls='eza --group-directories-first'
  alias ll='eza -l --group-directories-first --git'
  alias la='eza -la --group-directories-first --git'
  alias lt='eza --tree --level=2 --group-directories-first'
}
command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never --style=plain'

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
alias uvx='uvx'
alias uvi='uv init'

# Git
alias gs='git status'
alias gd='git diff'
alias gdc='git diff --cached'
alias gl='git log --oneline --graph --decorate -20'
alias gp='git pull --ff-only'
alias gpu='git push'
alias gco='git checkout'
alias gcb='git checkout -b'

# Misc QoL
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias g='git'
alias v='vim'
alias rg='rg --hidden --glob=!.git'

# Quickly ssh-add the github key (needed once per session if not using ssh-agent plugin)
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
# Put per-machine tweaks (cluster modules, weird PATH, etc.) in ~/.zshrc.local
[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
