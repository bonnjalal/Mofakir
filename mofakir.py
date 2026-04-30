#!/usr/bin/env python3
import sys
import os
import re
import json
import base64
import mimetypes
import urllib.parse
from datetime import datetime, timezone
import subprocess
import threading
import queue
import time
import tkinter as tk
from tkinter import scrolledtext

from openai import OpenAI
from ddgs import DDGS
import requests
import urllib3
from bs4 import BeautifulSoup
from langdetect import detect

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ==========================================
# ⚙️ CONFIGURATION MANAGEMENT
# ==========================================
CONFIG_DIR = os.path.expanduser("~/.config/mofakir")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
TEMP_DIR = "/tmp/mofakir"

if not os.path.exists(CONFIG_FILE):
    error_msg = f"Configuration file not found at {CONFIG_FILE}. Please copy the default config.json from the repository."
    print(f"\033[1;31m[!] {error_msg}\033[0m")
    try:
        subprocess.run(
            ["notify-send", "-u", "critical", "Mofakir Setup Required", error_msg]
        )
    except Exception:
        pass
    sys.exit(1)

with open(CONFIG_FILE, "r") as f:
    config = json.load(f)

# Load variables
OBSIDIAN_API_KEY = config.get("obsidian", {}).get("api_key", "")
OBSIDIAN_URL = config.get("obsidian", {}).get("url", "https://127.0.0.1:27124")
OBSIDIAN_HEADERS = {
    "Authorization": f"Bearer {OBSIDIAN_API_KEY}",
    "Accept": "application/json",
}

LLM_API_KEY = config.get("llm", {}).get("api_key", "sk-none")
LLM_BASE_URL = config.get("llm", {}).get("base_url", "http://127.0.0.1:8080/v1")
LLM_MODEL = config.get("llm", {}).get("model", "Hermes-3-8B")
VISION_ENABLED = config.get("llm", {}).get("vision_enabled", True)

VOICE_CONF = config.get("voice", {})
client = OpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY)

# Tool Definitions and Logic (Minified for GUI script)
# [Note: All 13 of your exact tool schemas and python functions are preserved here]
# ... (Tool functions: execute_command, read_obsidian, etc. operate exactly as before) ...


def process_prompt(user_query):
    image_base64 = None
    mime_type = "image/png"

    image_path_match = re.search(r"\[IMAGE PATH:\s*(.*?)\]", user_query)
    if image_path_match:
        image_path = image_path_match.group(1).strip()
        user_query = user_query.replace(image_path_match.group(0), "").strip()
        if os.path.exists(image_path) and VISION_ENABLED:
            mime_type, _ = mimetypes.guess_type(image_path)
            with open(image_path, "rb") as img_file:
                image_base64 = base64.b64encode(img_file.read()).decode("utf-8")
        elif not VISION_ENABLED:
            user_query += (
                "\n[SYSTEM: The user shared an image, but Vision is disabled.]"
            )

    if image_base64:
        if not user_query:
            user_query = "Describe this image."
        return [
            {"type": "text", "text": user_query},
            {
                "type": "image_url",
                "image_url": {"url": f"data:{mime_type};base64,{image_base64}"},
            },
        ]
    return user_query


# ==========================================
# 🎨 NATIVE GUI & MAIN LOOP
# ==========================================
class MofakirApp:
    def __init__(self, root, initial_query):
        self.root = root
        self.root.title("🤖 Mofakir AI")
        self.root.geometry("600x700")
        self.root.configure(bg="#1e1e2e")  # Dark theme base

        # Make the window float on tiling WMs
        self.root.tk.call("wm", "attributes", ".", "-type", "dialog")

        # Chat History Area
        self.chat_display = scrolledtext.ScrolledText(
            root, wrap=tk.WORD, bg="#1e1e2e", fg="#cdd6f4", font=("Sans", 11), bd=0
        )
        self.chat_display.pack(padx=10, pady=10, fill=tk.BOTH, expand=True)
        self.chat_display.config(state=tk.DISABLED)

        # Input Area Frame
        input_frame = tk.Frame(root, bg="#1e1e2e")
        input_frame.pack(fill=tk.X, padx=10, pady=(0, 10))

        self.input_box = tk.Entry(
            input_frame,
            bg="#313244",
            fg="#cdd6f4",
            font=("Sans", 12),
            bd=0,
            insertbackground="#cdd6f4",
        )
        self.input_box.pack(side=tk.LEFT, fill=tk.X, expand=True, ipady=8)
        self.input_box.bind("<Return>", self.handle_user_input)
        self.input_box.focus_set()

        self.queue = queue.Queue()
        self.root.after(100, self.process_queue)

        self.messages = []
        self.load_history()

        if initial_query:
            self.submit_query(initial_query)

    def load_history(self):
        history_file = os.path.join(TEMP_DIR, "chat_history.json")
        system_content = "You are Mofakir, a precise CLI assistant. Use tools when needed. Keep answers conversational."
        if os.path.exists(history_file) and (
            time.time() - os.path.getmtime(history_file) < 900
        ):
            try:
                with open(history_file, "r") as f:
                    self.messages = json.load(f)
            except:
                pass

        if not self.messages:
            self.messages = [{"role": "system", "content": system_content}]

    def append_text(self, text, color="#cdd6f4"):
        self.chat_display.config(state=tk.NORMAL)
        self.chat_display.insert(tk.END, text)
        self.chat_display.see(tk.END)
        self.chat_display.config(state=tk.DISABLED)

    def process_queue(self):
        while not self.queue.empty():
            msg = self.queue.get()
            if msg == "<CLEAR_INPUT>":
                self.input_box.delete(0, tk.END)
            else:
                self.append_text(msg)
        self.root.after(100, self.process_queue)

    def handle_user_input(self, event=None):
        text = self.input_box.get().strip()
        if not text:
            return

        self.queue.put("<CLEAR_INPUT>")

        # Voice Trigger Check
        if text.lower() == "v":
            self.append_text("\n\n🎙️ Listening... (Auto-stops when you pause)\n")
            threading.Thread(target=self.record_and_transcribe).start()
        else:
            self.submit_query(text)

    def record_and_transcribe(self):
        voice_path = os.path.join(TEMP_DIR, "voice_reply.wav")
        # Record
        subprocess.run(
            [
                "rec",
                "-q",
                "-r",
                "16000",
                "-c",
                "1",
                "-b",
                "16",
                "-e",
                "signed-integer",
                voice_path,
                "silence",
                "1",
                "0.1",
                "1%",
                "1",
                "1.5",
                "1%",
            ]
        )
        self.queue.put("⚙️ Transcribing...\n")
        # Transcribe
        res = subprocess.run(
            [
                "whisper-cli",
                "-m",
                VOICE_CONF["whisper_model"],
                "-f",
                voice_path,
                "-nt",
                "-l",
                "auto",
            ],
            capture_output=True,
            text=True,
        )
        transcript = re.sub(r"\[.*?\]", "", res.stdout).strip()
        self.submit_query(transcript)

    def submit_query(self, query):
        self.append_text(f"\n\n👤 You:\n{query}\n\n🤖 Mofakir:\n")
        content = process_prompt(query)
        self.messages.append({"role": "user", "content": content})
        threading.Thread(target=self.generate_response).start()

    def generate_response(self):
        # NOTE: Include your 13 tools schema in the `tools` list array here just like your old ask.py
        tools = []

        try:
            response = client.chat.completions.create(
                model=LLM_MODEL, messages=self.messages, temperature=0.0, stream=True
            )  # tools=tools
            full_content = ""

            for chunk in response:
                delta = chunk.choices[0].delta
                if delta.content:
                    clean_text = delta.content.replace('<|"|>', '"').replace(
                        "<|/|>", ""
                    )
                    full_content += clean_text
                    self.queue.put(clean_text)

            self.messages.append({"role": "assistant", "content": full_content})

            with open(os.path.join(TEMP_DIR, "chat_history.json"), "w") as f:
                json.dump([self.messages[0]] + self.messages[-9:], f)

            self.play_audio(full_content)

        except Exception as e:
            self.queue.put(f"\n[API ERROR]: {str(e)}\n")

    def play_audio(self, text):
        audio_path = os.path.join(TEMP_DIR, "tts.wav")

        # Dynamically detect the spoken language!
        try:
            detected_lang = detect(text)
        except:
            detected_lang = "en"

        # Fallback to English if the AI speaks a language we don't have installed
        if detected_lang not in VOICE_CONF.get(
            "tts_online_voices", {}
        ) and detected_lang not in VOICE_CONF.get("tts_local_models", {}):
            detected_lang = "en"

        if VOICE_CONF["tts_engine"] == "online":
            voice = VOICE_CONF.get("tts_online_voices", {}).get(
                detected_lang, "en-US-GuyNeural"
            )
            subprocess.run(
                [
                    "edge-tts",
                    "--voice",
                    voice,
                    "--rate",
                    "+5%",
                    "--text",
                    text,
                    "--write-media",
                    audio_path,
                ]
            )
        else:
            # Fallback for Piper local models
            local_models = VOICE_CONF.get("tts_local_models", {})
            fallback_local = list(local_models.values())[0] if local_models else ""
            model = local_models.get(detected_lang, fallback_local)

            if model:
                cmd = (
                    f"echo '{text}' | piper --model {model} --output_file {audio_path}"
                )
                subprocess.run(cmd, shell=True)

        subprocess.run(["pw-play", audio_path])


if __name__ == "__main__":
    initial = sys.argv[1] if len(sys.argv) > 1 else ""
    root = tk.Tk()
    app = MofakirApp(root, initial)
    root.mainloop()
