#!/bin/bash
# Starts the MLX LM server for Braindrop.
# Run this once before using Braindrop, or add it to Login Items.

MODEL="mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"
PORT=8080

# Prefer Homebrew Python 3.11 (most compatible with mlx-lm)
for candidate in \
    /opt/homebrew/bin/python3.11 \
    /opt/homebrew/bin/python3.12 \
    /opt/homebrew/bin/python3 \
    /usr/bin/python3; do
    if [ -f "$candidate" ] && "$candidate" -c "import mlx_lm" 2>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "mlx_lm not found. Install with:"
    echo "  /opt/homebrew/bin/pip3.11 install -U mlx-lm"
    exit 1
fi

# Kill any existing instance
pkill -f "mlx_lm.server" 2>/dev/null
sleep 0.5

echo "Starting MLX LM server on port $PORT..."
echo "Model: $MODEL"
echo "Python: $PYTHON"
echo ""
echo "Note: First request compiles Metal shaders (~30s). Subsequent requests are fast."
echo ""

exec "$PYTHON" -m mlx_lm.server \
    --model "$MODEL" \
    --port "$PORT" \
    --host 127.0.0.1
