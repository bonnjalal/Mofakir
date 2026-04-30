# Mofakir AI Desktop Assistant

Mofakir is an AI desktop assistant built specifically for Linux environments. Instead of living in a web browser, it runs as a lightweight native GUI that connects directly to your window manager, clipboard, and file system. 

It can see your screen, read your copied text, organize your Obsidian notes, run local bash commands, and hold spoken conversations using either local or cloud-based AI models.

## Installation

### Option 1: NixOS (Flakes)

If you use NixOS with Flakes enabled, you can run Mofakir directly without permanently installing any dependencies to your system.

    # Run directly from the repository
    nix run github:bonnjalal/Mofakir

    # Or add it to your flake.nix inputs:
    # inputs.mofakir.url = "github:YourUsername/mofakir";

### Option 2: Standard Linux (Arch, Debian, Ubuntu)

For non-Nix users, there is a standard installation script. This script automatically handles system dependencies (like sox, jq, and wl-clipboard), sets up an isolated Python virtual environment so it doesn't conflict with your system packages, compiles the necessary audio binaries, and downloads the default local voice models.

    git clone https://github.com/bonnjalal/Mofakir.git
    cd mofakir
    chmod +x install.sh
    ./install.sh

## Configuration and AI Models

You don't need a high-end GPU or massive local models to run Mofakir. Upon the first run, it generates a configuration file at ~/.config/mofakir/config.json. You can easily point the assistant to your preferred AI provider.

Here is an example of the default configuration structure:

    {
        "llm": {
            "provider_name": "local",
            "api_key": "sk-none",
            "base_url": "http://127.0.0.1:8080/v1",
            "model": "Gemma-e2b",
            "vision_enabled": true
        },
        "obsidian": {
            "api_key": "PASTE_YOUR_API_KEY_HERE",
            "url": "https://127.0.0.1:27124"
        },
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
    }

### Supported AI Providers

1. Local Models (Recommended): If you have the hardware, you can run llama.cpp or Ollama locally. Load a model that is good at using tools (like Hermes-3-8B or Qwen-2.5-7B), and point the base_url to your local server (usually http://127.0.0.1:8080/v1).

2. Cloud APIs: You can also use Groq, OpenRouter, OpenAI, or Gemini. Just swap the api_key, base_url, and model fields. If you use an API that doesn't support reading images, remember to set "vision_enabled": false to avoid errors.

## Voice and Text-to-Speech (TTS) Configuration

Mofakir includes automatic language detection. If you speak or type to it in French, it will detect the language and reply in French using the appropriate TTS voice mapped in your configuration file.

You can add support for more languages by expanding the tts_local_models and tts_online_voices dictionaries using standard language codes (e.g., "fr", "es", "ja").

### Using Online Voices (Edge-TTS)

By default, Mofakir uses Microsoft Edge's neural TTS engine for realistic voices.

1. Open your terminal and run "edge-tts --list-voices" to see all available voices.
2. Filter by your desired language (e.g., "edge-tts --list-voices | grep -i fr").
3. Copy the voice name you prefer (e.g., fr-FR-HenriNeural) and add it to the tts_online_voices section of your config.json.

### Using Offline Voices (Piper)

For completely private, offline TTS, Mofakir uses Piper.

1. Browse the Hugging Face Piper Voices Repository.
2. Download the .onnx and .onnx.json files for your preferred language and voice.
3. Place both files into your models folder (~/.local/share/mofakir/models/).
4. Add the absolute path of the .onnx file to the tts_local_models section of your config.json.

## Usage and Capabilities

### Keyboard Shortcuts

To get the most out of Mofakir, bind the script to your desktop environment's shortcut manager (for example, in your hyprland.conf):

* mofakir --voice : Opens the assistant for a standard query.
* mofakir --clipboard : Grabs whatever text, image, or file path you currently have copied and uses it as context for your next question.
* mofakir --screen : Silently takes a screenshot of your active monitors and sends it to the AI for visual analysis.

### Interactive Chat

When triggered, Mofakir opens a minimal, dark-themed GUI. 

* Typing: You can continue the conversation normally by typing in the input box and pressing Enter.
* Voice Replies: If you prefer to talk, type the letter v and press Enter. The assistant will start listening to your microphone, transcribe your speech, and reply automatically.

### System Integration Examples

Because Mofakir runs locally, it can interact with your system in ways web chatbots can't:

* Managing Files: Copy a PDF or an image in your file manager, trigger Mofakir, and tell it: "Upload this file to my Obsidian vault under the name receipt.pdf."
* Window Management: Mofakir knows which window you are actively working in. You can say: "Move this window to workspace 5."
* Note Taking: Using the Local REST API plugin for Obsidian, Mofakir can read your existing notes, search for specific topics, or append new thoughts directly into your vault.
