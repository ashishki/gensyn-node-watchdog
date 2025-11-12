#!/usr/bin/env bash
# ===========================================================
# GENSYN NODE WATCHDOG (light)
# - Single screen session name: "gensyn"
# - New launcher (code_gen_exp) + code-gen-swarm.yaml
# - Auto answers: N then blank line (use default model)
# - No betting/round checks; just process & (optional) VRAM
# ===========================================================

# ---------- User Settings ----------
NODE_NAME="gensyn"                                # screen session name
NODE_DIR="/root/rl-swarm"                # node working dir
VENV_ACTIVATE="$NODE_DIR/.venv/bin/activate"      # venv activate script
RUNTIME_LOG="$NODE_DIR/runtime.log"               # node runtime log
WATCHDOG_LOG="/root/gensyn_watchdog.log"  # watchdog own log

# Launcher (new entrypoint & config)
SWARM_CMD="python -m code_gen_exp.runner.swarm_launcher \
  --config-path \"$NODE_DIR/code_gen_exp/config\" \
  --config-name code-gen-swarm.yaml"

# Feed answers to interactive prompts:
# 1) “Do you want to change settings?” -> N
# 2) “Enter model or press Enter for default” -> <Enter>
AUTO_ANSWERS=$'N\n\n'

# Timings (seconds)
CHECK_INTERVAL=60           # how often to check health
GRACE_PERIOD=60             # wait after restart before next health check

# Optional: minimal free VRAM in MiB (set 0 to disable check)
MIN_FREE_VRAM_MB=0

# ---------- Helpers ----------
ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" | tee -a "$WATCHDOG_LOG"; }

has_enough_vram() {
  [[ "$MIN_FREE_VRAM_MB" -le 0 ]] && return 0
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  local free
  free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END{print s+0}')
  [[ -z "$free" ]] && return 0
  (( free >= MIN_FREE_VRAM_MB ))
}

is_node_running() {
  # Consider node alive if screen session exists OR a process with the exact launcher is running from NODE_DIR
  screen -ls | grep -q "[.]$NODE_NAME[[:space:]]" && return 0
  pgrep -af "$SWARM_CMD" | grep -q "$NODE_DIR"
}

# ---------- Restart Logic ----------
restart_node() {
  log "Restarting node $NODE_NAME ..."

  # Kill only matching processes belonging to this node
  pgrep -af "$SWARM_CMD" | grep "$NODE_DIR" | awk '{print $1}' | xargs -r kill -9
  pgrep -af "[r]un_rl_swarm.sh" | grep "$NODE_DIR" | awk '{print $1}' | xargs -r kill -9

  # Close screen if exists
  screen -S "$NODE_NAME" -X quit 2>/dev/null || true
  sleep 2

  # Start new screen session; activate venv; feed answers; tee into runtime log
  screen -dmS "$NODE_NAME" bash -lc "
    cd \"$NODE_DIR\" && \
    source \"$VENV_ACTIVATE\" && \
    printf \"$AUTO_ANSWERS\" | $SWARM_CMD 2>&1 | tee -a \"$RUNTIME_LOG\"
  "

  log "Node started; waiting $GRACE_PERIOD s for initialization..."
  sleep "$GRACE_PERIOD"
}

# Track last exit code written by the node (if node cooperates)
trap 'EC=$?; echo "[WATCHDOG_EXIT_CODE] $EC" >> "$RUNTIME_LOG"; exit $EC' EXIT INT TERM

# ---------- Main Loop ----------
log "Watchdog started. Node: $NODE_NAME  Dir: $NODE_DIR"
while true; do
  if ! has_enough_vram; then
    log "Low free VRAM; skipping restart attempt."
  else
    if is_node_running; then
      log "$NODE_NAME running OK."
    else
      log "$NODE_NAME is NOT running. Triggering restart..."
      restart_node
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
