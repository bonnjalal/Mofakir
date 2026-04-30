#!/usr/bin/env bash
set -e

# Colors for terminal output
GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}    🤖 Installing Mofakir AI Assistant    ${NC}"
echo -e "${BLUE}==========================================${NC}"

if [ "$EUID" -eq 0 ]; then
  echo -e "${RED}Please do NOT run this script as root. Run as your normal user.${NC}"
  echo -e "The script will ask for sudo password when installing system packages."
  exit 1
fi

# Define Standard Paths
SHARE_DIR="$HOME/.local/share/mofakir"
BIN_DIR="$SHARE_DIR/bin"
MODELS_DIR="$SHARE_DIR/models"
SOUNDS_DIR="$SHARE_DIR/sounds"
VENV_DIR="$SHARE_DIR/venv"
LOCAL_BIN="$HOME/.local/bin"

mkdir -p "$BIN_DIR" "$MODELS_DIR" "$SOUNDS_DIR" "$LOCAL_BIN"

# ==========================================
# 1. OS DETECTION & SYSTEM PACKAGES
# ==========================================
echo -e "\n${YELLOW}[1/6] Detecting OS and installing system dependencies...${NC}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_LIKE=$ID_LIKE
else
    echo -e "${RED}Cannot detect OS. /etc/os-release is missing.${NC}"
    exit 1
fi

if [[ "$OS" == "arch" || "$OS_LIKE" == *"arch"* ]]; then
    echo -e "Arch Linux detected. Using pacman..."
    sudo pacman -Syu --needed --noconfirm sox jq wl-clipboard grim playerctl tk python python-virtualenv wget curl base-devel git
elif [[ "$OS" == "ubuntu" || "$OS" == "debian" || "$OS_LIKE" == *"debian"* || "$OS_LIKE" == *"ubuntu"* ]]; then
    echo -e "Debian/Ubuntu detected. Using apt..."
    sudo apt-get update
    sudo apt-get install -y sox libsox-fmt-all jq wl-clipboard grim playerctl python3-tk python3-venv wget curl build-essential git
else
    echo -e "${RED}Unsupported OS for automated dependencies: $OS${NC}"
    echo -e "Please ensure you have: sox, jq, wl-clipboard, grim, playerctl, python3-tk, python3-venv, build-essential"
fi

# ==========================================
# 2. PYTHON VIRTUAL ENVIRONMENT
# ==========================================
echo -e "\n${YELLOW}[2/6] Setting up isolated Python environment...${NC}"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

echo "Installing Python packages (OpenAI, Edge-TTS, DDG, LangDetect)..."
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install openai duckduckgo-search requests beautifulsoup4 edge-tts langdetect

# ==========================================
# 3. WHISPER.CPP & PIPER TTS BINARIES
# ==========================================
echo -e "\n${YELLOW}[3/6] Setting up AI Audio Binaries...${NC}"

# Compile whisper.cpp if not present
if [ ! -f "$BIN_DIR/whisper-cli" ]; then
    echo "Compiling whisper.cpp from source (this is fast)..."
    rm -rf /tmp/whisper_build
    git clone https://github.com/ggerganov/whisper.cpp.git /tmp/whisper_build
    cd /tmp/whisper_build
    make -j$(nproc)
    cp main "$BIN_DIR/whisper-cli"
    cd - > /dev/null
    rm -rf /tmp/whisper_build
else
    echo "whisper-cli already installed."
fi

# Download Piper TTS if not present
if [ ! -f "$BIN_DIR/piper" ]; then
    echo "Downloading Piper TTS..."
    ARCH=$(uname -m)
    if [ "$ARCH" == "x86_64" ]; then
        wget -q --show-progress -O /tmp/piper.tar.gz "https://github.com/rhasspy/piper/releases/download/v1.2.0/piper_linux_x86_64.tar.gz"
        tar -xzf /tmp/piper.tar.gz -C /tmp/
        cp -r /tmp/piper/* "$BIN_DIR/"
        rm -rf /tmp/piper.tar.gz /tmp/piper
    else
        echo -e "${RED}Automated Piper install only supports x86_64. Please compile Piper manually for $ARCH.${NC}"
    fi
else
    echo "piper already installed."
fi

# ==========================================
# 4. DOWNLOADING AI MODELS (MULTI-LINGUAL)
# ==========================================
echo -e "\n${YELLOW}[4/6] Downloading Local AI Models...${NC}"

cd "$MODELS_DIR"

if [ ! -f "ggml-small.bin" ]; then
    echo "Downloading Whisper Small model (~240MB)..."
    wget -q --show-progress -O ggml-small.bin "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
fi

echo -e "\n${BLUE}Which Local TTS Languages would you like to install?${NC}"
echo "1) English (US)"
echo "2) Arabic (JO)"
echo "3) French (FR)"
echo "4) Spanish (ES)"
echo "5) German (DE)"
echo -n "Enter numbers separated by space (default: 1 2): "
read -r lang_choices
if [ -z "$lang_choices" ]; then lang_choices="1 2"; fi

dl_piper() {
    local lang=$1
    local region=$2
    local voice=$3
    local quality=$4
    local model="${region}-${voice}-${quality}.onnx"
    local url="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/${lang}/${region}/${voice}/${quality}/${model}"
    
    if [ ! -f "$model" ]; then
        echo "Downloading $model..."
        wget -q --show-progress -O "$model" "$url"
        wget -q -O "${model}.json" "${url}.json"
    else
        echo "$model already installed."
    fi
}

for choice in $lang_choices; do
    case $choice in
        1) dl_piper "en" "en_US" "lessac" "medium" ;;
        2) dl_piper "ar" "ar_JO" "kareem" "medium" ;;
        3) dl_piper "fr" "fr_FR" "upmc" "medium" ;;
        4) dl_piper "es" "es_ES" "sharvard" "medium" ;;
        5) dl_piper "de" "de_DE" "thorsten" "medium" ;;
        *) echo "Skipping unknown choice: $choice" ;;
    esac
done
cd - > /dev/null

# ==========================================
# 5. SYNTHESIZING SOUNDS & COPYING SCRIPTS
# ==========================================
echo -e "\n${YELLOW}[5/6] Finalizing assets and scripts...${NC}"

# Synthesize basic beep sounds so we don't need external WAV files!
if [ ! -f "$SOUNDS_DIR/start.wav" ]; then
    sox -n "$SOUNDS_DIR/start.wav" synth 0.1 sine 800 vol 0.5
fi
if [ ! -f "$SOUNDS_DIR/stop.wav" ]; then
    sox -n "$SOUNDS_DIR/stop.wav" synth 0.15 sine 400 vol 0.5
fi

# Copy core scripts to the share directory
if [ -f "src/mofakir.sh" ] && [ -f "src/mofakir-gui.py" ]; then
    cp src/mofakir.sh "$SHARE_DIR/mofakir.sh"
    cp src/mofakir-gui.py "$SHARE_DIR/mofakir-gui.py"
    chmod +x "$SHARE_DIR/mofakir.sh" "$SHARE_DIR/mofakir-gui.py"
elif [ -f "mofakir.sh" ] && [ -f "mofakir-gui.py" ]; then
    cp mofakir.sh "$SHARE_DIR/mofakir.sh"
    cp mofakir-gui.py "$SHARE_DIR/mofakir-gui.py"
    chmod +x "$SHARE_DIR/mofakir.sh" "$SHARE_DIR/mofakir-gui.py"
else
    echo -e "${RED}Error: Could not find mofakir.sh and mofakir-gui.py in the current directory.${NC}"
    exit 1
fi

# ==========================================
# 6. CREATING EXECUTABLE WRAPPERS
# ==========================================
echo -e "\n${YELLOW}[6/6] Creating executable wrappers in ~/.local/bin...${NC}"

# Mofakir Orchestrator Wrapper
cat << EOF > "$LOCAL_BIN/mofakir"
#!/usr/bin/env bash
# Inject our isolated binaries and python venv into the PATH
export PATH="$BIN_DIR:$VENV_DIR/bin:\$PATH"
exec "$SHARE_DIR/mofakir.sh" "\$@"
EOF

# Mofakir GUI Wrapper
cat << EOF > "$LOCAL_BIN/mofakir-gui"
#!/usr/bin/env bash
# Inject our isolated binaries and python venv into the PATH
export PATH="$BIN_DIR:$VENV_DIR/bin:\$PATH"
exec "$VENV_DIR/bin/python3" "$SHARE_DIR/mofakir-gui.py" "\$@"
EOF

chmod +x "$LOCAL_BIN/mofakir" "$LOCAL_BIN/mofakir-gui"

# ==========================================
# DONE
# ==========================================
echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}        🎉 INSTALLATION COMPLETE 🎉       ${NC}"
echo -e "${GREEN}==========================================${NC}"
echo -e "Mofakir is installed to ${BLUE}~/.local/bin/mofakir${NC}"
echo -e "\nMake sure ${YELLOW}~/.local/bin${NC} is in your system PATH."
echo -e "To configure Mofakir, simply run it for the first time:"
echo -e "  ${BLUE}mofakir --voice${NC}"
echo -e "This will generate your config file at ~/.config/mofakir/config.json\n"
