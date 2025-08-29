#!/bin/bash

# ===================================================================
# Gensyn Node Watchdog - Intelligent Node Monitoring & Auto-Restart
# ===================================================================
# 
# Features:
# - Auto-restart nodes on crashes/failures
# - Intelligent betting management (prevents double-betting)
# - GPU VRAM monitoring for node health
# - Game/round change detection
# - Graceful handling of manual stops (Ctrl+C)
# - Multi-node support with unique ports
#
# Author: Your GitHub Username
# License: MIT
# ===================================================================

# === CONFIGURATION ===
# Customize these variables for each node:

NODE_NAME="gensyn1"                                    # Unique node identifier
NODE_DIR="/workspace/rl-swarm1"                       # Path to node directory  
LOG_FILE="/workspace/gensyn_auto_restart_${NODE_NAME}.log"
RUNTIME_LOG="$NODE_DIR/node_runtime.log"
BETTING_LOG="$NODE_DIR/logs/prg_record.txt"
LAUNCH_CMD="bash ./run_rl_swarm.sh"                   # For additional nodes use: "PORT=3001(2,3,4...) bash ./run_rl_swarm.sh"

# System Configuration
CHECK_INTERVAL=300                                     # 5 min between health checks
BETTING_CHECK_INTERVAL=3600                           # 1 hour between betting status checks
GAME_CHANGE_CHECK_INTERVAL=3600                      # 1 hour between game/round change checks
MIN_VRAM_MB=2000                                      # Minimum GPU memory usage to consider node alive
SWARM_CMD="python -m rgym_exp.runner.swarm_launcher --config-path $NODE_DIR/rgym_exp/config --config-name rg-swarm.yaml"
MODEL_NAME="Gensyn/Qwen2.5-0.5B-Instruct"
GRACE_PERIOD=60                                       # Seconds to wait after restart before next health check

# === LOGGING FUNCTION ===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# === GET GPU VRAM USAGE ===
get_vram() {
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1
}

# === CHECK IF NODE PROCESS IS RUNNING ===
is_node_running() {
    ps aux | grep "$SWARM_CMD" | grep -v grep | grep "$NODE_DIR" > /dev/null
    local python_alive=$?
    local vram=$(get_vram)
    if [[ "$python_alive" -eq 0 && "$vram" -ge "$MIN_VRAM_MB" ]]; then
        return 0
    else
        return 1
    fi
}

# === GET CURRENT GAME INFO FROM API ===
get_current_game_info() {
    curl -s "https://dashboard.gensyn.ai/api/v1/applications/verdict/stats" | jq -r '{gameId: .game.id, roundId: (.rounds | max_by(.id) | .id), status: .game.status}'
}

# === CHECK FOR GAME/ROUND CHANGES ===
check_game_round_change() {
    local game_info=$(get_current_game_info)
    
    if [ $? -ne 0 ] || [ -z "$game_info" ] || [ "$game_info" == "null" ]; then
        log "Unable to get current game info for game/round change check"
        return 1  # Can't check, don't restart
    fi
    
    local current_game_id=$(echo "$game_info" | jq -r '.gameId')
    local current_round_id=$(echo "$game_info" | jq -r '.roundId')
    local game_status=$(echo "$game_info" | jq -r '.status')
    
    # If this is the first check, just store the current values
    if [ -z "$LAST_KNOWN_GAME_ID" ] || [ -z "$LAST_KNOWN_ROUND_ID" ]; then
        LAST_KNOWN_GAME_ID="$current_game_id"
        LAST_KNOWN_ROUND_ID="$current_round_id"
        log "Initial game/round tracking: Game $current_game_id Round $current_round_id"
        return 1  # Don't restart on first check
    fi
    
    # Check if game or round has changed
    if [ "$current_game_id" != "$LAST_KNOWN_GAME_ID" ] || [ "$current_round_id" != "$LAST_KNOWN_ROUND_ID" ]; then
        log "Game/Round change detected: $LAST_KNOWN_GAME_ID/$LAST_KNOWN_ROUND_ID -> $current_game_id/$current_round_id"
        
        # Update tracking variables
        LAST_KNOWN_GAME_ID="$current_game_id"
        LAST_KNOWN_ROUND_ID="$current_round_id"
        
        # Only restart if game is active and we haven't bet yet
        if [ "$game_status" == "active" ]; then
            # Check if we already have a bet for this new game/round
            if [ -f "$BETTING_LOG" ]; then
                local bet_found=$(grep "Game $current_game_id Round $current_round_id" "$BETTING_LOG" | grep "placed bet")
                if [ -z "$bet_found" ]; then
                    log "New active game/round without bet - restart recommended"
                    return 0  # Restart needed
                else
                    log "New game/round but bet already placed - no restart needed"
                    return 1  # No restart needed
                fi
            else
                log "New active game/round and no betting log - restart recommended"
                return 0  # Restart needed
            fi
        else
            log "New game/round but not active (status: $game_status) - no restart needed"
            return 1  # No restart needed
        fi
    fi
    
    return 1  # No change detected, no restart needed
}

# === CHECK IF BET WAS PLACED FOR CURRENT GAME AND ROUND ===
check_bet_status() {
    local game_info=$(get_current_game_info)
    
    if [ $? -ne 0 ] || [ -z "$game_info" ] || [ "$game_info" == "null" ]; then
        log "Unable to get current game info from API"
        return 0  # Default to not allowing betting if can't check
    fi
    
    local current_game_id=$(echo "$game_info" | jq -r '.gameId')
    local current_round_id=$(echo "$game_info" | jq -r '.roundId')
    local game_status=$(echo "$game_info" | jq -r '.status')
    
    log "Current game: $current_game_id, round: $current_round_id, status: $game_status"
    
    if [ "$game_status" != "active" ]; then
        log "Game is not active (status: $game_status)"
        return 1  # Game not active, allow betting for next game
    fi
    
    if [ ! -f "$BETTING_LOG" ]; then
        log "Betting log not found. No previous bets detected."
        return 1  # No betting log, allow betting
    fi
    
    # Check if bet was placed for current game and round
    local bet_found=$(grep "Game $current_game_id Round $current_round_id" "$BETTING_LOG" | grep "placed bet")
    
    if [ -n "$bet_found" ]; then
        log "Bet already placed for Game $current_game_id Round $current_round_id:"
        log "$bet_found"
        return 0  # Bet was placed, don't allow betting
    else
        log "No bet found for Game $current_game_id Round $current_round_id. Betting allowed."
        return 1  # No bet found, allow betting
    fi
}

# === RESTART NODE WITH BETTING DECISION ===
restart_node() {
    local restart_reason=${1:-"unknown"}
    log "Restarting node $NODE_NAME (reason: $restart_reason)..."

    # Kill only this node's processes by config and directory
    ps aux | grep "$SWARM_CMD" | grep -v grep | grep "$NODE_DIR" | awk '{print $2}' | xargs -r kill -9
    ps aux | grep "[r]un_rl_swarm.sh" | grep "$NODE_DIR" | awk '{print $2}' | xargs -r kill -9

    # Close screen session if it exists
    screen -S "$NODE_NAME" -X quit 2>/dev/null

    sleep 2

    # Get current game info for decision making
    local game_info=$(get_current_game_info)
    local betting_param="Y"  # Default: allow betting
    
    if [ $? -ne 0 ] || [ -z "$game_info" ] || [ "$game_info" == "null" ]; then
        log "Unable to get current game info - starting with betting enabled (Y)"
    else
        local current_game_id=$(echo "$game_info" | jq -r '.gameId')
        local current_round_id=$(echo "$game_info" | jq -r '.roundId')
        local game_status=$(echo "$game_info" | jq -r '.status')
        
        log "Current API state: Game $current_game_id Round $current_round_id Status $game_status"
        
        # Check if this is a new game/round compared to what we had before
        local is_new_game_round=0
        if [ -n "$LAST_KNOWN_GAME_ID" ] && [ -n "$LAST_KNOWN_ROUND_ID" ]; then
            if [ "$current_game_id" != "$LAST_KNOWN_GAME_ID" ] || [ "$current_round_id" != "$LAST_KNOWN_ROUND_ID" ]; then
                is_new_game_round=1
                log "Detected new game/round: $LAST_KNOWN_GAME_ID/$LAST_KNOWN_ROUND_ID -> $current_game_id/$current_round_id"
            fi
        else
            # First time running - initialize tracking
            log "First run - initializing game/round tracking"
        fi
        
        # Update tracking variables
        LAST_KNOWN_GAME_ID="$current_game_id"
        LAST_KNOWN_ROUND_ID="$current_round_id"
        
        # Decide on betting based on game status and bet history
        if [ "$game_status" != "active" ]; then
            betting_param="N"
            log "Game not active - starting with betting disabled (N)"
        elif check_bet_status; then
            # Bet already placed for current game/round
            if [ $is_new_game_round -eq 1 ]; then
                log "New game/round detected but bet already placed - this might be an old bet log entry"
                log "Starting with betting disabled (N) but will monitor for further changes"
            fi
            betting_param="N"
            log "Bet already placed for current round - starting with betting disabled (N)"
        else
            betting_param="Y"
            log "No bet placed for current round - starting with betting enabled (Y)"
        fi
    fi

    # Start a new screen session with appropriate betting parameter
    screen -dmS "$NODE_NAME" bash -c "
        cd '$NODE_DIR'
        source .venv/bin/activate
        echo -e 'N\n$MODEL_NAME\n$betting_param\n' | $LAUNCH_CMD 2>&1 | tee -a '$RUNTIME_LOG'
    "
    
    log "Node $NODE_NAME restarted with model $MODEL_NAME and betting=$betting_param"
    log "Waiting $GRACE_PERIOD seconds for node initialization..."
    sleep $GRACE_PERIOD
}

# === WATCHDOG PAUSE/RESUME VARIABLES ===
PAUSED_BY_USER=0
LAST_CHECKED_LINE=0

# === CHECK STATE VARIABLES ===
LAST_BETTING_CHECK_TS=$(date +%s)
LAST_GAME_CHECK_TS=$(date +%s)
LAST_KNOWN_GAME_ID=""
LAST_KNOWN_ROUND_ID=""

# === STARTUP MESSAGE ===
log "=== Gensyn Node Watchdog Started ==="
log "Node: $NODE_NAME"
log "Directory: $NODE_DIR" 
log "Min VRAM: ${MIN_VRAM_MB}MB"
log "Check interval: ${CHECK_INTERVAL}s"
log "Launch command: $LAUNCH_CMD"

# === MAIN MONITORING LOOP ===
while true; do
    # 1. If paused due to manual Ctrl+C interrupt, watch log for errors
    if [ $PAUSED_BY_USER -eq 1 ]; then
        if [ -f "$RUNTIME_LOG" ]; then
            LOG_LEN=$(wc -l < "$RUNTIME_LOG")
            if [ $LOG_LEN -gt $LAST_CHECKED_LINE ]; then
                NEW_ERRORS=$(tail -n +$((LAST_CHECKED_LINE + 1)) "$RUNTIME_LOG" | grep -E "Traceback|Error|Killed process|OutOfMemory|Exception")
                if [ -n "$NEW_ERRORS" ]; then
                    log "Detected new error in log, resuming monitoring!"
                    log "Error: $NEW_ERRORS"
                    PAUSED_BY_USER=0
                fi
            fi
        fi
        
        if [ $PAUSED_BY_USER -eq 1 ]; then
            log "Paused due to manual interrupt (exit 130). Waiting for new error in log..."
            sleep $CHECK_INTERVAL
            continue
        fi
    fi

    # 2. Check the latest exit code in the runtime log
    if [ -f "$RUNTIME_LOG" ]; then
        LAST_EXIT_CODE=$(tac "$RUNTIME_LOG" | grep -m1 "^\[WATCHDOG_EXIT_CODE\]" | awk '{print $2}')
        if [ "$LAST_EXIT_CODE" == "130" ]; then
            log "Detected manual stop (SIGINT, exit 130). Pausing monitoring until new error in log."
            PAUSED_BY_USER=1
            LAST_CHECKED_LINE=$(wc -l < "$RUNTIME_LOG" 2>/dev/null || echo "0")
            sleep $CHECK_INTERVAL
            continue
        fi
    fi

    # 3. Node health check and restart logic
    if is_node_running; then
        log "$NODE_NAME running OK. VRAM: $(get_vram)MB"
    else
        log "$NODE_NAME is NOT running."
        restart_node "node_not_running"
    fi

    # 4. Every BETTING_CHECK_INTERVAL seconds, check if betting status changed (NO RESTART)
    NOW_TS=$(date +%s)
    if (( NOW_TS - LAST_BETTING_CHECK_TS >= BETTING_CHECK_INTERVAL )); then
        log "Checking current betting status..."
        if check_bet_status; then
            log "Bet status: PLACED - Current node should not be betting"
        else
            log "Bet status: NOT PLACED - Current node can bet if it wants"
        fi
        LAST_BETTING_CHECK_TS=$NOW_TS
    fi

    # 5. Every GAME_CHANGE_CHECK_INTERVAL seconds, check for game/round changes
    if (( NOW_TS - LAST_GAME_CHECK_TS >= GAME_CHANGE_CHECK_INTERVAL )); then
        log "Checking for game/round changes..."
        if check_game_round_change; then
            log "Game/Round changed without bet - restarting node to enable betting!"
            restart_node "game_round_change"
        fi
        LAST_GAME_CHECK_TS=$NOW_TS
    fi

    sleep $CHECK_INTERVAL
done