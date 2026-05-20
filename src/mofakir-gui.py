#!/usr/bin/env python3
import sys
import os
import re
import json
import base64
import urllib.parse
import subprocess
import threading
import time

from PyQt6.QtWidgets import QApplication
from PyQt6.QtQml import QQmlApplicationEngine
from PyQt6.QtCore import Qt, QTimer, pyqtSignal, pyqtSlot, QThread, QObject, QUrl

import openai
from openai import OpenAI
from ddgs import DDGS
import requests
import urllib3
from bs4 import BeautifulSoup
from langdetect import detect

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ==========================================
# ⚙️ CONFIGURATION & PATH RESOLUTION
# ==========================================
CONFIG_DIR = os.path.expanduser("~/.config/mofakir")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
TEMP_DIR = "/tmp/mofakir"
SOUND_DIR = os.path.expanduser("~/.local/share/mofakir/sounds")
HISTORY_DIR = os.path.expanduser("~/.local/state/mofakir")
HISTORY_FILE = os.path.join(HISTORY_DIR, "chat_history.json")

os.makedirs(CONFIG_DIR, exist_ok=True)
os.makedirs(SOUND_DIR, exist_ok=True)
os.makedirs(HISTORY_DIR, exist_ok=True)

# Smart UI Path Resolver
_base_dir = os.path.dirname(os.path.abspath(__file__))
qml_paths_to_check = [
    os.path.join(CONFIG_DIR, "ui.qml"),
    os.path.join(_base_dir, "ui.qml"),
    os.path.abspath(os.path.join(_base_dir, "..", "share", "mofakir", "ui.qml")),
    os.path.expanduser("~/.local/share/mofakir/ui.qml"),
]

QML_FILE = None
for path in qml_paths_to_check:
    if os.path.exists(path):
        QML_FILE = path
        break

if not QML_FILE:
    print(
        "\033[1;31m[!] Error: ui.qml not found. Please ensure the frontend file is downloaded.\033[0m"
    )
    sys.exit(1)

if not os.path.exists(CONFIG_FILE):
    print(f"\033[1;31m[!] Configuration file not found at {CONFIG_FILE}.\033[0m")
    sys.exit(1)

with open(CONFIG_FILE, "r") as f:
    config = json.load(f)

LLM_HISTORY_DURATION_MINS = config.get("llm", {}).get("history_duration_minutes", 15)
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

CONTEXT_PATH = os.path.expanduser(
    config.get("llm", {}).get("system_context", "~/.config/mofakir/context.md")
)
USER_CONTEXT = ""
if os.path.exists(CONTEXT_PATH):
    with open(CONTEXT_PATH, "r", encoding="utf-8") as f:
        USER_CONTEXT = f.read().strip()
else:
    try:
        os.makedirs(os.path.dirname(CONTEXT_PATH), exist_ok=True)
        with open(CONTEXT_PATH, "w", encoding="utf-8") as f:
            f.write(
                "<!-- Write your custom context here. Mofakir will read this to personalize its answers. -->\n"
            )
    except:
        pass

## TOOLS & LOGIC
tools = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get current weather conditions for a specific location.",
            "parameters": {
                "type": "object",
                "properties": {"location": {"type": "string"}},
                "required": ["location"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the web for live facts.",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string"}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "obsidian_search",
            "description": "Search Obsidian notes.",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string"}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "obsidian_read",
            "description": "Read an Obsidian note.",
            "parameters": {
                "type": "object",
                "properties": {"filename": {"type": "string"}},
                "required": ["filename"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "obsidian_write",
            "description": "Write/Overwrite an Obsidian note.",
            "parameters": {
                "type": "object",
                "properties": {
                    "filename": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["filename", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "execute_command",
            "description": "Execute a bash shell command.",
            "parameters": {
                "type": "object",
                "properties": {"command": {"type": "string"}},
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "manage_desktop",
            "description": "Manage workspaces depending on desktop environment.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["focus_workspace", "move_to_workspace"],
                    },
                    "target": {"type": "string"},
                    "window_address": {
                        "type": "string",
                        "description": "Optional window address",
                    },
                },
                "required": ["action", "target"],
            },
        },
    },
]


def get_weather(location):
    try:
        url = f"https://wttr.in/{urllib.parse.quote(location)}?format=%C+%t,+Feels+like+%f,+Wind:+%w,+Humidity:+%h"
        res = requests.get(url, timeout=5)
        return (
            f"Weather in {location}: {res.text.strip()}"
            if res.status_code == 200
            else f"Failed. Status: {res.status_code}"
        )
    except Exception as e:
        return f"Error: {e}"


def search_obsidian(query):
    try:
        url = f"{OBSIDIAN_URL.rstrip('/')}/search/"
        headers = OBSIDIAN_HEADERS.copy()
        headers["Content-Type"] = "application/json"

        # Attempt 1: Standard JSON body
        res = requests.post(
            url, headers=headers, json={"query": query}, verify=False, timeout=5
        )

        # Attempt 2: If 400/404, fallback to the plugin's custom Content-Type and raw text body
        if res.status_code >= 400:
            alt_headers = OBSIDIAN_HEADERS.copy()
            alt_headers["Content-Type"] = "application/vnd.olrapi.search+json"
            res = requests.post(
                url,
                headers=alt_headers,
                data=query.encode("utf-8"),
                verify=False,
                timeout=5,
            )

        if res.status_code == 200:
            data = res.json()
            if not data:
                return "No results found for that query."
            if isinstance(data, list) and len(data) > 0 and isinstance(data[0], dict):
                return "\n\n".join(
                    [
                        f"File: {i.get('filename')}\nSnippets: {[m.get('context', '').strip() for m in i.get('matches', [])]}"
                        for i in data[:3]
                    ]
                )
            elif isinstance(data, list):
                return "Files found:\n" + "\n".join([str(i) for i in data[:10]])
            return f"Raw results: {str(data)[:2000]}"
        else:
            return f"Error: {res.status_code} - {res.text}"
    except Exception as e:
        return f"Error: {e}"


def read_obsidian(filename):
    try:
        return requests.get(
            f"{OBSIDIAN_URL.rstrip('/')}/vault/{urllib.parse.quote(filename)}",
            headers=OBSIDIAN_HEADERS,
            verify=False,
            timeout=3,
        ).text[:3000]
    except Exception as e:
        return f"Error: {e}"


def write_obsidian(filename, content):
    try:
        headers = OBSIDIAN_HEADERS.copy()
        headers["Content-Type"] = "text/markdown"
        res = requests.put(
            f"{OBSIDIAN_URL.rstrip('/')}/vault/{urllib.parse.quote(filename)}",
            headers=headers,
            data=content.encode("utf-8"),
            verify=False,
            timeout=3,
        )
        return (
            f"Success. Note saved. Exact content written:\n{content}"
            if res.status_code in [200, 201, 204]
            else f"Error: {res.status_code}"
        )
    except Exception as e:
        return f"Error: {e}"


def execute_command(command):
    try:
        res = subprocess.run(
            command, shell=True, capture_output=True, text=True, timeout=10
        )
        return (res.stdout + res.stderr)[:3000] or "Success with no output."
    except Exception as e:
        return f"Error: {e}"


def deep_web_search(query):
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=3, backend="lite"))
        out = ""
        for r in results:
            try:
                soup = BeautifulSoup(
                    requests.get(r["href"], timeout=4).text, "html.parser"
                )
                for s in soup(["script", "style", "nav", "footer"]):
                    s.extract()
                out += f"--- {r['title']} ---\n{soup.get_text(separator=' ', strip=True)[:1500]}\n"
            except:
                out += f"--- {r['title']} ---\n{r['body']}\n"
        return out[:5000]
    except Exception as e:
        return f"Error: {e}"


def manage_desktop(action, target, window_address=""):
    try:
        if "hyprland" in os.environ.get("XDG_CURRENT_DESKTOP", "").lower():
            if action == "focus_workspace":
                cmd = ["hyprctl", "dispatch", "workspace", str(target)]
            else:
                cmd = (
                    [
                        "hyprctl",
                        "dispatch",
                        "movetoworkspace",
                        f"{target},address:{window_address}",
                    ]
                    if window_address
                    else ["hyprctl", "dispatch", "movetoworkspace", str(target)]
                )
            subprocess.run(cmd, check=True)
            return "Success on Hyprland."
        return "Blocked: Only Hyprland supported."
    except Exception as e:
        return f"Error: {e}"


def process_prompt(user_query):
    image_base64, mime_type = None, "image/png"
    match = re.search(r"\[IMAGE PATH:\s*(.*?)\]", user_query)
    if match:
        path = match.group(1).strip()
        user_query = user_query.replace(match.group(0), "").strip()
        if os.path.exists(path) and VISION_ENABLED:
            with open(path, "rb") as f:
                image_base64 = base64.b64encode(f.read()).decode("utf-8")
        elif not VISION_ENABLED:
            user_query += "\n[SYSTEM: Image shared but Vision disabled.]"

    if image_base64:
        clean_query = user_query.replace("Regarding this screenshot:", "").strip()
        if not clean_query:
            final_text = "Please describe the attached image in detail."
        else:
            final_text = f"Regarding this attached image: {clean_query}"

        return [
            {"type": "text", "text": final_text},
            {
                "type": "image_url",
                "image_url": {"url": f"data:{mime_type};base64,{image_base64}"},
            },
        ]
    return user_query


## QTHREADS
class TTSWorkerThread(QThread):
    status_signal = pyqtSignal(str, str)
    finished_signal = pyqtSignal()

    def __init__(self, text):
        super().__init__()
        self.text = text
        self._is_stopped = False
        self.current_process = None

    def run(self):
        audio_path = os.path.join(TEMP_DIR, "tts.wav")
        try:
            detected_lang = detect(self.text)
        except:
            detected_lang = "en"

        if self._is_stopped:
            return

        if VOICE_CONF.get("tts_engine", "online") == "online":
            self.status_signal.emit("🔊 Speaking...", "#89b4fa")
            voice = VOICE_CONF.get("tts_online_voices", {}).get(
                detected_lang, "en-US-GuyNeural"
            )
            self.current_process = subprocess.Popen(
                [
                    "edge-tts",
                    "--voice",
                    voice,
                    "--rate",
                    "+5%",
                    "--text",
                    self.text,
                    "--write-media",
                    audio_path,
                ],
                stderr=subprocess.DEVNULL,
            )
            if self.current_process:
                self.current_process.wait()
        else:
            local_models = VOICE_CONF.get("tts_local_models", {})
            model = os.path.expanduser(
                local_models.get(
                    detected_lang,
                    list(local_models.values())[0] if local_models else "",
                )
            )

            if os.path.exists(model):
                self.status_signal.emit("🔊 Speaking...", "#89b4fa")
                self.current_process = subprocess.Popen(
                    ["piper", "--model", model, "--output_file", audio_path],
                    stdin=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                self.current_process.communicate(input=self.text.encode("utf-8"))
            else:
                self.status_signal.emit("⚠️ Missing Voice Model", "#f38ba8")
                print(
                    f"[!] Error: Model {model} not found. Please verify your Nix Flake or install.sh downloaded it."
                )

        if self._is_stopped:
            return

        if os.path.exists(audio_path):
            self.current_process = subprocess.Popen(
                ["pw-play", audio_path], stderr=subprocess.DEVNULL
            )
            self.current_process.wait()

        if not self._is_stopped:
            self.finished_signal.emit()

    def stop(self):
        self._is_stopped = True
        if self.current_process:
            try:
                self.current_process.terminate()
            except:
                pass


class AIGeneratorThread(QThread):
    status_signal = pyqtSignal(str, str)
    new_bubble_signal = pyqtSignal(str, str)
    append_text_signal = pyqtSignal(str)
    sys_message_signal = pyqtSignal(str, str)
    require_approval_signal = pyqtSignal(str)
    finished_signal = pyqtSignal(str)
    history_save_signal = pyqtSignal()

    SAFE_COMMANDS = [
        "ls",
        "cat",
        "echo",
        "date",
        "whoami",
        "uptime",
        "hyprctl",
        "wmctrl",
        "playerctl",
        "wpctl",
        "pactl",
        "xdotool",
        "sleep",
        "free",
        "df",
        "du",
        "top",
        "htop",
        "ps",
        "uname",
        "grep",
        "find",
        "neofetch",
        "fastfetch",
    ]

    def __init__(self, messages):
        super().__init__()
        self.messages = messages
        self.approval_event = threading.Event()
        self.approval_result = False
        self._is_stopped = False

    def stop(self):
        self._is_stopped = True
        self.approval_event.set()

    def execute_command_safe(self, command):
        base_cmd = command.strip().split()[0] if command.strip() else ""
        if base_cmd in self.SAFE_COMMANDS:
            return execute_command(command)

        self.approval_event.clear()
        self.require_approval_signal.emit(command)
        self.approval_event.wait()
        if self.approval_result and not self._is_stopped:
            return execute_command(command)
        else:
            return "Command execution denied by the user."

    def run(self):
        try:
            temp_messages = list(self.messages)

            # If an image exists, we MUST strip the 'tools' payload entirely to prevent the 8B model's attention from collapsing into hallucination.
            has_image = False
            for msg in temp_messages:
                if isinstance(msg.get("content"), list):
                    for part in msg["content"]:
                        if isinstance(part, dict) and part.get("type") == "image_url":
                            has_image = True
                            break

            api_kwargs = {
                "model": LLM_MODEL,
                "messages": temp_messages,
                "temperature": 0.0,
                "stream": True,
            }

            # Only inject the tools schema if the model is processing text-only context
            if not has_image:
                api_kwargs["tools"] = tools

            response = client.chat.completions.create(**api_kwargs)
            tool_calls, full_content = [], ""
            bubble_created = False

            buffer = ""
            last_emit = time.time()

            for chunk in response:
                if self._is_stopped:
                    break
                delta = chunk.choices[0].delta
                if delta.tool_calls:
                    for tc in delta.tool_calls:
                        idx = (
                            tc.index
                            if tc.index is not None
                            else max(0, len(tool_calls) - 1)
                        )
                        while len(tool_calls) <= idx:
                            tool_calls.append(
                                {
                                    "id": "",
                                    "type": "function",
                                    "function": {"name": "", "arguments": ""},
                                }
                            )
                        if tc.id:
                            tool_calls[idx]["id"] = tc.id
                        if tc.function:
                            if tc.function.name:
                                tool_calls[idx]["function"]["name"] = tc.function.name
                            if tc.function.arguments:
                                tool_calls[idx]["function"]["arguments"] += (
                                    tc.function.arguments
                                )

                if delta.content:
                    clean_text = (
                        delta.content.replace('<|"|>', '"')
                        .replace("<|/|>", "")
                        .replace("execute_command", "")
                    )
                    if clean_text:
                        if not bubble_created:
                            self.new_bubble_signal.emit("ai", "")
                            bubble_created = True
                            buffer = ""
                            last_emit = time.time()

                        full_content += clean_text
                        buffer += clean_text

                        if time.time() - last_emit > 0.05:
                            self.append_text_signal.emit(buffer)
                            buffer = ""
                            last_emit = time.time()

            if buffer and not self._is_stopped:
                self.append_text_signal.emit(buffer)

            if self._is_stopped:
                self.finished_signal.emit("")
                return

            if tool_calls:
                if full_content.strip():
                    temp_messages.append({"role": "assistant", "content": full_content})
                tool_results_text = ""
                for tool_call in tool_calls:
                    if self._is_stopped:
                        break

                    tool_name = tool_call["function"]["name"]
                    try:
                        args = json.loads(tool_call["function"]["arguments"])
                    except:
                        args = {}

                    self.sys_message_signal.emit("sys", f"⚙️ Running {tool_name}...")

                    if tool_name == "get_weather":
                        results = get_weather(args.get("location", ""))
                    elif tool_name == "web_search":
                        results = deep_web_search(args.get("query", ""))
                    elif tool_name == "obsidian_search":
                        results = search_obsidian(args.get("query", ""))
                    elif tool_name == "obsidian_read":
                        results = read_obsidian(args.get("filename", ""))
                    elif tool_name == "obsidian_write":
                        results = write_obsidian(
                            args.get("filename", ""), args.get("content", "")
                        )
                    elif tool_name == "manage_desktop":
                        results = manage_desktop(
                            args.get("action", ""),
                            args.get("target", ""),
                            args.get("window_address", ""),
                        )
                    elif tool_name == "execute_command":
                        results = self.execute_command_safe(args.get("command", ""))
                    else:
                        results = "Done."

                    tool_results_text += f"\n--- {tool_name} ---\n{results}\n"

                if self._is_stopped:
                    self.finished_signal.emit("")
                    return

                temp_messages.append(
                    {
                        "role": "user",
                        "content": f"[SYSTEM RESULTS]:\n{tool_results_text}\nReply directly based on these results. If quoting written content, quote it exactly without paraphrasing.",
                    }
                )
                final_content = ""
                bubble_created = False

                # Turn 2 API Call (Processing Tool Results)
                api_kwargs_t2 = {
                    "model": LLM_MODEL,
                    "messages": temp_messages,
                    "temperature": 0.0,
                    "stream": True,
                }

                stream_response = client.chat.completions.create(**api_kwargs_t2)

                buffer = ""
                last_emit = time.time()

                for chunk in stream_response:
                    if self._is_stopped:
                        break
                    if chunk.choices[0].delta.content:
                        clean_text = (
                            chunk.choices[0]
                            .delta.content.replace('<|"|>', '"')
                            .replace("<|/|>", "")
                            .replace("execute_command", "")
                        )
                        if clean_text:
                            if not bubble_created:
                                self.new_bubble_signal.emit("ai", "")
                                bubble_created = True
                                buffer = ""
                                last_emit = time.time()

                            final_content += clean_text
                            buffer += clean_text

                            if time.time() - last_emit > 0.05:
                                self.append_text_signal.emit(buffer)
                                buffer = ""
                                last_emit = time.time()

                if buffer and not self._is_stopped:
                    self.append_text_signal.emit(buffer)

                if self._is_stopped:
                    self.finished_signal.emit("")
                    return

                if final_content.strip():
                    self.messages.append(
                        {"role": "assistant", "content": final_content}
                    )
                full_content = final_content
            else:
                if full_content.strip():
                    self.messages.append({"role": "assistant", "content": full_content})

            self.history_save_signal.emit()
            self.finished_signal.emit(full_content)

        except openai.APIConnectionError:
            self.sys_message_signal.emit(
                "sys", "⚠️ Error: The Local LLM Server is offline."
            )
            self.finished_signal.emit("The local model server is offline.")
        except Exception as e:
            self.sys_message_signal.emit("sys", f"[API ERROR]: {str(e)}")
            self.finished_signal.emit("")


## BACKEND CONTROLLER (Bridged to QML)
class Backend(QObject):
    statusChanged = pyqtSignal(str, str)
    messageAdded = pyqtSignal(str, str)
    messageAppended = pyqtSignal(str)
    inputStateChanged = pyqtSignal(bool)
    stopButtonStateChanged = pyqtSignal(bool)
    requireApproval = pyqtSignal(str)
    clearApproval = pyqtSignal()

    def __init__(self, initial_query, launch_mode):
        super().__init__()
        self.is_voice_mode = launch_mode == "--voice"
        self.is_recording = False
        self.rec_process = None
        self.messages = []

        self.timer = QTimer()
        self.timer.timeout.connect(self.check_signals)
        self.timer.start(200)

        self.load_history()

    @pyqtSlot(str, str)
    def handle_message_added(self, role, text):
        self.messageAdded.emit(role, text)

    @pyqtSlot(str)
    def handle_message_appended(self, text):
        self.messageAppended.emit(text)

    def emit_initial_state(self):
        if self.is_voice_mode:
            self.statusChanged.emit("🎙️ Voice Mode Active", "#a6e3a1")
        for msg in self.messages:
            if msg["role"] != "system":
                role_str = "ai" if msg["role"] == "assistant" else "user"
                self.messageAdded.emit(role_str, msg["content"])

        if len(sys.argv) > 1 and sys.argv[1].strip():
            self.submit_query(sys.argv[1])

    def load_history(self):
        system_content = "You are Mofakir, a precise CLI assistant. You MUST use the provided JSON tool calls to execute commands. Do not output raw tool names as text. Keep answers conversational."
        if USER_CONTEXT and not USER_CONTEXT.startswith("<!--"):
            system_content += f"\n\n### USER CONTEXT:\n{USER_CONTEXT}"

        self.messages = []
        if os.path.exists(HISTORY_FILE) and (
            time.time() - os.path.getmtime(HISTORY_FILE)
            < (LLM_HISTORY_DURATION_MINS * 60)
        ):
            try:
                with open(HISTORY_FILE, "r") as f:
                    loaded_history = json.load(f)
                    for msg in loaded_history:
                        if msg.get("role") != "system":
                            self.messages.append(msg)
            except:
                pass

        self.messages.insert(0, {"role": "system", "content": system_content})

    @pyqtSlot()
    def save_history(self):
        tail = [m for m in self.messages if m.get("role") != "system"]
        history_to_save = [self.messages[0]] + tail[-8:]
        with open(HISTORY_FILE, "w") as f:
            json.dump(history_to_save, f)

    @pyqtSlot()
    def interrupt_ai(self):
        if hasattr(self, "ai_thread") and self.ai_thread is not None:
            if self.ai_thread.isRunning():
                self.ai_thread.stop()

        if hasattr(self, "tts_thread") and self.tts_thread is not None:
            if self.tts_thread.isRunning():
                self.tts_thread.stop()

        self.is_recording = False
        if self.rec_process:
            try:
                self.rec_process.terminate()
            except:
                pass

        subprocess.run(["pkill", "-x", "pw-play"], stderr=subprocess.DEVNULL)
        subprocess.run(["pkill", "-x", "piper"], stderr=subprocess.DEVNULL)
        subprocess.run(["pkill", "-x", "edge-tts"], stderr=subprocess.DEVNULL)
        subprocess.run(["pkill", "-x", "rec"], stderr=subprocess.DEVNULL)
        subprocess.run(["pkill", "-x", "whisper-cli"], stderr=subprocess.DEVNULL)

        self.statusChanged.emit("Idle", "#6c7086")
        self.inputStateChanged.emit(True)
        self.stopButtonStateChanged.emit(False)
        self.is_voice_mode = False
        self._input_enabled = True

    def check_signals(self):
        if os.path.exists(os.path.join(TEMP_DIR, "gui_signal")):
            os.remove(os.path.join(TEMP_DIR, "gui_signal"))
            if (
                self.is_recording
                or not getattr(self, "_input_enabled", True)
                or (
                    hasattr(self, "ai_thread")
                    and self.ai_thread is not None
                    and self.ai_thread.isRunning()
                )
            ):
                self.interrupt_ai()
            else:
                self.startVoiceRecording()

    @pyqtSlot(str)
    def processInput(self, text):
        self.interrupt_ai()
        self.is_voice_mode = False
        self.statusChanged.emit("Idle", "#6c7086")
        self.submit_query(text)

    @pyqtSlot()
    def stopAIOperation(self):
        self.interrupt_ai()

    @pyqtSlot(bool)
    def resolveCommandApproval(self, approved):
        self.clearApproval.emit()
        if hasattr(self, "ai_thread") and self.ai_thread:
            self.ai_thread.approval_result = approved
            self.ai_thread.approval_event.set()

    @pyqtSlot()
    def startVoiceRecording(self):
        self.interrupt_ai()
        if self.is_recording:
            return
        self.is_recording = True
        self.is_voice_mode = True
        self._input_enabled = False
        self.inputStateChanged.emit(False)
        self.stopButtonStateChanged.emit(True)
        self.statusChanged.emit("🎙️ Listening... (Say 'Stop' to end)", "#a6e3a1")
        subprocess.run(
            ["pw-play", os.path.join(SOUND_DIR, "start.wav")], stderr=subprocess.DEVNULL
        )
        threading.Thread(target=self.record_with_silence).start()

    def stop_recording(self):
        if self.is_recording and self.rec_process:
            self.is_recording = False
            self.rec_process.terminate()

    def record_with_silence(self):
        self.rec_process = subprocess.Popen(
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
                os.path.join(TEMP_DIR, "voice_reply.wav"),
                "silence",
                "1",
                "0.1",
                "1%",
                "1",
                "1.5",
                "1%",
            ]
        )
        self.rec_process.wait()
        if self.is_recording:
            self.is_recording = False
            subprocess.run(
                ["pw-play", os.path.join(SOUND_DIR, "stop.wav")],
                stderr=subprocess.DEVNULL,
            )
            self.transcribe_audio()

    def transcribe_audio(self):
        self.statusChanged.emit("⚙️ Transcribing...", "#f9e2af")
        whisper_model = os.path.expanduser(
            VOICE_CONF.get("whisper_model")
            or "~/.local/share/mofakir/models/ggml-small.bin"
        )
        res = subprocess.run(
            [
                "whisper-cli",
                "-m",
                whisper_model,
                "-f",
                os.path.join(TEMP_DIR, "voice_reply.wav"),
                "-nt",
                "-l",
                "auto",
            ],
            capture_output=True,
            text=True,
        )
        transcript = re.sub(r"\[.*?\]", "", res.stdout).strip()

        if transcript:
            clean_no_spaces = re.sub(r"[^\w]", "", transcript.lower())
            hallucinations = [
                "ご視聴ありがとうございました",
                "はい承知しました",
                "thankyou",
                "thanksforwatching",
                "soustitres",
                "subtitles",
                "amaraorg",
                "thankyouverymuch",
                "merci",
            ]
            if (
                any(h in clean_no_spaces for h in hallucinations)
                and len(transcript.split()) <= 5
            ):
                transcript = ""

        if transcript:
            clean_trans = re.sub(r"[^\w\s]", "", transcript.lower().strip())
            stop_phrases = [
                "stop",
                "exit",
                "quit",
                "thank you",
                "thanks",
                "ok stop",
                "goodbye",
                "bye",
            ]
            if (
                any(p in clean_trans for p in stop_phrases)
                and len(clean_trans.split()) <= 4
            ):
                self.statusChanged.emit("Idle", "#6c7086")
                self.messageAdded.emit("sys", "🛑 Conversation Ended.")
                self.is_voice_mode = False
                self._input_enabled = True
                self.inputStateChanged.emit(True)
                self.stopButtonStateChanged.emit(False)
                return
            self.submit_query(transcript)
        else:
            self.statusChanged.emit("Idle", "#6c7086")
            self.messageAdded.emit("sys", "No speech detected.")
            self.is_voice_mode = False
            self._input_enabled = True
            self.inputStateChanged.emit(True)
            self.stopButtonStateChanged.emit(False)

    def submit_query(self, query):
        self._input_enabled = False
        self.inputStateChanged.emit(False)
        self.stopButtonStateChanged.emit(True)
        self.statusChanged.emit("🧠 Thinking...", "#cba6f7")
        self.messageAdded.emit("user", query)

        content = process_prompt(query)
        self.messages.append({"role": "user", "content": content})

        if hasattr(self, "ai_thread") and self.ai_thread is not None:
            if self.ai_thread.isRunning():
                self.ai_thread.stop()
            self.ai_thread.deleteLater()

        self.ai_thread = AIGeneratorThread(self.messages)
        self.ai_thread.status_signal.connect(self.statusChanged.emit)
        self.ai_thread.new_bubble_signal.connect(
            self.handle_message_added, Qt.ConnectionType.QueuedConnection
        )
        self.ai_thread.append_text_signal.connect(
            self.handle_message_appended, Qt.ConnectionType.QueuedConnection
        )
        self.ai_thread.sys_message_signal.connect(
            self.handle_message_added, Qt.ConnectionType.QueuedConnection
        )
        self.ai_thread.require_approval_signal.connect(self.requireApproval.emit)
        self.ai_thread.finished_signal.connect(self.on_ai_finished)
        self.ai_thread.history_save_signal.connect(self.save_history)
        self.ai_thread.start()

    def on_ai_finished(self, full_response):
        if full_response.strip():
            self.play_audio(full_response)
        else:
            self.statusChanged.emit("Idle", "#6c7086")
            self._input_enabled = True
            self.inputStateChanged.emit(True)
            self.stopButtonStateChanged.emit(False)

    def clean_text_for_tts(self, text):
        text = re.sub(r"```.*?```", " code block omitted. ", text, flags=re.DOTALL)
        text = re.sub(r"`.*?`", " code ", text)
        text = re.sub(r"\[(.*?)\]\(.*?\)", r"\1", text)
        text = re.sub(r"https?://[^\s]+", " link ", text)
        text = re.sub(r"\*\*(.*?)\*\*", r"\1", text)
        text = re.sub(r"\*(.*?)\*", r"\1", text)
        text = re.sub(r"__(.*?)__", r"\1", text)
        text = re.sub(r"^#+\s+", "", text, flags=re.MULTILINE)
        return text.strip()

    def play_audio(self, text):
        tts_text = self.clean_text_for_tts(text)

        if hasattr(self, "tts_thread") and self.tts_thread is not None:
            if self.tts_thread.isRunning():
                self.tts_thread.stop()
            self.tts_thread.deleteLater()

        self.tts_thread = TTSWorkerThread(tts_text)
        self.tts_thread.status_signal.connect(self.statusChanged.emit)
        self.tts_thread.finished_signal.connect(self.on_tts_finished)
        self.tts_thread.start()

    def on_tts_finished(self):
        if self.is_voice_mode:
            self.startVoiceRecording()
        else:
            self.statusChanged.emit("Idle", "#6c7086")
            self._input_enabled = True
            self.inputStateChanged.emit(True)
            self.stopButtonStateChanged.emit(False)


if __name__ == "__main__":
    app = QApplication(sys.argv)
    engine = QQmlApplicationEngine()

    initial_q = sys.argv[1] if len(sys.argv) > 1 else ""
    launch_m = sys.argv[2] if len(sys.argv) > 2 else ""
    backend = Backend(initial_q, launch_m)

    engine.rootContext().setContextProperty("backend", backend)
    engine.load(QUrl.fromLocalFile(QML_FILE))

    if not engine.rootObjects():
        sys.exit(-1)

    QTimer.singleShot(100, backend.emit_initial_state)

    sys.exit(app.exec())
