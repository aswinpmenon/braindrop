#!/bin/bash
# Starts llama-server (llama.cpp) for Substage
# Run this once before using Substage, or add it to your login items.

MODEL_BLOB="$HOME/.ollama/models/blobs/sha256-dde5aa3fc5ffc17176b5e8bdc82f587b24b2678c6c66101bf7da77af9f7ccdff"
PORT=8080

# Kill any existing instance
pkill -f "llama-server" 2>/dev/null
sleep 1

if [ ! -f "$MODEL_BLOB" ]; then
    echo "Model not found at $MODEL_BLOB"
    echo "Run: ollama pull llama3.2"
    exit 1
fi

echo "Starting llama-server on port $PORT..."
echo "Model: llama3.2 (3B)"
echo ""

exec llama-server \
    --model "$MODEL_BLOB" \
    --port "$PORT" \
    --host 127.0.0.1 \
    --ctx-size 4096 \
    --threads $(sysctl -n hw.logicalcpu) \
    --alias llama3.2
