#!/usr/bin/env bash

## DYNAMIC ARGUMENT PARSING
MODE_VOICE=false
MODE_CLIPBOARD=false
MODE_SCREEN=false
TOGGLE_FLAG=""

for arg in "$@"; do
    case $arg in
        --voice) MODE_VOICE=true ;;
        --clipboard) MODE_CLIPBOARD=true ;;
        --screen) MODE_SCREEN=true ;;
        --toggle) TOGGLE_FLAG="--toggle" ;;
    esac
done

CONFIG_FILE="$HOME/.config/mofakir/config.json"
TEMP_DIR="/tmp/mofakir"
PID_FILE="$TEMP_DIR/initial_recording.pid"
SOUND_DIR="$HOME/.local/share/mofakir/sounds"
mkdir -p "$TEMP_DIR" "$SOUND_DIR"

if [ ! -f "$CONFIG_FILE" ]; then mofakir-gui ""; exit 1; fi

WHISPER_MODEL=$(jq -r '.voice.whisper_model' "$CONFIG_FILE")

if [[ "$WHISPER_MODEL" == "null" || -z "$WHISPER_MODEL" ]]; then
    WHISPER_MODEL="$HOME/.local/share/mofakir/models/ggml-small.bin"
else
    WHISPER_MODEL="${WHISPER_MODEL/#\~/$HOME}"
fi

if [ ! -f "$WHISPER_MODEL" ]; then
    notify-send -u normal "Mofakir AI" "Downloading Whisper model (ggml-small.bin) for the first time..."
    mkdir -p "$(dirname "$WHISPER_MODEL")"
    wget -q --show-progress -O "$WHISPER_MODEL" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
fi

if pgrep -f "mofakir-gui" > /dev/null; then
    echo "toggle" > "$TEMP_DIR/gui_signal"
    exit 0
fi

if [[ "$TOGGLE_FLAG" == "--toggle" && -f "$PID_FILE" ]]; then
    if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        kill $(cat "$PID_FILE") 2>/dev/null
        rm -f "$PID_FILE"
        pw-play "$SOUND_DIR/stop.wav" 2>/dev/null &
        exit 0
    fi
fi

if pgrep -x "rec" > /dev/null; then
    notify-send -u critical "🎙️ Mic Busy!" "Mofakir is already recording."
    exit 1
fi

## CONTEXT GATHERING
ACTIVE_WIN=""
if command -v hyprctl &> /dev/null && [ "$XDG_SESSION_TYPE" == "wayland" ]; then
    ACTIVE_WIN=$(hyprctl activewindow | head -n 1 | awk '{print $2}')
fi
WIN_CONTEXT=""
if [[ -n "$ACTIVE_WIN" && "$ACTIVE_WIN" != "Invalid" ]]; then
    WIN_CONTEXT="[SYSTEM: The user's active window address is 0x$ACTIVE_WIN.] "
fi

CLIP_CONTEXT=""
if [[ "$MODE_CLIPBOARD" == true ]]; then
    if [ "$XDG_SESSION_TYPE" == "wayland" ] && command -v wl-paste &> /dev/null; then
        MIME_TYPE=$(wl-paste --list-types | head -n 1)
        if [[ "$MIME_TYPE" == text/* ]]; then CLIP_CONTEXT="Regarding this text: '''$(wl-paste)'''. "
        elif [[ "$MIME_TYPE" == image/* ]]; then wl-paste > "$TEMP_DIR/clipboard.png"; CLIP_CONTEXT="[IMAGE PATH: $TEMP_DIR/clipboard.png] "
        elif [[ "$MIME_TYPE" == "text/uri-list" ]]; then CLIP_CONTEXT="[FILE PATH: $(printf '%b' "$(wl-paste | head -n 1 | sed 's/^file:\/\///' | sed 's/%/\\x/g')")] "; fi
    fi
elif [[ "$MODE_SCREEN" == true ]]; then
    rm -f "$TEMP_DIR/screen.png"
    if [ "$XDG_SESSION_TYPE" == "wayland" ] && command -v grim &> /dev/null; then grim "$TEMP_DIR/screen.png"; fi
    if [ -f "$TEMP_DIR/screen.png" ]; then CLIP_CONTEXT="[IMAGE PATH: $TEMP_DIR/screen.png] Regarding this screenshot: "; fi
fi

USER_PROMPT=""
LAUNCH_FLAG="--text"

if [[ "$MODE_VOICE" == true ]]; then
    LAUNCH_FLAG="--voice"
    pw-play "$SOUND_DIR/start.wav" 2>/dev/null &
    
    if [[ "$TOGGLE_FLAG" == "--toggle" ]]; then
        notify-send -t 3000 "🎙️ Mofakir" "Listening... Press shortcut again to stop."
        rec -q -r 16000 -c 1 -b 16 -e signed-integer "$TEMP_DIR/voice.wav" &
        echo $! > "$PID_FILE"
        wait $! 
    else
        rec -q -r 16000 -c 1 -b 16 -e signed-integer "$TEMP_DIR/voice.wav" silence 1 0.1 1% 1 1.5 1%
        pw-play "$SOUND_DIR/stop.wav" 2>/dev/null &
    fi
    
    RAW_TRANSCRIPT=$(whisper-cli -m "$WHISPER_MODEL" -f "$TEMP_DIR/voice.wav" -nt -l auto)
    USER_PROMPT=$(echo "$RAW_TRANSCRIPT" | sed -e 's/\[.*\]//g' | xargs)
fi

# Launch PyQt6 GUI with combined context and voice modes
FINAL_PROMPT="$WIN_CONTEXT$CLIP_CONTEXT$USER_PROMPT"
mofakir-gui "$FINAL_PROMPT" "$LAUNCH_FLAG" &
