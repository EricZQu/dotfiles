#!/usr/bin/env bash
# ============================================================================
# ~/.config/claude/statusline.sh
#
# Two-line Claude Code statusline tailored for ML / multi-server workflows.
#
# Reads JSON on stdin (per Claude Code's spec), prints two formatted lines
# on stdout. Configure via ~/.config/claude/statusline.env.
#
# Line 1 — identity:  host │ dir(branch) │ env │ GPU │ slurm jobs
# Line 2 — session:   model │ ctx-bar │ cost+rate │ tokens+tpm │ rate-limit
#
# Dependencies: jq. Everything else degrades gracefully.
# ============================================================================
set -uo pipefail

# ─── load config ───────────────────────────────────────────────────────────
CONFIG="${CLAUDE_STATUSLINE_ENV:-$HOME/.config/claude/statusline.env}"
# defaults
SHOW_HOST=1; SHOW_DIR=1; SHOW_GIT=1; SHOW_ENV=1; SHOW_GPU=1; SHOW_SLURM=1
SHOW_MODEL=1; SHOW_CTX=1; SHOW_COST=1; SHOW_TOKENS=1; SHOW_RATE=1
CACHE_TTL=5
HOST_COLORS=()
[[ -f "$CONFIG" ]] && source "$CONFIG"

# ─── colors ────────────────────────────────────────────────────────────────
RST=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'
MAG=$'\033[35m'; CYN=$'\033[36m'; WHT=$'\033[37m'
BRED=$'\033[91m'; BGRN=$'\033[92m'; BYEL=$'\033[93m'; BBLU=$'\033[94m'
BMAG=$'\033[95m'; BCYN=$'\033[96m'

color_for_pct() {  # 0-100 → green<50<yellow<80<red
  local p="$1"
  if   (( p < 50 )); then printf '%s' "$GRN"
  elif (( p < 80 )); then printf '%s' "$YEL"
  else                    printf '%s' "$BRED"
  fi
}

bar() {  # bar <pct> <width>
  local pct="$1" w="${2:-10}" filled
  filled=$(( pct * w / 100 )); (( filled > w )) && filled=$w; (( filled < 0 )) && filled=0
  local empty=$(( w - filled ))
  local color; color="$(color_for_pct "$pct")"
  local out=""
  (( filled > 0 )) && out+="$color$(printf '█%.0s' $(seq 1 "$filled"))"
  (( empty  > 0 )) && out+="$DIM$(printf '░%.0s' $(seq 1 "$empty"))"
  printf '%s%s' "$out" "$RST"
}

human_tokens() {  # 296000 → 296k, 1234567 → 1.2M
  local n="$1"
  if   (( n >= 1000000 )); then awk -v n="$n" 'BEGIN { printf "%.1fM", n/1000000 }'
  elif (( n >= 1000    )); then printf '%dk' $(( n / 1000 ))
  else                          printf '%d' "$n"
  fi
}

human_dur() {  # seconds → "Xh Ym" or "Xm" or "Xs"
  local s="$1"
  (( s < 60 ))    && { printf '%ds' "$s"; return; }
  (( s < 3600 ))  && { printf '%dm' $(( s / 60 )); return; }
  printf '%dh%dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
}

# ─── caching helpers (avoid hammering nvidia-smi/squeue) ───────────────────
CACHE_DIR="${TMPDIR:-/tmp}/cc-statusline-${USER:-$(id -un 2>/dev/null || echo nobody)}"
mkdir -p "$CACHE_DIR" 2>/dev/null
cache_get() {  # cache_get <name> <ttl> <cmd…>
  local name="$1" ttl="$2"; shift 2
  local f="$CACHE_DIR/$name"
  if [[ -f "$f" ]] && (( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null \
                                       || stat -f %m "$f" 2>/dev/null \
                                       || echo 0) < ttl )); then
    cat "$f"; return
  fi
  local out; out="$("$@" 2>/dev/null || true)"
  printf '%s' "$out" > "$f"
  printf '%s' "$out"
}

# ─── data probes ───────────────────────────────────────────────────────────
probe_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 || return
  local raw; raw="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
                                --format=csv,noheader,nounits 2>/dev/null)"
  [[ -z "$raw" ]] && return
  local n=0 active=0 sum_util=0 sum_mu=0 sum_mt=0 model
  while IFS=, read -r u mu mt; do
    u="${u// /}"; mu="${mu// /}"; mt="${mt// /}"
    [[ -z "$u" ]] && continue
    n=$(( n + 1 )); sum_util=$(( sum_util + u ))
    sum_mu=$(( sum_mu + mu )); sum_mt=$(( sum_mt + mt ))
    (( u > 5 )) && active=$(( active + 1 ))
  done <<< "$raw"
  (( n == 0 )) && return
  local avg=$(( sum_util / n ))
  local mem_pct=0
  (( sum_mt > 0 )) && mem_pct=$(( sum_mu * 100 / sum_mt ))
  # Try to grab GPU model (first card only) for a tag like "H100"
  model="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  # Trim "NVIDIA " prefix and reduce to short name
  model="${model#NVIDIA }"
  case "$model" in
    *H100*)              model=H100 ;;
    *H200*)              model=H200 ;;
    *A100*)              model=A100 ;;
    *A6000*)             model=A6000 ;;
    *V100*)              model=V100 ;;
    *L40S*)              model=L40S ;;
    *L40*)               model=L40 ;;
    *RTX*6000*Ada*)      model=RTX6000Ada ;;
    *RTX*5090*)          model=5090 ;;
    *RTX*4090*)          model=4090 ;;
    *RTX*3090*)          model=3090 ;;
    *)                   model="$(echo "$model" | awk '{print $NF}')" ;;
  esac
  if (( n == active )); then
    # all cards busy: just count×model util%
    printf '%d×%s %d%%' "$n" "$model" "$avg"
  else
    # mixed: active/total×model util-of-active%
    local active_avg=0
    (( active > 0 )) && active_avg=$(( sum_util / active ))
    printf '%d/%d×%s %d%%' "$active" "$n" "$model" "$active_avg"
  fi
}

probe_slurm() {
  command -v squeue >/dev/null 2>&1 || return
  local count user="${USER:-$(id -un)}"
  count="$(squeue -h -u "$user" 2>/dev/null | wc -l)"
  count="${count// /}"
  [[ "$count" = "0" || -z "$count" ]] && return
  printf '%s' "$count"
}

probe_env() {
  # uv project? check for pyproject.toml in cwd or ancestors via VIRTUAL_ENV
  if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    printf '%s' "$(basename "$VIRTUAL_ENV" | sed 's/^\.//; s/^venv$/'"$(basename "$(dirname "$VIRTUAL_ENV")")"'/')"
    return
  fi
  if [[ -n "${CONDA_DEFAULT_ENV:-}" && "$CONDA_DEFAULT_ENV" != "base" ]]; then
    printf '%s' "$CONDA_DEFAULT_ENV"
  fi
}

probe_git() {
  local cwd="$1"
  command -v git >/dev/null 2>&1 || return
  local branch
  branch="$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)" \
    || branch="$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)"
  [[ -z "$branch" ]] && return
  local mod stg
  mod="$(git -C "$cwd" --no-optional-locks diff --numstat 2>/dev/null | wc -l)"
  stg="$(git -C "$cwd" --no-optional-locks diff --cached --numstat 2>/dev/null | wc -l)"
  mod="${mod// /}"; stg="${stg// /}"
  local extra=""
  (( stg > 0 )) && extra+=" +$stg"
  (( mod > 0 )) && extra+=" *$mod"
  printf '%s%s' "$branch" "$extra"
}

# ─── short hostname with optional regex coloring ───────────────────────────
host_segment() {
  local host="${HOSTNAME:-$(hostname -s 2>/dev/null || echo '?')}"
  host="${host%%.*}"
  local color="$BCYN"
  for entry in "${HOST_COLORS[@]:-}"; do
    [[ -z "$entry" ]] && continue
    local pat="${entry%%:*}" code="${entry##*:}"
    if [[ "$host" == *"$pat"* ]]; then
      color=$'\033['"$code"'m'
      break
    fi
  done
  printf '%s%s%s' "$color" "$host" "$RST"
}

# ─── parse stdin JSON ──────────────────────────────────────────────────────
input="$(cat)"

j() { jq -r "$1 // empty" 2>/dev/null <<<"$input"; }

model_name="$(j '.model.display_name')"
model_id="$(j '.model.id')"
cwd="$(j '.workspace.current_dir')"; [[ -z "$cwd" ]] && cwd="$(j '.cwd')"
[[ -z "$cwd" ]] && cwd="$PWD"

ctx_pct="$(j '.context_window.used_percentage')"
[[ -z "$ctx_pct" ]] && ctx_pct=0
ctx_pct="${ctx_pct%.*}"   # int
in_tok="$(j '.context_window.total_input_tokens')"; in_tok="${in_tok:-0}"
out_tok="$(j '.context_window.total_output_tokens')"; out_tok="${out_tok:-0}"
total_tok=$(( in_tok + out_tok ))

cost_usd="$(j '.cost.total_cost_usd')"; cost_usd="${cost_usd:-0}"
dur_ms="$(j '.cost.total_duration_ms')";  dur_ms="${dur_ms:-0}"
api_ms="$(j '.cost.total_api_duration_ms')"; api_ms="${api_ms:-0}"

rl_pct="$(j '.rate_limits.five_hour.used_percentage')"; rl_pct="${rl_pct:-}"
rl_reset="$(j '.rate_limits.five_hour.resets_at')";    rl_reset="${rl_reset:-}"

# ─── compute derived ───────────────────────────────────────────────────────
# burn rate = cost / hours
burn_per_hour="0.00"
if [[ "$dur_ms" -gt 0 ]] 2>/dev/null && awk "BEGIN { exit !($cost_usd > 0) }"; then
  burn_per_hour="$(awk -v c="$cost_usd" -v d="$dur_ms" 'BEGIN { printf "%.2f", c / (d/3600000) }')"
fi
# tokens per minute
tpm=0
if (( dur_ms > 0 && total_tok > 0 )); then
  tpm=$(( total_tok * 60000 / dur_ms ))
fi
# rate-limit reset countdown
rl_reset_str=""
if [[ -n "$rl_reset" ]]; then
  now=$(date +%s)
  remain=$(( rl_reset - now ))
  (( remain > 0 )) && rl_reset_str=" $(human_dur "$remain")"
fi

# ─── short-cwd display ────────────────────────────────────────────────────
short_cwd() {
  local d="$1"
  d="${d/#$HOME/~}"
  # If too long, keep only last 2 segments
  local n; n=$(awk -F/ '{print NF}' <<<"$d")
  if (( n > 4 )) && [[ "$d" != "~/"* ]]; then
    d=".../$(awk -F/ '{print $(NF-1)"/"$NF}' <<<"$d")"
  fi
  printf '%s' "$d"
}

# ─── BUILD LINE 1 ──────────────────────────────────────────────────────────
SEP="${DIM}│${RST}"
parts1=()

[[ "$SHOW_HOST" = "1" ]] && parts1+=("${BOLD}🖥${RST}  $(host_segment)")

if [[ "$SHOW_DIR" = "1" ]]; then
  dir_str="$(short_cwd "$cwd")"
  if [[ "$SHOW_GIT" = "1" ]]; then
    git_info="$(probe_git "$cwd")"
    if [[ -n "$git_info" ]]; then
      parts1+=("${BLU}📂${RST} ${BBLU}$dir_str${RST} ${MAG}($git_info)${RST}")
    else
      parts1+=("${BLU}📂${RST} ${BBLU}$dir_str${RST}")
    fi
  else
    parts1+=("${BLU}📂${RST} ${BBLU}$dir_str${RST}")
  fi
fi

if [[ "$SHOW_ENV" = "1" ]]; then
  env_name="$(probe_env)"
  [[ -n "$env_name" ]] && parts1+=("${YEL}🐍${RST} ${BYEL}$env_name${RST}")
fi

if [[ "$SHOW_GPU" = "1" ]]; then
  gpu_str="$(cache_get gpu "$CACHE_TTL" probe_gpu)"
  [[ -n "$gpu_str" ]] && parts1+=("${GRN}🎮${RST} ${BGRN}$gpu_str${RST}")
fi

if [[ "$SHOW_SLURM" = "1" ]]; then
  slurm_str="$(cache_get slurm "$CACHE_TTL" probe_slurm)"
  [[ -n "$slurm_str" ]] && parts1+=("${MAG}🧪${RST} ${BMAG}$slurm_str jobs${RST}")
fi

# ─── BUILD LINE 2 ──────────────────────────────────────────────────────────
parts2=()

if [[ "$SHOW_MODEL" = "1" && -n "$model_name" ]]; then
  parts2+=("${BOLD}🤖${RST} ${BCYN}$model_name${RST}")
fi

if [[ "$SHOW_CTX" = "1" ]]; then
  parts2+=("💭 $(bar "$ctx_pct" 10) $(color_for_pct "$ctx_pct")${ctx_pct}%${RST}")
fi

if [[ "$SHOW_COST" = "1" ]]; then
  cost_str="$(printf '$%.2f' "$cost_usd")"
  parts2+=("💸 ${BYEL}${cost_str}${RST} ${DIM}(\$${burn_per_hour}/h)${RST}")
fi

if [[ "$SHOW_TOKENS" = "1" && "$total_tok" -gt 0 ]]; then
  parts2+=("📊 ${BWHT:-$WHT}$(human_tokens "$total_tok")${RST} ${DIM}(${tpm} tpm)${RST}")
fi

if [[ "$SHOW_RATE" = "1" && -n "$rl_pct" ]]; then
  rl_int="${rl_pct%.*}"
  parts2+=("⏱  $(bar "$rl_int" 10) $(color_for_pct "$rl_int")${rl_int}%${RST}${rl_reset_str}")
fi

# ─── PRINT ─────────────────────────────────────────────────────────────────
join_parts() {
  local IFS=""
  local out="" first=1
  for p in "$@"; do
    if (( first )); then out="$p"; first=0
    else                 out="$out ${SEP} $p"
    fi
  done
  printf '%s' "$out"
}

[[ "${#parts1[@]}" -gt 0 ]] && { join_parts "${parts1[@]}"; printf '\n'; }
[[ "${#parts2[@]}" -gt 0 ]] && { join_parts "${parts2[@]}"; printf '\n'; }
