#!/bin/bash

ROOT=$PWD

# Colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;95m'
BLUE='\033[0;94m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Exports
env_vars=(PUB_MULTI_ADDRS PEER_MULTI_ADDRS HOST_MULTI_ADDRS IDENTITY_PATH ORG_ID)
for v in "${env_vars[@]}"; do export "$v"; done
export HF_HUB_DOWNLOAD_TIMEOUT=120
export TUNNEL_TYPE=""

# Defaults for multiaddrs and identity
DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ"
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}
DEFAULT_IDENTITY_PATH="$ROOT/swarm.pem"
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

# Swarm contracts
SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

# Storage verification and setup
check_storage() {
    echo -e "${CYAN}${BOLD}[✓] Verifying external storage at /mnt/data...${NC}"
    [ ! -d "/mnt/data" ] && sudo mkdir -p /mnt/data
    if ! touch /mnt/data/test_write 2>/dev/null; then
        echo -e "${YELLOW}${BOLD}[!] Adjusting permissions...${NC}"
        sudo chown -R $USER:$USER /mnt/data && sudo chmod -R 775 /mnt/data
    fi
    rm -f /mnt/data/test_write
    AVAIL=$(df -BG /mnt/data | awk 'NR==2{print $4}' | tr -d 'G')
    if [ "$AVAIL" -lt 5 ]; then
        echo -e "${RED}${BOLD}[✗] Insufficient space ($AVAIL GB). Need ≥5GB.${NC}"
        exit 1
    fi
    echo -e "${GREEN}${BOLD}[✓] $(df -h /mnt/data | awk 'NR==2{print $4}') available${NC}"
}

# Cleanup trap
cleanup() {
    echo -e "${YELLOW}${BOLD}[✓] Cleaning up...${NC}"
    kill $SERVER_PID $TUNNEL_PID 2>/dev/null || true
    [ -n "$VIRTUAL_ENV" ] && deactivate
    exit 0
}
trap cleanup INT

# Run storage check
echo; check_storage

# GPU & CUDA detection
check_cuda_installation() {
    echo -e "\n${CYAN}${BOLD}[✓] Checking GPU and CUDA installation...${NC}"
    GPU_AVAILABLE=false; CPU_ONLY=false; CUDA_AVAILABLE=false; NVCC_AVAILABLE=false
    detect_gpu() {
        command -v lspci &>/dev/null && {
            lspci | grep -qi nvidia && return 0
            lspci | grep -Eqi "amd|radeon|ati" && return 2
        }
        command -v nvidia-smi &>/dev/null && return 0
        [ -d "/proc/driver/nvidia" ] && return 0
        return 1
    }
    detect_gpu; r=$?
    if [ $r -eq 0 ]; then GPU_AVAILABLE=true;
    elif [ $r -eq 2 ]; then CPU_ONLY=true; return;
    else CPU_ONLY=true; return; fi
    command -v nvcc &>/dev/null && NVCC_AVAILABLE=true
    if $GPU_AVAILABLE && { ! $CUDA_AVAILABLE || ! $NVCC_AVAILABLE; }; then
        read -p "Install CUDA & NVCC? [Y/n] " choice; choice=${choice:-Y}
        [[ $choice =~ ^[Yy]$ ]] && bash <(curl -sSL https://raw.githubusercontent.com/zunxbt/gensyn-testnet/main/cuda.sh) && source ~/.bashrc || true
    fi
}
check_cuda_installation
echo -e "\n$([ "$CPU_ONLY" = true ] && echo "${YELLOW}${BOLD}[✓] CPU-only mode${NC}" || echo "${GREEN}${BOLD}[✓] GPU acceleration${NC}")"

# Select swarm
while true; do
    echo -e "\n${CYAN}${BOLD}Select swarm: [A] Math | [B] Math Hard${NC}"
    read -p "> " ab; ab=${ab:-A}
    case $ab in [Aa]*) USE_BIG_SWARM=false; break;; [Bb]*) USE_BIG_SWARM=true; break;; *) echo "Answer A or B.";; esac
done
SWARM_CONTRACT=$([ "$USE_BIG_SWARM" = true ] && echo $BIG_SWARM_CONTRACT || echo $SMALL_SWARM_CONTRACT)

# Select parameters
while true; do
    echo -e "\n${CYAN}${BOLD}Parameters (0.5,1.5,7,32,72)?${NC}"
    read -p "> " pc; pc=${pc:-0.5}
    case $pc in 0.5|1.5|7|32|72) PARAM_B=$pc; break;; *) echo "Choose from [0.5,1.5,7,32,72]";; esac
done

# modal-login & tunnel setup (preserve updated logic)
install_localtunnel() {
    command -v lt &>/dev/null && return 0
    npm install -g localtunnel &>/dev/null && return 0
    return 1
}
install_cloudflared() {
    command -v cloudflared &>/dev/null && return 0
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH" -O cloudflared || return 1
    chmod +x cloudflared && sudo mv cloudflared /usr/local/bin/ || return 1
    return 0
}
install_ngrok() {
    command -v ngrok &>/dev/null && return 0
    wget -q "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-$OS-$NGROK_ARCH.tgz" -O ngrok.tgz || return 1
    tar -xzf ngrok.tgz && sudo mv ngrok /usr/local/bin/ && rm ngrok.tgz || return 1
    return 0
}
check_url() {
    local url=$1; local i max=3
    for ((i=0;i<max;i++)); do
        http=$(curl -s -o /dev/null -w "%{http_code}" "$url")
        [[ "$http" =~ ^(200|301|302|404)$ ]] && return 0
        sleep 2
    done
    return 1
}
try_localtunnel() {
    install_localtunnel || return 1
    TUNNEL_TYPE=localtunnel; lt --port $PORT > localtunnel.log 2>&1 & TUNNEL_PID=$!; sleep 5
    URL=$(grep -o "https://[^ ]*" localtunnel.log | head -1)
    [ -n "$URL" ] && { FORWARDING_URL=$URL; return 0; } || kill $TUNNEL_PID
    return 1
}
try_cloudflared() {
    install_cloudflared || return 1
    TUNNEL_TYPE=cloudflared; cloudflared tunnel --url http://localhost:$PORT > cloudflared.log 2>&1 & TUNNEL_PID=$!
    for i in {1..10}; do
        URL=$(grep -o 'https://[^ ]*\.trycloudflare.com' cloudflared.log | head -1)
        [ -n "$URL" ] && { check_url "$URL" && { FORWARDING_URL=$URL; return 0; }; break; }
        sleep 1
done
    kill $TUNNEL_PID
    return 1
}
try_ngrok() {
    install_ngrok || return 1
    while true; do read -p "Enter ngrok authtoken: " TOKEN; [ -n "$TOKEN" ] && { ngrok authtoken "$TOKEN"; break; }; done
    TUNNEL_TYPE=ngrok; ngrok http $PORT --log=stdout --log-format=json > ngrok.log 2>&1 & TUNNEL_PID=$!; sleep 5
    URL=$(grep -o '"public_url":"https://[^ ]*' ngrok.log | sed 's/"public_url":"//' | head -1)
    [ -n "$URL" ] && { FORWARDING_URL=$URL; return 0; } || kill $TUNNEL_PID
    return 1
}
start_tunnel() { try_localtunnel || try_cloudflared || try_ngrok; }

# development server startup
cd modal-login
npm install --legacy-peer-deps
# ensure ss
if ! command -v ss &>/dev/null; then sudo apt install -y iproute2||sudo yum install -y iproute||sudo pacman -Sy iproute2; fi
# kill 3000
ss -ltnp|grep -q':3000' && kill -9 $(ss -ltnp|grep ':3000'|grep -oP 'pid=\K[0-9]+')
npm run dev > server.log 2>&1 & SERVER_PID=$!
for i in {1..30}; do grep -q 'Local:        http://localhost:' server.log && PORT=$(grep -oP 'localhost:\K[0-9]+' server.log) && break; sleep 1; done
[ -f temp-data/userData.json ] || { detect_gpu; start_tunnel; while [ ! -f temp-data/userData.json ]; do sleep 3; done; }
ORG_ID=$(awk 'BEGIN{FS="\""}!/^[ \t]*[{}]/{print $(NF-1);exit}' temp-data/userData.json)
echo -e "${GREEN}${BOLD}[✓] ORG_ID=$ORG_ID${NC}"
cd ..

# inject contract
ENV_FILE="$ROOT/modal-login/.env"
[ -f "$ENV_FILE" ] && sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"

# Python venv on external storage
VENV_PATH="/mnt/data/.venv"
sudo chown -R $USER:$USER /mnt/data && sudo chmod -R 775 /mnt/data
[ ! -d "$VENV_PATH" ] && python3 -m venv "$VENV_PATH" || exit 1
source "$VENV_PATH/bin/activate" || exit 1
export ROOT=~/rl-swarm; export PIP_CACHE_DIR="/mnt/data/pip_cache"; mkdir -p "$PIP_CACHE_DIR"
pip install --disable-pip-version-check --cache-dir "$PIP_CACHE_DIR" --no-cache-dir -q -r "$ROOT/requirements-hivemind.txt" || exit 1
pip install --disable-pip-version-check --cache-dir "$PIP_CACHE_DIR" --no-cache-dir -q -r "$ROOT/requirements.txt" || exit 1

echo -e "${GREEN}${BOLD}[✓] Python packages installed${NC}"

# Config selection and training
echo -e "\n${CYAN}${BOLD}[✓] Configuring training...${NC}"
if [ -z "$CONFIG_PATH" ]; then
  if [ "$CPU_ONLY" = false ]; then
    case "$PARAM_B" in 32|72) CFG="gpu/grpo-qwen-2.5-${PARAM_B}b-bnb-4bit-deepseek-r1.yaml";; *) CFG="gpu/grpo-qwen-2.5-${PARAM_B}b-deepseek-r1.yaml";; esac
  else
    CFG="mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
  fi
  CONFIG_PATH="$ROOT/hivemind_exp/configs/$CFG"
  GAME=$([ "$USE_BIG_SWARM" = true ] && echo "dapo" || echo "gsm8k")
fi

# HF token
if [ -n "${HF_TOKEN}" ]; then HUGGINGFACE_ACCESS_TOKEN=$HF_TOKEN; else read -p "Push to HF Hub? [y/N] " yn; yn=${yn:-N}; case $yn in [Yy]*) read -p "HF token: " HUGGINGFACE_ACCESS_TOKEN;; *) HUGGINGFACE_ACCESS_TOKEN="None";; esac; fi

# launch training
echo -e "\n${GREEN}${BOLD}[✓] Launching training...${NC}"
CMD=(python -m hivemind_exp.${GAME}.train_single_gpu --hf_token "$HUGGINGFACE_ACCESS_TOKEN" --identity_path "$IDENTITY_PATH" --config "$CONFIG_PATH" --game "$GAME")
[ -n "$ORG_ID" ] && CMD+=(--modal_org_id "$ORG_ID") || CMD+=(--public_maddr "$PUB_MULTI_ADDRS" --initial_peers "$PEER_MULTI_ADDRS" --host_maddr "$HOST_MULTI_ADDRS")
"${CMD[@]}"

wait
