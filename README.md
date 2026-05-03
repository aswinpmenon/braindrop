# Braindrop

A native macOS menu-bar app that docks a thin command bar below your Finder window. Type what you want to do in plain English — Braindrop translates it into a shell command, shows you what it will change, and runs it.

**Powered by Apple MLX** running Qwen2.5-Coder locally on your Apple Silicon GPU.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![MLX](https://img.shields.io/badge/Apple-MLX-black)

---

## What it does

- Press **⌃Space** anywhere → a bar appears below your Finder window
- Type a natural-language request: *"compress all PNGs here"*, *"how many files"*, *"rename these to lowercase"*
- Braindrop generates the shell command and previews what files will be created, modified, or deleted
- Press **Return** (or **Run**) to execute — or **Escape** to cancel

Works with your selected files **or** the open folder when nothing is selected.

---

## Why MLX?

Braindrop uses Apple's [MLX](https://github.com/ml-explore/mlx) framework instead of llama.cpp or Ollama:

| | MLX (Braindrop) | llama.cpp | Ollama |
|---|---|---|---|
| Apple Silicon | Native GPU (Metal) | Metal (patched) | Crashes on macOS 26 |
| 1.5B model speed | ~130 tok/s | ~34 tok/s | — |
| Memory (1.5B 4-bit) | ~1 GB | ~1.5 GB | — |
| First-run setup | pip install | brew install | broken |

Model used: **Qwen2.5-Coder-1.5B-Instruct (4-bit)** — a code-tuned model that excels at generating shell commands.

---

## Requirements

- macOS 14 Sonoma or later (tested on macOS 26 / Apple Silicon M-series)
- [Homebrew](https://brew.sh)
- Python 3.11 (via Homebrew)
- Xcode Command Line Tools

---

## Installation

### 1 — Install Homebrew Python 3.11 (if not already installed)

```bash
brew install python@3.11
```

### 2 — Install MLX LM

```bash
/opt/homebrew/bin/pip3.11 install -U mlx-lm
```

This also downloads the MLX framework (~50 MB). The Qwen model (~1 GB) downloads automatically on first server start.

### 3 — Install Braindrop

Download or clone this repo, then:

```bash
cd ~/Downloads/Braindrop
bash build.sh
cp -r Braindrop.app /Applications/
open /Applications/Braindrop.app
```

Requires Xcode Command Line Tools (`xcode-select --install`).

### 4 — Start the LLM server

```bash
bash ~/Downloads/Braindrop/start-mlx-server.sh
```

Keep this terminal open (or set it up as a Login Item — see below). The server runs on `http://127.0.0.1:8080`.

> **First request:** Metal shaders compile on the very first inference (~30 seconds). Every request after that is fast (~130 tok/s, typically under 1 second for a command).

### 5 — Grant permissions

On first launch macOS will ask for two permissions:

| Permission | Why |
|---|---|
| **Accessibility** | Needed for the global ⌃Space hotkey |
| **Automation → Finder** | Reads your selected files and current folder |

Go to **System Settings → Privacy & Security → Accessibility** and enable Braindrop if it isn't listed.

---

## Auto-start the server at login (optional)

```bash
cat > ~/Library/LaunchAgents/io.braindrop.mlx-server.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>             <string>io.braindrop.mlx-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/YOUR_USERNAME/Downloads/Braindrop/start-mlx-server.sh</string>
    </array>
    <key>RunAtLoad</key>         <true/>
    <key>KeepAlive</key>         <true/>
    <key>StandardOutPath</key>   <string>/tmp/braindrop-mlx.log</string>
    <key>StandardErrorPath</key> <string>/tmp/braindrop-mlx.log</string>
</dict>
</plist>
EOF
```

Replace `YOUR_USERNAME` with your macOS username (`whoami`), then load it:

```bash
launchctl load ~/Library/LaunchAgents/io.braindrop.mlx-server.plist
```

---

## Usage

| Action | How |
|---|---|
| Open bar | **⌃Space** |
| Close bar | **Escape** |
| Run command | **Return** or click **Run** |
| Navigate history | **↑ / ↓** in the text field |
| Copy generated command | Click the copy icon |

### Tips

- Select files in Finder before pressing ⌃Space — Braindrop will target exactly those files
- With no selection, the current open folder is used as context
- Destructive commands (delete, overwrite) show a red **Run anyway** button
- Tweak which categories run without confirmation in **Settings → Auto-run**

---

## Settings

Open via the menu-bar icon → **Settings…** or the gear icon in the bar.

- **General** — keyboard shortcut, command history
- **Auto-run** — choose which command types run without asking
- **AI Models** — server URL, model name, connection test
- **About** — version info

### Switching models

The default model is `mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit`. You can switch to a larger model for better quality:

| Model | Size | Speed | Quality |
|---|---|---|---|
| `Qwen2.5-Coder-0.5B-Instruct-4bit` | 0.4 GB | Fastest | Basic |
| `Qwen2.5-Coder-1.5B-Instruct-4bit` | 1 GB | Fast | **Default** |
| `Qwen2.5-Coder-3B-Instruct-4bit` | 2 GB | Good | Better |
| `Qwen2.5-Coder-7B-Instruct-4bit` | 4.5 GB | Slower | Best |

All models are in the `mlx-community` org on HuggingFace and download automatically.

---

## Building from source

```bash
git clone https://github.com/aswinpmenon/braindrop.git
cd braindrop
bash build.sh
```

---

## License

MIT
