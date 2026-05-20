#!/usr/bin/env bash
set -e

GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m' 
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}    🤖 Installing Mofakir AI Assistant    ${NC}"
echo -e "${BLUE}==========================================${NC}"

if [ "$EUID" -eq 0 ]; then
  echo -e "${RED}Please do NOT run this script as root.${NC}"
  exit 1
fi

SHARE_DIR="$HOME/.local/share/mofakir"
BIN_DIR="$SHARE_DIR/bin"
MODELS_DIR="$SHARE_DIR/models"
SOUNDS_DIR="$SHARE_DIR/sounds"
VENV_DIR="$SHARE_DIR/venv"
LOCAL_BIN="$HOME/.local/bin"

mkdir -p "$BIN_DIR" "$MODELS_DIR" "$SOUNDS_DIR" "$LOCAL_BIN"

echo -e "\n${YELLOW}[1/6] Detecting OS and installing system dependencies...${NC}"
if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; OS_LIKE=$ID_LIKE; else exit 1; fi

if [[ "$OS" == "arch" || "$OS_LIKE" == *"arch"* ]]; then
    sudo pacman -Syu --needed --noconfirm sox jq wl-clipboard grim playerctl python python-virtualenv wget curl base-devel git xclip maim xdotool wmctrl cmake xcb-util-cursor
elif [[ "$OS" == "ubuntu" || "$OS" == "debian" || "$OS_LIKE" == *"debian"* || "$OS_LIKE" == *"ubuntu"* ]]; then
    sudo apt-get update
    sudo apt-get install -y sox libsox-fmt-all jq wl-clipboard grim playerctl python3-venv wget curl build-essential git xclip maim xdotool wmctrl cmake libxcb-cursor0
fi

echo -e "\n${YELLOW}[2/6] Setting up isolated Python environment...${NC}"
if [ ! -d "$VENV_DIR" ]; then python3 -m venv "$VENV_DIR"; fi
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install openai ddgs requests beautifulsoup4 edge-tts langdetect PyQt6

echo -e "\n${YELLOW}[3/6] Setting up AI Audio Binaries...${NC}"
if [ ! -f "$BIN_DIR/whisper-cli" ] || (command -v ldd >/dev/null && ldd "$BIN_DIR/whisper-cli" 2>&1 | grep -q "not found"); then
    echo "Rebuilding/repairing whisper-cli..."
    rm -rf /tmp/whisper_build
    git clone https://github.com/ggerganov/whisper.cpp.git /tmp/whisper_build
    cd /tmp/whisper_build
    
    cmake -B build -DBUILD_SHARED_LIBS=OFF
    cmake --build build --config Release -j$(nproc) || true
    
    WHISPER_BIN=$(find . -type f \( -name "whisper-cli" -o -name "main" \) -executable | head -n 1)
    
    if [ -n "$WHISPER_BIN" ]; then
        cp "$WHISPER_BIN" "$BIN_DIR/whisper-cli"
    else
        echo -e "${RED}FATAL ERROR: Failed to find compiled whisper binary! Installation aborted.${NC}"
        exit 1
    fi
    
    cd "$REPO_DIR"
    rm -rf /tmp/whisper_build
fi

if [ ! -f "$BIN_DIR/piper" ]; then
    if [ "$(uname -m)" == "x86_64" ]; then
        echo "Downloading Piper TTS Binary..."
        rm -f /tmp/piper.tar.gz
        
        PIPER_URL="https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz"
        DOWNLOAD_SUCCESS=false
        
        MIRRORS=(
            "$PIPER_URL"
            "https://ghp.ci/$PIPER_URL"
            "https://ghfast.top/$PIPER_URL"
            "https://mirror.ghproxy.com/$PIPER_URL"
        )
        
        for url in "${MIRRORS[@]}"; do
            echo "Attempting download from: $url"
            if wget -c --tries=3 -U "$USER_AGENT" -q --show-progress -O /tmp/piper.tar.gz "$url"; then
                DOWNLOAD_SUCCESS=true
                break
            fi
        done
        
        if [ "$DOWNLOAD_SUCCESS" = true ] && [ -s /tmp/piper.tar.gz ]; then
            tar -xzf /tmp/piper.tar.gz -C /tmp/
            cp -r /tmp/piper/* "$BIN_DIR/"
            rm -rf /tmp/piper.tar.gz /tmp/piper
        else
            echo -e "${RED}FATAL ERROR: Failed to download Piper TTS. Installation aborted.${NC}"
            rm -f /tmp/piper.tar.gz
            exit 1
        fi
    fi
fi

echo -e "\n${YELLOW}[4/6] Downloading Local AI Models...${NC}"
cd "$MODELS_DIR"

needs_download=true
if [ -f "ggml-small.bin" ]; then
    filesize=$(stat -c%s "ggml-small.bin" 2>/dev/null || wc -c < "ggml-small.bin")
    if [ "$filesize" -ge 200000000 ]; then needs_download=false; fi
fi

if [ "$needs_download" = true ]; then 
    echo "Downloading Whisper Small (Q8 Quantized) model (~250MB)..."
    WHISPER_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin"
    HF_MIRROR="https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin"
    
    if ! wget -c --tries=3 -U "$USER_AGENT" -q --show-progress -O ggml-small.bin "$WHISPER_URL"; then
        echo "Official link failed, trying HF-Mirror..."
        if ! wget -c --tries=3 -U "$USER_AGENT" -q --show-progress -O ggml-small.bin "$HF_MIRROR"; then
            echo -e "${RED}FATAL ERROR: Failed to download Whisper model. Installation aborted.${NC}"
            exit 1
        fi
    fi
fi

dl_piper() {
    if [ ! -f "$5.onnx" ]; then
        echo "  -> Downloading TTS Voice: $5..."
        
        local url1="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/$1/$2/$3/$4/$5.onnx"
        local url2="https://hf-mirror.com/rhasspy/piper-voices/resolve/v1.0.0/$1/$2/$3/$4/$5.onnx"
        
        if ! wget -c --tries=3 -U "$USER_AGENT" -q --show-progress -O "$5.onnx" "$url1"; then
            if ! wget -c --tries=3 -U "$USER_AGENT" -q --show-progress -O "$5.onnx" "$url2"; then
                echo -e "${RED}FATAL ERROR: Failed to download TTS voice model $5.onnx.${NC}"
                exit 1
            fi
        fi
        
        local json1="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/$1/$2/$3/$4/$5.onnx.json"
        local json2="https://hf-mirror.com/rhasspy/piper-voices/resolve/v1.0.0/$1/$2/$3/$4/$5.onnx.json"
        
        if ! wget -c --tries=3 -U "$USER_AGENT" -q -O "$5.onnx.json" "$json1"; then
            if ! wget -c --tries=3 -U "$USER_AGENT" -q -O "$5.onnx.json" "$json2"; then
                echo -e "${RED}FATAL ERROR: Failed to download TTS voice JSON $5.onnx.json.${NC}"
                exit 1
            fi
        fi
    fi
}

echo -e "\n${BLUE}Select TTS languages to install for offline voice synthesis:${NC}"
echo "  en - English (Default)    de - German         ru - Russian"
echo "  ar - Arabic               it - Italian        zh - Chinese"
echo "  fr - French               ja - Japanese       es - Spanish"
echo "  pt - Portuguese           all - Install all"

# Use tty redirection to read input safely in headless or pipeline environments
read -p "Enter languages separated by space (default: en): " selected_langs </dev/tty || selected_langs="en"

if [ -z "$selected_langs" ]; then selected_langs="en"; fi
if [[ "$selected_langs" == *"all"* ]]; then selected_langs="en ar fr es de it ja pt ru zh"; fi

for lang in $selected_langs; do
    case $lang in
        en) dl_piper "en" "en_US" "lessac" "medium" "en_US-lessac-medium" ;;
        ar) dl_piper "ar" "ar_JO" "kareem" "medium" "ar_JO-kareem-medium" ;;
        fr) dl_piper "fr" "fr_FR" "upmc" "medium" "fr_FR-upmc-medium" ;;
        es) dl_piper "es" "es_ES" "sharvard" "medium" "es_ES-sharvard-medium" ;;
        de) dl_piper "de" "de_DE" "thorsten" "medium" "de_DE-thorsten-medium" ;;
        it) dl_piper "it" "it_IT" "riccardo" "xlow" "it_IT-riccardo-xlow" ;;
        ja) dl_piper "ja" "ja_JP" "dani" "low" "ja_JP-dani-low" ;;
        pt) dl_piper "pt" "pt_PT" "tugao" "medium" "pt_PT-tugao-medium" ;;
        ru) dl_piper "ru" "ru_RU" "denis" "medium" "ru_RU-denis-medium" ;;
        zh) dl_piper "zh" "zh_CN" "huashan" "medium" "zh_CN-huashan-medium" ;;
        *) echo -e "${YELLOW}Warning: Unknown language code '$lang', skipping.${NC}" ;;
    esac
done

# Force return to repository directory before starting the copy actions
cd "$REPO_DIR"

echo -e "\n${YELLOW}[5/6] Finalizing assets and scripts...${NC}"

# Ensure default assets exist and are copied over safely
if [ -d "$REPO_DIR/sounds" ] && [ "$(ls -A "$REPO_DIR/sounds" 2>/dev/null)" ]; then 
    cp "$REPO_DIR/sounds"/* "$SOUNDS_DIR/"
else
    echo "Generating default UI sounds using sox..."
    sox -n "$SOUNDS_DIR/start.wav" synth 0.1 sine 800 vol 0.5 || true
    sox -n "$SOUNDS_DIR/stop.wav" synth 0.15 sine 400 vol 0.5 || true
fi

mkdir -p "$HOME/.config/mofakir"
if [ ! -f "$HOME/.config/mofakir/config.json" ] && [ -f "$REPO_DIR/config.json" ]; then 
    cp "$REPO_DIR/config.json" "$HOME/.config/mofakir/config.json"
fi

# Critical copies (any failure here will exit with error)
cp "$REPO_DIR/trigger.sh" "$SHARE_DIR/mofakir.sh"
cp "$REPO_DIR/src/mofakir-gui.py" "$SHARE_DIR/mofakir-gui.py"
cp "$REPO_DIR/src/ui.qml" "$SHARE_DIR/ui.qml"
chmod +x "$SHARE_DIR/mofakir.sh" "$SHARE_DIR/mofakir-gui.py"

echo -e "\n${YELLOW}[6/6] Creating executable wrappers in ~/.local/bin...${NC}"
cat << EOF > "$LOCAL_BIN/mofakir"
#!/usr/bin/env bash
export PATH="$BIN_DIR:$VENV_DIR/bin:\$PATH"
exec "$SHARE_DIR/mofakir.sh" "\$@"
EOF
cat << EOF > "$LOCAL_BIN/mofakir-gui"
#!/usr/bin/env bash
export PATH="$BIN_DIR:$VENV_DIR/bin:\$PATH"
exec "$VENV_DIR/bin/python3" "$SHARE_DIR/mofakir-gui.py" "\$@"
EOF
chmod +x "$LOCAL_BIN/mofakir" "$LOCAL_BIN/mofakir-gui"

echo -e "\n${GREEN}        🎉 INSTALLATION COMPLETE 🎉       ${NC}"
