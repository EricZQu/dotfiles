# dotfiles

Bootstrap script + dotfiles for fast setup on any new server.

```
zsh + antidote + starship + claude-code + uv + atuin + direnv + mosh
```

## Quickstart

On a fresh machine:

```bash
curl -fsSL https://raw.githubusercontent.com/ericqu/dotfiles/main/bootstrap.sh | bash
```

That's it. The script:

1. Installs zsh (apt if sudo available, else warns)
2. Clones this repo to `~/.dotfiles`
3. Installs the antidote plugin manager
4. Installs Starship (single binary to `~/.local/bin`)
5. Installs modern CLI tools: jq, fzf, zoxide, eza, bat, ripgrep
6. Installs direnv, uv, hf cli, claude code
7. Installs atuin and (if interactive) prompts for register/login
8. Installs mosh (apt → conda-forge → source-build chain)
9. Installs Globus Connect Personal and (if interactive) prompts for setup key
10. Generates a github SSH key and prints the pubkey
11. Symlinks every file under `home/` into `$HOME`
12. Adds a `.bashrc` trampoline that auto-launches zsh on machines where chsh isn't allowed
13. Tries `chsh -s /usr/bin/zsh`

Everything is **idempotent** — re-running on an existing server just updates what changed.

## Repository layout

```
dotfiles/
├── bootstrap.sh                  # the installer (run via curl|bash)
├── README.md
└── home/                         # mirrors $HOME; everything here gets symlinked
    ├── .zshrc
    ├── .zsh_plugins.txt          # antidote plugin list (compiled to .zsh_plugins.zsh on first shell)
    ├── .gitconfig                # identity + modern git defaults + delta config
    ├── .tmux.conf
    └── .config/
        ├── starship.toml
        ├── direnv/direnvrc       # contains layout_uv shim
        ├── atuin/config.toml
        └── claude/
            ├── settings.json     # wires statusLine to statusline.sh
            ├── statusline.sh     # custom two-line statusline (model, ctx, $/h, tpm, GPU, slurm)
            └── statusline.env    # per-machine SHOW_* toggles
```

## Environment flags

Pass these as env vars when running bootstrap, e.g. `SKIP_GLOBUS=1 bash bootstrap.sh`.

| Flag | Effect |
|---|---|
| `REPO_URL` | git URL of this repo (default: `https://github.com/ericqu/dotfiles.git`) |
| `DOTFILES_DIR` | clone target (default: `~/.dotfiles`) |
| `GITHUB_EMAIL` | email for the SSH key (default: `ericqu@berkeley.edu`) |
| `ASSUME_YES=1` | non-interactive: skip atuin register, ssh keygen prompts, globus auth |
| `SKIP_TOOLS=1` | skip fzf/zoxide/eza/bat/ripgrep |
| `SKIP_DIRENV=1` | skip direnv |
| `SKIP_UV=1` / `SKIP_HF=1` / `SKIP_CLAUDE_CODE=1` | skip those installs |
| `SKIP_ATUIN=1` | skip atuin entirely |
| `SKIP_ATUIN_REGISTER=1` | install atuin but don't prompt for register/login |
| `SKIP_MOSH=1` | skip mosh |
| `SKIP_GLOBUS=1` | skip globus |
| `SKIP_GLOBUS_AUTH=1` | install globus but don't prompt for setup key |
| `SKIP_SSH=1` | skip github SSH keygen |
| `SKIP_CHSH=1` | don't try chsh; rely on .bashrc trampoline |

## What's where

### Prompt: Starship

P10k-lean inspired, two-line, transient. Config in `home/.config/starship.toml`.
The transient prompt feature (replace previous prompts with a minimal version
after Enter) is wired up in `home/.zshrc` via zsh's `zle` hooks — Starship
itself doesn't have native zsh transient support but this emulates p10k.

### Plugins: antidote (loads OMZ plugins)

Antidote replaces oh-my-zsh as the framework but loads OMZ plugins natively.
Result: same plugin list you're used to (git, extract, copy*, uv, tmux, etc.)
but ~5–10× faster shell startup.

The plugin list lives at `home/.zsh_plugins.txt`. Edit it and start a new
shell — antidote rebuilds the compiled bundle automatically.

### Modern CLI tools

| Tool | Replaces | Trigger |
|---|---|---|
| eza | ls | `ls`, `ll`, `la`, `lt` aliases |
| bat | cat | `cat` alias (no paging, plain style) |
| ripgrep | grep -r | `rg` (with `--hidden` and `!.git`) |
| delta | diff pager | git diff/log/show (configured in .gitconfig) |
| zoxide | cd | `cd foo` jumps to most-used dir matching foo (overrides cd!) |
| fzf | — | `Ctrl+T` for files, `Ctrl+R` for history (overridden by atuin) |
| fzf-tab | tab menu | tab now opens a fuzzy interactive picker |
| direnv | manual venv activation | drop a `.envrc` containing `layout uv` |
| atuin | shell history | `Ctrl+R` for fuzzy + cross-machine sync |
| mosh | ssh | `mosh server` for sessions that survive network changes |

### uv + direnv pattern

```bash
mkdir myproject && cd myproject
uv init                      # creates pyproject.toml
echo 'layout uv' > .envrc    # tells direnv to use the uv layout
direnv allow                 # one-time approval
uv add torch numpy           # add dependencies

# now every time you cd into myproject:
#   - .venv/ gets created (first time) or activated
#   - PATH and VIRTUAL_ENV are set
# cd out → unloaded automatically
```

The `layout_uv` shim is in `home/.config/direnv/direnvrc`.

### Git config

`~/.gitconfig` is identity (`Eric Qu / ericqu@berkeley.edu / EricZQu`) plus
modern defaults: `pull.ff = only`, `push.autoSetupRemote = true`,
`fetch.prune = true`, `rerere.enabled`, `merge.conflictStyle = zdiff3`,
histogram diff, and delta as the pager.

Per-machine overrides go in `~/.gitconfig.local` (untracked, sourced via
`[include]` from the main file). Useful for:

```ini
# different identity for work commits
[user]
	email = ericqu@meta.com

# proxy for restricted networks
[http]
	proxy = http://proxy.internal:8080
```

To enable SSH commit signing (uses your existing `~/.ssh/id_ed25519`),
uncomment the section at the bottom of `.gitconfig` and add the same key
to GitHub at https://github.com/settings/keys with type **Signing Key**.

### Slurm helpers

Inherited from your previous setup:

```
q              # squeue
myq            # your jobs, formatted
sout <jobid>   # tail StdOut
serr <jobid>   # tail StdErr
wout / werr    # watch tail
vout / verr    # vim the log file
```

### Custom Claude Code statusline

Two-line, ML-aware. Reads JSON from stdin (per CC's spec), prints:

```
🖥  bair-04 │ 📂 escaip (main *2 +1) │ 🐍 escaip │ 🎮 4×H100 87% │ 🧪 3 jobs
🤖 Opus 4.7 │ 💭 ███░░░░░░░ 31% │ 💸 $0.34 ($2.10/h) │ 📊 296k (1120 tpm) │ ⏱  ██░░░░░░░░ 23% 3h59m
```

- `4×H100 87%` — GPU count, model, average util across cards (cached 5s)
- `3 jobs` — your slurm queue size
- `$2.10/h` — cost burn rate, derived from `total_cost_usd / total_duration_ms`
- `1120 tpm` — tokens per minute throughput
- `23% 3h59m` — five-hour rate-limit usage and time to reset

Toggle pieces in `~/.config/claude/statusline.env`:

```bash
SHOW_GPU=0      # disable GPU readout on CPU-only login nodes
SHOW_SLURM=0    # disable slurm readout off-cluster
HOST_COLORS=("bair-:36" "fair-:35")   # color-code hostnames by cluster
```

### Atuin sync

By default points at `https://api.atuin.sh` (their hosted server, free, E2E
encrypted). To self-host later, edit `~/.config/atuin/config.toml` and add:

```toml
sync_address = "https://your.atuin.server"
```

To set up sync on a new machine:

```bash
atuin login -u <username> -k '<your encryption key>'
atuin sync
```

Save the encryption key shown at first registration somewhere safe — it's the
only thing that can decrypt your history.

### Globus

Installed at `~/.local/share/globus`. Launcher `gcp` is in `~/.local/bin`.

```bash
gcp -setup KEY     # if you skipped during bootstrap
gcp -start &       # start the daemon (will run until logout)
```

To make it survive logout on a Linux server:

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/globus.service <<EOF
[Unit]
Description=Globus Connect Personal
[Service]
ExecStart=%h/.local/share/globus/globusconnectpersonal -start
Restart=on-failure
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now globus
loginctl enable-linger $USER   # makes user-systemd survive logout (needs sudo on most distros)
```

## Per-machine overrides

Two escape hatches for things that should NOT be in version control:

- `~/.zshrc.local` — sourced at the end of `.zshrc`. Put cluster-specific
  module loads, weird `PATH` additions, etc. here. Untracked.
- `.envrc` per-project — for project-specific `CUDA_VISIBLE_DEVICES`,
  `WANDB_PROJECT`, `HF_HOME`, etc.

## Updating

```bash
cd ~/.dotfiles && git pull
# changes to symlinked files take effect immediately
# changes to bootstrap.sh: re-run it
```

To re-run the bootstrap and pick up new tools added since:

```bash
bash ~/.dotfiles/bootstrap.sh
```

## Troubleshooting

**`exec zsh -l` fails after bootstrap.** Check that `zsh` is on `PATH`:
`which zsh`. If not, the install step probably failed silently — try
`apt list --installed | grep zsh`.

**Plugins don't load.** Antidote compiles plugin source on first shell startup.
If it's stale, delete `~/.zsh_plugins.zsh` and start a new shell.

**Statusline shows nothing.** Verify `bash ~/.config/claude/statusline.sh < /dev/null`
runs without error. If `jq: command not found`, install jq (it's part of
the `tools` step in bootstrap; might have been skipped).

**Mosh "could not connect" on a cluster.** Likely UDP ports 60000–61000 are
blocked. Fall back to plain ssh; mosh is opt-in per session anyway.

**Globus daemon dies on logout.** Use the systemd-user service shown above,
plus `loginctl enable-linger`.

**Conda doesn't activate fast enough.** The OMZ `python` plugin and Starship's
`conda` module both probe conda; if your `conda init` block is heavy, consider
moving it into `~/.zshrc.local` and lazy-loading.

## Editing on a server

Real files live in `~/.dotfiles/home/`. The files in `$HOME` are symlinks.
So:

```bash
vim ~/.zshrc                 # actually edits ~/.dotfiles/home/.zshrc
cd ~/.dotfiles && git diff   # see your change
git commit -am "tweak" && git push
# on every other machine: cd ~/.dotfiles && git pull
```
