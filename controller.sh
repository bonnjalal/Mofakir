#!/usr/bin/env bash

# Arguments
MODE=$1       # --voice, --clipboard, or --screen
TOGGLE=$2     # --toggle (optional)

CONFIG_FILE="$HOME/.config/mofakir/config.json"

# First-run check: If config doesn't exist, run the python script to generate it, then abort.
if [ ! -f "$CONFIG_FILE" ]; then
    ~/.local/bin/ask ""
    exit 1
fi

# Load settings from Unified JSON config via jq
TTS_ENGINE=$(jq -r '.voice.tts_engine' "$CONFIG_FILE")
WHISPER_MODEL=$(jq -r '.voice.whisper_model' "$CONFIG_FILE")
TTS_LOCAL_EN=$(jq -r '.voice.tts_local_model_en' "$CONFIG_FILE")
TTS_LOCAL_AR=$(jq -r '.voice.tts_local_model_ar' "$CONFIG_FILE")
TTS_ONLINE_EN=$(jq -r '.voice.tts_online_voice_en' "$CONFIG_FILE")
TTS_ONLINE_AR=$(jq -r '.voice.tts_online_voice_ar' "$CONFIG_FILE")

TEMP_DIR="/tmp/mofakir"
PID_FILE="$TEMP_DIR/recording.pid"
LOCK_FILE="$TEMP_DIR/thinking.lock"
WAIT_FILE="$TEMP_DIR/waiting.pid"
BOUNCE_LOCK="$TEMP_DIR/bounce.lock"
mkdir -p "$TEMP_DIR"

trap 'rmdir "$BOUNCE_LOCK" 2>/dev/null' EXIT
if ! mkdir "$BOUNCE_LOCK" 2>/dev/null; then exit 1; fi

# ==========================================
# 🚫 SMART CONCURRENCY & WAKE-UP GUARD
# ==========================================
if [[ "$TOGGLE" == "--toggle" && -f "$PID_FILE" ]]; then
    : # Let toggle stop the manual recording
else
    # 1. Check if Mic is busy
    if pgrep -x "rec" > /dev/null || pgrep -x "sox" > /dev/null; then
        notify-send -u critical "🎙️ Mic Busy!" "Mofakir is already recording."
        exit 1
    fi
    
    # 2. Check if AI is actively generating (Do not disturb)
    if [ -f "$LOCK_FILE" ]; then
        LOCK_PID=$(cat "$LOCK_FILE")
        if kill -0 "$LOCK_PID" 2>/dev/null; then
            notify-send -u critical "🧠 AI Busy!" "Mofakir is currently thinking."
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi

    # 3. Check if WezTerm is IDLE and waiting for a reply
    if [ -f "$WAIT_FILE" ]; then
        WAIT_PID=$(cat "$WAIT_FILE")
        if kill -0 "$WAIT_PID" 2>/dev/null; then
            # The "Close & Respawn" Approach:
            # Tell Hyprland to cleanly destroy the idle window
            hyprctl dispatch closewindow "class:ai_mofakir" 2>/dev/null
            
            # Force-kill the background script just in case
            kill -9 "$WAIT_PID" 2>/dev/null
            
            # Clean up the locks
            rm -f "$WAIT_FILE" "$LOCK_FILE"
            
            # IMPORTANT: We DO NOT 'exit 0' here anymore! 
            # We let the script fall right through to start a brand new recording.
        else
            rm -f "$WAIT_FILE"
        fi
    fi
fi

# ==========================================
# 🪟 WINDOW CONTEXT
# ==========================================
ACTIVE_WIN=$(hyprctl activewindow | head -n 1 | awk '{print $2}')
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
        pw-play ~/.config/mofakir/sounds/stop.wav &
        notify-send -t 2000 "⚙️ Processing..." "Transcribing audio..."
    else
        pw-play ~/.config/mofakir/sounds/start.wav &
        notify-send -t 3000 "🎙️ Mofakir Manual Mode" "Listening... Press shortcut again to stop."
        rec -q -r 16000 -c 1 -b 16 -e signed-integer "$TEMP_DIR/voice.wav" &
        echo $! > "$PID_FILE"
        exit 0 
    fi
else
    pw-play ~/.config/mofakir/sounds/start.wav &
    timeout 10 rec -q -r 16000 -c 1 -b 16 -e signed-integer "$TEMP_DIR/voice.wav" silence 1 0.1 1% 1 1.5 1%
    pw-play ~/.config/mofakir/sounds/stop.wav &
fi

# ==========================================
# 📋 CLIPBOARD & SCREEN CONTEXT
# ==========================================
CLIP_CONTEXT=""
if [[ "$MODE" == "--clipboard" ]]; then
    MIME_TYPE=$(wl-paste --list-types | head -n 1)
    if [[ "$MIME_TYPE" == text/* ]]; then
        CLIP_TEXT=$(wl-paste)
        CLIP_CONTEXT="Regarding this text: '''$CLIP_TEXT'''. "
    elif [[ "$MIME_TYPE" == image/* ]]; then
        wl-paste > "$TEMP_DIR/clipboard.png"
        CLIP_CONTEXT="[IMAGE PATH: $TEMP_DIR/clipboard.png] "
    elif [[ "$MIME_TYPE" == "text/uri-list" ]]; then
        FILE_PATH=$(wl-paste | head -n 1 | sed 's/^file:\/\///')
        FILE_PATH=$(printf '%b' "${FILE_PATH//%/\\x}")
        CLIP_CONTEXT="[FILE PATH: $FILE_PATH] "
    fi
elif [[ "$MODE" == "--screen" ]]; then
    grim "$TEMP_DIR/screen.png"
    CLIP_CONTEXT="[IMAGE PATH: $TEMP_DIR/screen.png] Regarding this screenshot of my current screen: "
fi

# ==========================================
# 🧠 TRANSCRIPTION PHASE
# ==========================================
RAW_TRANSCRIPT=$(whisper-cli -m "$WHISPER_MODEL" -f "$TEMP_DIR/voice.wav" -nt -l auto)
USER_PROMPT=$(echo "$RAW_TRANSCRIPT" | sed -e 's/\[.*\]//g' | xargs)

FINAL_PROMPT="$WIN_CONTEXT$CLIP_CONTEXT$USER_PROMPT"
echo "$FINAL_PROMPT" > "$TEMP_DIR/prompt.txt"

# ==========================================
# 💻 WEZTERM INTERACTIVE WRAPPER
# ==========================================
cat << 'EOF' > "$TEMP_DIR/run_ai.sh"
#!/usr/bin/env bash

# Clean up ALL locks if WezTerm is closed abruptly
trap 'rm -f /tmp/mofakir/thinking.lock /tmp/mofakir/waiting.pid' EXIT

while true; do
    # 🔴 STATE 1: THINKING & GENERATING
    rm -f /tmp/mofakir/waiting.pid
    echo $$ > /tmp/mofakir/thinking.lock

    clear
    echo -e '\e[1;36m🤖 MOFAKIR:\e[0m\n'

    ~/.local/bin/ask "$(cat /tmp/mofakir/prompt.txt)" | tee /tmp/mofakir/answer.txt

    echo -e '\n\n\e[1;30m🔊 Speaking...\e[0m'

    # DYNAMIC TTS ENGINE
    if [[ "$TTS_ENGINE" == "online" ]]; then
        if grep -q '[أ-ي]' /tmp/mofakir/answer.txt; then
            edge-tts --voice "$TTS_ONLINE_AR" --rate "+5%" --text "$(cat /tmp/mofakir/answer.txt)" --write-media /tmp/mofakir/tts.wav
        else
            edge-tts --voice "$TTS_ONLINE_EN" --rate "+5%" --text "$(cat /tmp/mofakir/answer.txt)" --write-media /tmp/mofakir/tts.wav
        fi
    else
        if grep -q '[أ-ي]' /tmp/mofakir/answer.txt; then
            cat /tmp/mofakir/answer.txt | piper --model "$TTS_LOCAL_AR" --length_scale 0.75 --output_file /tmp/mofakir/tts.wav
        else
            cat /tmp/mofakir/answer.txt | piper --model "$TTS_LOCAL_EN" --output_file /tmp/mofakir/tts.wav
        fi
    fi

    pw-play /tmp/mofakir/tts.wav

    # 🟢 STATE 2: WAITING FOR USER REPLY
    rm -f /tmp/mofakir/thinking.lock
    echo $$ > /tmp/mofakir/waiting.pid

    echo -e '\n\e[1;32m> Type your reply (Enter to close, or type "v" + Enter to speak):\e[0m'
    
    # This blocks until you type something
    USER_REPLY=""
    read USER_REPLY
    
    if [[ "$USER_REPLY" == "v" || "$USER_REPLY" == "V" ]]; then
        echo -e '\e[1;35m🎙️ Listening... (Auto-stops when you pause)\e[0m'
        pw-play ~/.config/mofakir/sounds/start.wav 2>/dev/null &
        timeout 10 rec -q -r 16000 -c 1 -b 16 -e signed-integer /tmp/mofakir/voice_reply.wav silence 1 0.1 1% 1 1.5 1%
        pw-play ~/.config/mofakir/sounds/stop.wav 2>/dev/null &
        
        echo -e '\e[1;33m⚙️ Transcribing...\e[0m'
        RAW_TRANSCRIPT=$(whisper-cli -m "$WHISPER_MODEL" -f /tmp/mofakir/voice_reply.wav -nt -l auto)
        USER_REPLY=$(echo "$RAW_TRANSCRIPT" | sed -e 's/\[.*\]//g' | xargs)
        
        echo -e "\e[1;36mYou said:\e[0m $USER_REPLY\n"
        sleep 1 
    elif [ -z "$USER_REPLY" ]; then
        break
    fi
    
    echo "$USER_REPLY" > /tmp/mofakir/prompt.txt
done
EOF
chmod +x "$TEMP_DIR/run_ai.sh"

wezterm start --class ai_mofakir -- bash -c "export TTS_ENGINE=\"$TTS_ENGINE\"; export TTS_ONLINE_EN=\"$TTS_ONLINE_EN\"; export TTS_ONLINE_AR=\"$TTS_ONLINE_AR\"; export TTS_LOCAL_EN=\"$TTS_LOCAL_EN\"; export TTS_LOCAL_AR=\"$TTS_LOCAL_AR\"; export WHISPER_MODEL=\"$WHISPER_MODEL\"; $TEMP_DIR/run_ai.sh" &
