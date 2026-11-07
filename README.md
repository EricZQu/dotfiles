# dotfiles

Bootstrap script + dotfiles for fast setup on any new server.

```
bash + ble.sh + starship + claude-code + codex + herdr + uv + hf + direnv + mosh  (+ atuin, opt-in)
```

## Quickstart

On a fresh machine:

```bash
curl -fsSL https://raw.githubusercontent.com/EricZQu/dotfiles/main/bootstrap.sh | bash
```

That's it. The script:

1. Checks for bash ≥ 4.3 (installs one via brew/pixi if the system bash is older, e.g. macOS)
2. Clones this repo to `~/.dotfiles`
3. Installs [ble.sh](https://github.com/akinomyoga/ble.sh) (prebuilt nightly → `~/.local/share/blesh`)
4. Installs Starship (single binary to `~/.local/bin`)
5. Installs modern CLI tools: jq, fzf, zoxide, eza, bat, ripgrep
6. Installs direnv, uv, hf cli, claude code, codex, herdr
7. *(opt-in, `WITH_ATUIN=1`)* Installs atuin and (if interactive) prompts for register/login
8. Installs mosh (brew → pixi/conda-forge → source-build chain)
9. Installs Globus Connect Personal and (if interactive) prompts for setup key
10. Generates a github SSH key and prints the pubkey
11. Symlinks every file under `home/` into `$HOME`

Everything is **idempotent** — re-running on an existing server just updates what changed.

**Nothing is installed with sudo.** Every tool goes under `$HOME` (`~/.local/bin`,
`~/.pixi`, …), so self-updaters like `claude`, `codex` and `herdr update` work
without root and nothing ends up root-owned. If an old sudo install of
claude/codex/herdr is found, bootstrap installs a user-local copy that shadows it
(`~/.local/bin` is first on `PATH`) and tells you how to remove the old one. The
script refuses to run under `sudo`. There is no `chsh` step: bash stays your login shell.

## Repository layout

```
dotfiles/
├── bootstrap.sh                  # the installer (run via curl|bash)
├── README.md
└── home/                         # mirrors $HOME; everything here gets symlinked
    ├── .bashrc
    ├── .blerc                    # ble.sh settings (autosuggest, menu completion, history)
    ├── .gitconfig                # identity + modern git defaults + delta config
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
| `REPO_URL` | git URL of this repo (default: `https://github.com/EricZQu/dotfiles.git`) |
| `DOTFILES_DIR` | clone target (default: `~/.dotfiles`) |
| `GITHUB_EMAIL` | email for the SSH key (default: `ericqu@berkeley.edu`) |
| `ASSUME_YES=1` | non-interactive: skip atuin register, ssh keygen prompts, globus auth |
| `SKIP_TOOLS=1` | skip fzf/zoxide/eza/bat/ripgrep |
| `SKIP_DIRENV=1` | skip direnv |
| `SKIP_UV=1` / `SKIP_HF=1` / `SKIP_CLAUDE_CODE=1` / `SKIP_CODEX=1` / `SKIP_HERDR=1` | skip those installs |
| `WITH_ATUIN=1` | **opt in** to atuin (off by default) |
| `SKIP_ATUIN_REGISTER=1` | with `WITH_ATUIN=1`: install atuin but don't prompt for register/login |
| `SKIP_MOSH=1` | skip mosh |
| `SKIP_GLOBUS=1` | skip globus |
| `SKIP_GLOBUS_AUTH=1` | install globus but don't prompt for setup key |
| `SKIP_SSH=1` | skip github SSH keygen |
| `SKIP_BLESH=1` | skip ble.sh |
| `BLESH_UPDATE=1` | re-download ble.sh even if already installed |

## What's where

### Prompt: Starship

P10k-lean inspired, two-line, transient. Config in `home/.config/starship.toml`.
The transient prompt (replace previous prompts with a minimal `❯` after Enter)
comes from ble.sh's `bleopt prompt_ps1_final`, set in `home/.bashrc`. Without
ble.sh you still get the full Starship prompt, just not the collapsing.

### Line editor: ble.sh (replaces antidote + zsh plugins)

| zsh setup | bash setup |
|---|---|
| zsh-autosuggestions | ble.sh auto-complete (grey ghost text; Right/End/Ctrl+F accepts) |
| fast-syntax-highlighting | ble.sh built-in highlighting |
| fzf-tab | `Tab` opens a ble.sh menu (arrows / type to filter); fzf `**<Tab>` |
| `SHARE_HISTORY` etc. | `bleopt history_share=1`, `HISTCONTROL=ignoreboth:erasedups` |
| OMZ `git` | the aliases listed in `.bashrc` (`ga gaa gc gcmsg gst gb gf gsw …`) |
| OMZ `extract`, `copypath`, `copyfile`, `copybuffer` | same names in `.bashrc`; `copybuffer` is `Ctrl+O` |
| OMZ `history`, `cp`, `python` | `h`, `hs`, `cpv`, `pyfind`, `pygrep`, `pyclean` |
| OMZ `uv` | `uv`/`uvx` completions |
| OMZ `sublime`, `pip`, `macos` | not ported |

Settings: `home/.blerc`. Options: `bleopt` (see ble.sh's `blerc.template`).
`AUTO_PUSHD` has no bash equivalent. If ble.sh isn't installed, `.bashrc` falls
back to plain readline + the fzf shell scripts.

### Modern CLI tools

| Tool | Replaces | Trigger |
|---|---|---|
| eza | ls | `ls`, `ll`, `la`, `lt` aliases |
| bat | cat | `cat` alias (no paging, plain style) |
| ripgrep | grep -r | `rg` (with `--hidden` and `!.git`) |
| delta | diff pager | git diff/log/show (configured in .gitconfig) |
| zoxide | cd | `cd foo` jumps to most-used dir matching foo (overrides cd!) |
| fzf | — | `Ctrl+T` for files, `Ctrl+R` for history (overridden by atuin if installed) |
| direnv | manual venv activation | drop a `.envrc` containing `layout uv` |
| atuin *(opt-in)* | shell history | `Ctrl+R` for fuzzy + cross-machine sync |
| mosh | ssh | `mosh server` for sessions that survive network changes |
| herdr | tmux | terminal multiplexer for running several coding agents side by side |

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
`fetch.prune = true`, `rerere.enabled`, histogram diff, and delta as the
pager. `merge.conflictStyle` is set to `diff3` by default and upgraded to
`zdiff3` by `bootstrap.sh` when git ≥ 2.35 (written to `~/.gitconfig.local`).

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

### Coding agents: Claude Code, Codex, herdr

All three install as single-user binaries in `~/.local/bin` and update themselves
in place, no sudo:

```bash
claude update     # also auto-updates in the background
codex update
herdr update
```

### Atuin (opt-in)

Atuin is **not** installed by default. To opt in on a machine:

```bash
WITH_ATUIN=1 bash ~/.dotfiles/bootstrap.sh
```

`.bashrc` only hooks atuin in when the binary is present (and ble.sh is loaded), so machines without it
keep plain bash history with fzf on `Ctrl+R`. To turn it off again on a machine
that has it: `rm ~/.local/bin/atuin` (and `rm -rf ~/.atuin` to uninstall).

Sync points at `https://api.atuin.sh` (their hosted server, free, E2E
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

- `~/.bashrc.local` — sourced at the end of `.bashrc`. Put cluster-specific
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

**No autosuggestions / highlighting.** ble.sh isn't loaded: check
`ls ~/.local/share/blesh/ble.sh`; if missing, run `bash ~/.dotfiles/bootstrap.sh`
(needs `curl` and `xz`). `BLESH_UPDATE=1` pulls a fresh nightly. On bash < 4 (macOS
`/bin/bash`), bootstrap installs a newer bash into `~/.local/bin` and `.bashrc` hops into it.

**First prompt prints "updating tput cache".** Normal; ble.sh builds a per-TERM cache once.

**`codex`/`claude` runs an old version or can't update.** It's probably a
root-owned `sudo npm i -g` copy earlier on `PATH`. Run `which -a codex`, make sure
`~/.local/bin` comes first, and remove the old one with
`sudo npm uninstall -g @openai/codex` (or `@anthropic-ai/claude-code`).

**Statusline shows nothing.** Verify `bash ~/.config/claude/statusline.sh < /dev/null`
runs without error. If `jq: command not found`, install jq (it's part of
the `tools` step in bootstrap; might have been skipped).

**Mosh "could not connect" on a cluster.** Likely UDP ports 60000–61000 are
blocked. Fall back to plain ssh; mosh is opt-in per session anyway.

**Globus daemon dies on logout.** Use the systemd-user service shown above,
plus `loginctl enable-linger`.

**Conda doesn't activate fast enough.** The OMZ `python` plugin and Starship's
`conda` module both probe conda; if your `conda init` block is heavy, consider
moving it into `~/.bashrc.local` and lazy-loading.

## Editing on a server

Real files live in `~/.dotfiles/home/`. The files in `$HOME` are symlinks.
So:

```bash
vim ~/.bashrc                 # actually edits ~/.dotfiles/home/.bashrc
cd ~/.dotfiles && git diff   # see your change
git commit -am "tweak" && git push
# on every other machine: cd ~/.dotfiles && git pull
```
