# 🤖 Mofakir AI Desktop Assistant

Mofakir is a native, agentic AI desktop assistant built specifically for Linux environments. Instead of living inside a restricted web browser sandbox, Mofakir runs as a lightweight native PyQt6 GUI that bridges your offline (or online) LLM directly to your window manager, clipboard, active application context, and file system.

It can see your screen, read your copied text or binary clipboard assets, organize your Obsidian vaults, run local bash commands with interactive UI safety prompts, and hold spoken conversations with automatic multilingual speech-to-text and text-to-speech.

---

## Video Demonstration

Deploying Mofakir on your workspace unlocks completely hands-free desktop control. Watch the agentic assistant manage system utilities, analyze code, and interact with desktop workspaces in real time:

<p align="center">
  <video src="assets/mofakir_demo.mp4" width="100%" controls>
    Your browser does not support the video tag. You can view the demonstration video directly in the <code>assets/</code> folder.
  </video>
</p>

---

## Verified Test Environments & Hardware

The system has been fully verified and tested on the following setup:

### Hardware Specifications
* **Operating Systems:** NixOS, Arch Linux (`arch-box`) 
* **Desktop Environment:** Hyprland Window Manager (Wayland)
* **Memory:** 32 GB RAM (Shared memory)
* **Audio Server:** PipeWire (via `wireplumber` & `pw-play`)
* **Local LLM:** Gemma-4-e2b hosted on a local llama-cpp server
* CPU: AMD Ryzen 7 8845HS (16) @ 5.14 GHz
* GPU: Integrated Laptop GPU

---

## Installation & Setup

### NixOS (Nix Flakes)

If you use NixOS with Flakes enabled, Mofakir is entirely packaged with all system and audio dependencies.

#### Run Directly
```bash
nix run github:bonnjalal/Mofakir
```

#### Home Manager Integration
Add the Home Manager module to your configuration to declare your settings, context, and selected offline voice models:

Add The flake to your configuration:
```nix
mofakir.url = "github:bonnjalal/Mofakir";
```
```nix
{ inputs, pkgs, ... }: {
  imports = [ inputs.mofakir.homeManagerModules.default ];

  programs.mofakir = {
    enable = true;
    context = ''
    Information about you or your machine
    '';
    settings = {
      llm = {
        model = "Gemma-4-e2b";
        base_url = "[http://127.0.0.1:8080/v1](http://127.0.0.1:8080/v1)";
        api_key = "sk-none";
      };
      voice = {
        tts_engine = "local"; 
        tts_offline_voices = [ "en" "ar" ]; 
      };
    };
  };
}
```
You can find the full options in the config bellow.
---

### Standard Linux (Arch, Debian, Ubuntu) (`only tested on Arch for now`)


```bash
git clone [https://github.com/bonnjalal/Mofakir.git](https://github.com/bonnjalal/Mofakir.git)
cd mofakir
chmod +x install.sh
./install.sh
```

---

## Hyprland Window Rules & Shortcuts

If you are using hyprland, To integrate Mofakir seamlessly into your workspace, copy the following rules and hotkeys into your `~/.config/hypr/mofakir.conf` (and load it in your main config with `source = ~/.config/hypr/mofakir.conf`):

```ini
# ==========================================
# MOFAKIR WINDOW RULES
# ==========================================
windowrulev2 = float, title:^(Mofakir AI)$
windowrulev2 = size 40% 50%, title:^(Mofakir AI)$
windowrulev2 = center, title:^(Mofakir AI)$
windowrulev2 = opacity 0.85 0.70, title:^(Mofakir AI)$
windowrulev2 = animation slide, title:^(Mofakir AI)$

# ==========================================
# MOFAKIR KEYBINDS
# ==========================================

# 1. AUTO MODE (VAD: Automatically stops recording when you pause talking)
bind = SUPER, A, exec, mofakir --voice
bind = SUPER ALT, A, exec, mofakir --clipboard --voice
bind = SUPER CTRL, A, exec, mofakir --screen --voice

# 2. MANUAL TOGGLE MODE (Push-to-Talk: Perfect for loud environments. Press to start, press to stop)
bind = SUPER SHIFT, A, exec, mofakir --voice --toggle
bind = SUPER SHIFT ALT, A, exec, mofakir --clipboard --toggle
bind = SUPER SHIFT CTRL, A, exec, mofakir --screen --toggle
```

---

## Comprehensive Configuration Guide (`config.json`)

Mofakir generates its configuration file at `~/.config/mofakir/config.json`. Below is a detailed technical breakdown of every sub-object parameter and how to tweak it to match your workflow.

### 1. The `"llm"` Block

This block configures Mofakir's core intelligence engine. It utilizes an OpenAI-compatible API scheme, meaning it can connect to local backends (`llama.cpp`, `Ollama`, `vLLM`) or external clouds (`Groq`, `OpenRouter`, `OpenAI`).

```json
"llm": {
    "provider_name": "local",
    "api_key": "sk-none",
    "base_url": "[http://127.0.0.1:8080/v1](http://127.0.0.1:8080/v1)",
    "model": "Hermes-3-8B",
    "vision_enabled": true,
    "history_duration_minutes": 15,
    "system_context": "~/.config/mofakir/system_context.md"
}
```

* **`provider_name`** *(String)*: An informational label for your setup (e.g., `"local"`, `"groq"`, `"openrouter"`). It helps track your backend targets.
* **`api_key`** *(String)*: The authentication token for your provider. Set this to `"sk-none"` if you are running a local offline server that doesn't require keys.
* **`base_url`** *(String)*: The target network endpoint of your inference server. Ensure it points to the base directory of the completions route (usually ends with `/v1`).
* **`model`** *(String)*: The precise model identifier string passed in the payload API request.
* **`vision_enabled`** *(Boolean)*: `true` or `false`. When enabled, Mofakir allows binary base64 vision payloads via the screen/clipboard mechanics. If using a model that lacks vision layers, set this to `false` to prevent API errors.
* **`history_duration_minutes`** *(Integer/Float)*: Controls memory management. Mofakir automatically drops historical message logs from the sliding context window if the file modification timestamp exceeds this duration. This prevents old chat topics from muddying your fresh commands.
* **`system_context`** *(String)*: Absolute path pointing to a persistent system context profile markdown file.

---

### 2. The `"obsidian"` Block

Enables agentic integration with your local personal knowledge graph.

```json
"obsidian": {
    "api_key": "PASTE_YOUR_API_KEY_HERE",
    "url": "[https://127.0.0.1:27124](https://127.0.0.1:27124)"
}
```

* **`api_key`** *(String)*: The authentication token generated inside your Obsidian application under *Settings -> Local REST API -> Auth Tokens* (You will need to install the addon first).
* **`url`** *(String)*: The HTTPS server link exposed locally by the Obsidian API plugin. Note that it usually listens on secure port `27124`. Mofakir explicitly ignores invalid certificate verification warnings internally to allow self-signed local REST handshakes.

---

### 3. The `"voice"` Block

Controls the speech-to-text (STT) and text-to-speech (TTS) pipelines.

```json
"voice": {
    "tts_engine": "online",
    "whisper_model": "~/.local/share/mofakir/models/ggml-small.bin",
    "tts_local_models": {
        "en": "~/.local/share/mofakir/models/en_US-lessac-medium.onnx",
        "ar": "~/.local/share/mofakir/models/ar_JO-kareem-medium.onnx"
    },
    "tts_online_voices": {
        "en": "en-US-GuyNeural",
        "ar": "ar-EG-ShakirNeural"
    }
}
```

* **`tts_engine`** *(String)*: Options are `"online"` or `"local"`.
    * `online`: Connects to Microsoft Edge's highly realistic, low-latency cloud neural speech synthesis stream. Requires an active network connection.
    * `local`: Switches to 100% private, zero-network processing using the compiled **Piper ONNX** engine.
* **`whisper_model`** *(String)*: Absolute path to your local compiled Whisper GGML model binary file. Mofakir defaults to a high-precision `Q8_0` quantization format for instant, local CPU transcription.
* **`tts_local_models`** *(Object)*: Key-value map pairing ISO language strings to the absolute local directory path of your Piper `.onnx` speech files. Mofakir performs real-time language detection on text generation and dynamically swaps this mapping to speak native languages flawlessly.
* **`tts_online_voices`** *(Object)*: Key-value map tracking language codes to specific Microsoft Edge cloud neural voice structures.

#### How to Get Online TTS Names (`edge-tts`)
If you are using `"tts_engine": "online"`, you can choose from hundreds of high-quality neural voices provided by Microsoft Edge.
1. Open your terminal and run: `edge-tts --list-voices`
2. Filter by your desired language. For example, to find French voices: `edge-tts --list-voices | grep -i fr`
3. Copy the exact voice "Name" (e.g., `fr-FR-HenriNeural`) and map it to the appropriate language code in your `tts_online_voices` configuration object.

#### How to Get Offline TTS Models (`piper`)
If you are using `"tts_engine": "local"`, you need to download ONNX-based voice models to your machine.
You can use your own voice models, or use these piper voices repo:
1. Browse the [Hugging Face Piper Voices Repository](https://huggingface.co/rhasspy/piper-voices/tree/v1.0.0).
2. Navigate to your target language folder (e.g., `fr` -> `fr_FR` -> `upmc` -> `medium`).
3. Download both the `.onnx` file and the `.onnx.json` file. 
4. Place both files into your local models directory: `~/.local/share/mofakir/models/`
5. Copy the absolute path to the `.onnx` file and map it to your language code in the `tts_local_models` configuration object.

---

### Common Configuration Profiles

#### Profile A: 100% Offline Local Model (`llama.cpp` or `Ollama`)
Use this profile if you want total privacy with local hardware acceleration. Ensure your local model supports function-calling (like *Hermes-3-8B* or *Qwen-2.5-7B*).

```json
{
  "llm": {
    "provider_name": "local",
    "api_key": "sk-none",
    "base_url": "[http://127.0.0.1:8080/v1](http://127.0.0.1:8080/v1)",
    "model": "Hermes-3-8B",
    "vision_enabled": true,
    "history_duration_minutes": 15,
    "system_context": "~/.config/mofakir/system_context.md"
  },
  "voice": {
    "tts_engine": "local"
  }
}
```

#### Profile B: High-Speed Hybrid Cloud 
Excellent for slow hardware or laptop configurations. Blazing fast text generation via cloud servers (Groq as example) combined with low-resource local Whisper audio compilation.

```json
{
  "llm": {
    "provider_name": "groq",
    "api_key": "gsk_yA7b8...",
    "base_url": "[https://api.groq.com/openai/v1](https://api.groq.com/openai/v1)",
    "model": "qwen-2.5-32b",
    "vision_enabled": false,
    "history_duration_minutes": 10,
    "system_context": "~/.config/mofakir/system_context.md"
  },
  "voice": {
    "tts_engine": "online"
  }
}
```

---

## Agentic Architecture & System Safety

Unlike basic chat interfaces, Mofakir parses your prompt and dynamically decides whether it needs to invoke a native tool.

### Built-in Desktop Tools
1. `get_weather(location)`: Fetches real-time terminal-friendly formatting from `wttr.in`.
2. `web_search(query)`: Executes DuckDuckGo scraping to parse fresh documentation and feed live results to the LLM context.
3. `obsidian_search` / `obsidian_read` / `obsidian_write`: Manages notes using the encrypted Obsidian Local REST API.
4. `manage_desktop(action, target)`: Switches workspaces or dispatches active window addresses cleanly on Hyprland.
5. `execute_command(command)`: Run local bash pipelines.

### Execution Safety Guardrails & Threading Isolation
Mofakir classifies all system bash commands before executing them:

* **Auto-Approval Safe List:** Commands starting with safe utilities (`ls`, `cat`, `echo`, `uptime`, `free`, `df`, `playerctl`, `wpctl`, `uname`, `fastfetch`) run instantly in the background without user interruption.
* **Interactive Approval UI:** If the model tries to run an unverified command (e.g., `mkdir`, `nix-rebuild`, or installing a package), Mofakir suspends the thread execution loop, pops up an interactive **"⚠️ Action Required"** window directly inside the PyQt6 UI chat interface, and waits for a hard click on **Approve** or **Deny** before processing.
---
