#!/usr/bin/env bash

MODE=$1       # --voice, --clipboard, or --screen
TOGGLE=$2     # --toggle (optional)

CONFIG_FILE="$HOME/.config/mofakir/config.json"
TEMP_DIR="/tmp/mofakir"
PID_FILE="$TEMP_DIR/recording.pid"
mkdir -p "$TEMP_DIR"

# First-run check: Let Python generate the config GUI
if [ ! -f "$CONFIG_FILE" ]; then
    mofakir-gui ""
    exit 1
fi

WHISPER_MODEL=$(jq -r '.voice.whisper_model' "$CONFIG_FILE")

# ==========================================
# 🚫 SMART CONCURRENCY & RESPAWN GUARD
# ==========================================
if [[ "$TOGGLE" != "--toggle" || ! -f "$PID_FILE" ]]; then
    if pgrep -x "rec" > /dev/null || pgrep -x "sox" > /dev/null; then
        notify-send -u critical "🎙️ Mic Busy!" "Mofakir is already recording."
        exit 1
    fi
    
    # If the GUI is already open, cleanly kill it to start a new context
    if pgrep -f "mofakir-gui" > /dev/null; then
        pkill -f "mofakir-gui"
    fi
fi

# ==========================================
# 🪟 WINDOW CONTEXT
# ==========================================
ACTIVE_WIN=""
if command -v hyprctl &> /dev/null; then
    ACTIVE_WIN=$(hyprctl activewindow | head -n 1 | awk '{print $2}')
fi

WIN_CONTEXT=""
if [[ -n "$ACTIVE_WIN" && "$ACTIVE_WIN" != "Invalid" ]]; then
    WIN_CONTEXT="[SYSTEM: The user's active window address is 0x$ACTIVE_WIN. For desktop tools, append this to the target, e.g., '5,address:0x$ACTIVE_WIN'.] "
fi

# ==========================================
# 🎤 RECORDING PHASE
# ==========================================
if [[ "$TOGGLE" == "--toggle" ]]; then
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        kill $(cat "$PID_FILE") 2>/dev/null
        rm -f "$PID_FILE"
        pw-play ~/.local/share/mofakir/sounds/stop.wav 2>/dev/null &
        notify-send -t 2000 "⚙️ Processing..." "Transcribing audio..."
    else
        pw-play ~/.local/share/mofakir/sounds/start.wav 2>/dev/null &
        notify-send -t 3000 "🎙️ Mofakir Manual Mode" "Listening... Press shortcut again to stop."
        rec -q -r 16000 -c 1 -b 16 -e signed-integer "$TEMP_DIR/voice.wav" &
        echo $! > "$PID_FILE"
        exit 0 
    fi
else
    pw-play ~/.local/share/mofakir/sounds/start.wav 2>/dev/null &
    timeout 10 rec -q -r 16000 -c 1 -b 16 -e signed-integer "$TEMP_DIR/voice.wav" silence 1 0.1 1% 1 1.5 1%
    pw-play ~/.local/share/mofakir/sounds/stop.wav 2>/dev/null &
fi

# ==========================================
# 📋 CONTEXT GATHERING
# ==========================================
CLIP_CONTEXT=""
if [[ "$MODE" == "--clipboard" ]]; then
    MIME_TYPE=$(wl-paste --list-types | head -n 1)
    if [[ "$MIME_TYPE" == text/* ]]; then
        CLIP_CONTEXT="Regarding this text: '''$(wl-paste)'''. "
    elif [[ "$MIME_TYPE" == image/* ]]; then
        wl-paste > "$TEMP_DIR/clipboard.png"
        CLIP_CONTEXT="[IMAGE PATH: $TEMP_DIR/clipboard.png] "
    elif [[ "$MIME_TYPE" == "text/uri-list" ]]; then
        FILE_PATH=$(wl-paste | head -n 1 | sed 's/^file:\/\///' | sed 's/%/\\x/g')
        CLIP_CONTEXT="[FILE PATH: $(printf '%b' "$FILE_PATH")] "
    fi
elif [[ "$MODE" == "--screen" ]]; then
    grim "$TEMP_DIR/screen.png"
    CLIP_CONTEXT="[IMAGE PATH: $TEMP_DIR/screen.png] Regarding this screenshot of my current screen: "
fi

# ==========================================
# 🧠 TRANSCRIPTION & GUI HANDOFF
# ==========================================
RAW_TRANSCRIPT=$(whisper-cli -m "$WHISPER_MODEL" -f "$TEMP_DIR/voice.wav" -nt -l auto)
USER_PROMPT=$(echo "$RAW_TRANSCRIPT" | sed -e 's/\[.*\]//g' | xargs)

FINAL_PROMPT="$WIN_CONTEXT$CLIP_CONTEXT$USER_PROMPT"

# Launch the new Native Python GUI
mofakir-gui "$FINAL_PROMPT" &
