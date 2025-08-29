# RL-Swarm Launcher

Automated launching and monitoring of RL-Swarm nodes with GPU-first support.

## Features

- Node orchestration – run single or multiple RL-Swarm nodes, each in its own screen session  
- Automatic port assignment – run multiple nodes on unique ports (`3001`, `3002`, …)  
- Logging of exit codes – each node writes watchdog-style logs to its own directory  
- GPU support – if CUDA is available, nodes automatically use it  
- Isolated environments – each node runs from its own directory  

## Covered Cases

### Node lifecycle
- Single node launch with default port  
- Multiple nodes launched with incremented ports  
- Detached background execution with `screen`  

### Monitoring and logging
- Exit codes logged in `<NODE_DIR>/node_runtime.log`  
- Each node runs in a named `screen` session for easy attach/detach  

### GPU-aware execution
- By default uses GPU if available (`torch.cuda.is_available()`)  
- CPU fallback suggested as future PR

## 🔧 Req


```bash
# Ubuntu/Debian
sudo apt update
sudo apt install -y curl jq screen 

# Cheack
curl --version
jq --version
screen --version
nvidia-smi
```

### Structure:
```
workspace/
├── rl-swarm1/           # Node 1
│   ├── run_rl_swarm.sh
│   ├── node_runtime.log
│   └── logs/
│       └── prg_record.txt
├── rl-swarm2/           # Node 2 
│   ├── run_rl_swarm.sh
│   ├── node_runtime.log
│   └── logs/
│       └── prg_record.txt
└── watchdog/
    ├── gensyn_node1_watchdog.sh
    ├── gensyn_node2_watchdog.sh
    └── logs/
```

## 📦 Setup
### 1. Cloning repo
```bash
cd /workspace
git clone https://github.com/yourusername/gensyn-node-watchdog
cd gensyn-node-watchdog
```

### 2. Copying and prepp
```bash
# Copy if more then 1
cp gensyn_node_watchdog.sh gensyn_node1_watchdog.sh
cp gensyn_node_watchdog.sh gensyn_node2_watchdog.sh

# Allow
chmod +x gensyn_node1_watchdog.sh
chmod +x gensyn_node2_watchdog.sh
```

### 3. Confing in each script

**For node 1 (`gensyn_node1_watchdog.sh`):**
```bash
NODE_NAME="gensyn1"
NODE_DIR="/workspace/rl-swarm1"
LOG_FILE="/workspace/gensyn_auto_restart_${NODE_NAME}.log"
RUNTIME_LOG="$NODE_DIR/node_runtime.log"
BETTING_LOG="$NODE_DIR/logs/prg_record.txt"
LAUNCH_CMD="bash ./run_rl_swarm.sh"
```

**For node 2 (`gensyn_node2_watchdog.sh`):**
```bash
NODE_NAME="gensyn2"
NODE_DIR="/workspace/rl-swarm2"
LOG_FILE="/workspace/gensyn_auto_restart_${NODE_NAME}.log"
RUNTIME_LOG="$NODE_DIR/node_runtime.log"
BETTING_LOG="$NODE_DIR/logs/prg_record.txt"
LAUNCH_CMD="PORT=3001 bash ./run_rl_swarm.sh"
```

**For few:**
```bash
NODE_NAME="gensyn3"
NODE_DIR="/workspace/rl-swarm3"
LAUNCH_CMD="PORT=3002 bash ./run_rl_swarm.sh"
# etc
```

### 4. Modification of run_rl_swarm.sh

Add the following to the **end of each** `run_rl_swarm.sh`:

```bash
# === WATCHDOG EXIT CODE LOGGING ===
EXIT_CODE=$?
echo "[WATCHDOG_EXIT_CODE] $EXIT_CODE" >> "$NODE_DIR/node_runtime.log"
exit $EXIT_CODE
```

Where `$NODE_DIR` is the path to the node directory (for example `/workspace/rl-swarm1`).

## Launch

### Launch each node in a separate screen session:

```bash
# Node 1
screen -dmS watchdog_node1 ./gensyn_node1_watchdog.sh

# Node 2  
screen -dmS watchdog_node2 ./gensyn_node2_watchdog.sh

# Check running sessions
screen -ls
```

### Attach to a session for monitoring:
```bash
# Attach to watchdog session for node 1
screen -r watchdog_node1

# Detach without stopping: Ctrl+A, then D
# Stop: Ctrl+C (will enter pause mode until error occurs)
```

### Check logs:
```bash
# Watchdog logs
tail -f /workspace/gensyn_auto_restart_gensyn1.log

# Node runtime logs
tail -f /workspace/rl-swarm1/node_runtime.log

# Betting logs
tail -f /workspace/rl-swarm1/logs/prg_record.txt
```

## Configuration

Main parameters in the script:

```bash
CHECK_INTERVAL=300                 # 5 min between health checks
BETTING_CHECK_INTERVAL=3600        # 1 hour between betting status checks
GAME_CHANGE_CHECK_INTERVAL=3600    # 1 hour between round change checks
MIN_VRAM_MB=2000                   # Minimum GPU VRAM usage
GRACE_PERIOD=60                    # Wait time after restart
```

## Monitoring and Debugging

### Check node status:
```bash
# Node processes
ps aux | grep python | grep swarm_launcher

# GPU usage
nvidia-smi

# Screen sessions  
screen -ls

# Last watchdog actions
tail -20 /workspace/gensyn_auto_restart_gensyn1.log
```

### Manual control:
```bash
# Temporary pause (Ctrl+C inside screen session)
# Watchdog will pause and wait for errors in logs

# Full stop of watchdog
screen -S watchdog_node1 -X quit

# Restart
screen -dmS watchdog_node1 ./gensyn_node1_watchdog.sh
```

## Troubleshooting

### Common issues:

1. **"command not found: jq"**
   ```bash
   sudo apt install jq
   ```

2. **"VRAM check fails"**
   ```bash
   nvidia-smi  # Check GPU availability
   # Adjust MIN_VRAM_MB in config
   ```

3. **"No screen session found"**
   ```bash
   screen -dmS gensyn1 # Create session again
   ```

4. **"API timeout"**
   ```bash
   curl -s "https://dashboard.gensyn.ai/api/v1/applications/verdict/stats"
   # Check API availability
   ```

## CPU-only Systems

> **Pull Requests are welcome!**  
> 
> To adapt for CPU-only systems you need to:
> - Replace VRAM check with CPU/RAM utilization check  
> - Use `htop`, `ps`, or `/proc/stat` instead of `nvidia-smi`  
> - Adapt the `is_node_running()` function  

Example CPU version:
```bash
get_cpu_usage() {
    ps -o %cpu -p $(pgrep -f "$SWARM_CMD") | tail -1 | tr -d ' '
}

is_node_running() {
    ps aux | grep "$SWARM_CMD" | grep -v grep | grep "$NODE_DIR" > /dev/null
    local python_alive=$?
    local cpu_usage=$(get_cpu_usage)
    if [[ "$python_alive" -eq 0 && "${cpu_usage%.*}" -ge "5" ]]; then
        return 0
    else
        return 1
    fi
}
```

## Logs and Monitoring

Logging structure:
- **Watchdog logs**: `/workspace/gensyn_auto_restart_<NODE_NAME>.log`  
- **Node runtime logs**: `<NODE_DIR>/node_runtime.log`  
- **Betting logs**: `<NODE_DIR>/logs/prg_record.txt`  

Every action is logged with a timestamp for full transparency of the system.

## Contributing

1. Fork the repository  
2. Create a feature branch (`git checkout -b feature/cpu-support`)  
3. Commit your changes (`git commit -am 'Add CPU monitoring support'`)  
4. Push to the branch (`git push origin feature/cpu-support`)  
5. Open a Pull Request  

## GPU Requirements

The system is specifically designed for **GPU-based Gensyn nodes** and requires:
- NVIDIA GPU with CUDA support  
- Installed NVIDIA drivers  
- `nvidia-smi` utility  
- Minimum 2GB VRAM for stable operation  

---

**Author**: https://github.com/ashishki