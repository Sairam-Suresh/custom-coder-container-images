#!/bin/bash

# 1. Direct path to the real devcontainer binary
REAL_DEVCONTAINER="/home/coder/.local/bin/devcontainer-real"

if [ ! -x "$REAL_DEVCONTAINER" ]; then
    echo "Error: The real devcontainer binary was not found or is not executable at: $REAL_DEVCONTAINER" >&2
    exit 1
fi

# 2. Extract arguments to detect orchestrations and configurations
COMMAND=""
WORKSPACE_FOLDER=""
POSITIONAL_FOLDER=""
CONFIG_FILE=""
args=()

for arg in "$@"; do
    case "$arg" in
        up|build|read-configuration|exec|run-user-commands|stop|down)
            COMMAND="$arg"
            break
            ;;
    esac
done

i=1
while [ $i -le $# ]; do
    arg="${!i}"
    case "$arg" in
        --workspace-folder)
            next_idx=$((i+1))
            WORKSPACE_FOLDER="${!next_idx}"
            args+=("$arg" "$WORKSPACE_FOLDER")
            i=$((i+2))
            ;;
        --workspace-folder=*)
            WORKSPACE_FOLDER="${arg#*=}"
            args+=("$arg")
            i=$((i+1))
            ;;
        --config)
            next_idx=$((i+1))
            CONFIG_FILE="${!next_idx}"
            i=$((i+2))
            ;;
        --config=*)
            CONFIG_FILE="${arg#*=}"
            i=$((i+1))
            ;;
        -*)
            args+=("$arg")
            i=$((i+1))
            ;;
        *)
            if [ "$arg" != "$COMMAND" ] && [ -z "$POSITIONAL_FOLDER" ]; then
                POSITIONAL_FOLDER="$arg"
            fi
            args+=("$arg")
            i=$((i+1))
            ;;
    esac
done

# Resolve fallback directories for the context if not explicitly passed
if [ -z "$WORKSPACE_FOLDER" ]; then
    WORKSPACE_FOLDER="${POSITIONAL_FOLDER:-.}"
fi

# Locate devcontainer configuration file
if [ -z "$CONFIG_FILE" ]; then
    if [ -f "$WORKSPACE_FOLDER/.devcontainer/devcontainer.json" ]; then
        CONFIG_FILE="$WORKSPACE_FOLDER/.devcontainer/devcontainer.json"
    elif [ -f "$WORKSPACE_FOLDER/.devcontainer.json" ]; then
        CONFIG_FILE="$WORKSPACE_FOLDER/.devcontainer.json"
    fi
fi

# 3. Inject configuration modifications via a Named Pipe (FIFO)
case "$COMMAND" in
    up|build|read-configuration)
        if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
            CONFIG_DIR=$(dirname "$CONFIG_FILE")
            CONFIG_BASE=$(basename "$CONFIG_FILE")

            # Choose an alternate accepted name to avoid collision with the real file
            if [ "$CONFIG_BASE" = "devcontainer.json" ]; then
                PIPE_NAME=".devcontainer.json"
            else
                PIPE_NAME="devcontainer.json"
            fi

            PIPE_PATH="$CONFIG_DIR/$PIPE_NAME"

            # Clean up the pipe unconditionally on exit
            cleanup() {
                rm -f "$PIPE_PATH"
            }
            trap cleanup EXIT

            # Build the clean FIFO channel
            rm -f "$PIPE_PATH"
            mkfifo "$PIPE_PATH"

            # Process adjustments strictly within runtime memory
            MODIFIED_JSON=$(python3 -c '
import sys, re, json

def clean_jsonc(text):
    pattern = re.compile(r"//.*?$|/\*.*?\*/|(\"(?:\\.|[^\"\\])*\")", re.DOTALL | re.MULTILINE)
    clean = pattern.sub(lambda m: m.group(1) if m.group(1) else "", text)
    return re.sub(r",(\s*[\]}])", r"\1", clean)

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        raw_content = f.read()
    
    data = json.loads(clean_jsonc(raw_content))
    data["updateRemoteUserUID"] = False
    
    run_args = data.get("runArgs", [])
    if isinstance(run_args, str):
        run_args = [run_args]
        
    if not any(arg.startswith("--userns") for arg in run_args):
        run_args.append("--userns=")
        
    data["runArgs"] = run_args
    print(json.dumps(data))
except Exception:
    print(raw_content)
' "$CONFIG_FILE")

            # Continuously feed the pipe in the background to handle multi-pass validation checks
            while [ -p "$PIPE_PATH" ]; do
                echo "$MODIFIED_JSON" > "$PIPE_PATH"
            done 2>/dev/null &
            FEED_PID=$!

            # Execute the real command targeting our streaming channel
            "$REAL_DEVCONTAINER" "${args[@]}" --config "$PIPE_PATH"
            EXIT_CODE=$?

            kill $FEED_PID 2>/dev/null
            exit $EXIT_CODE
        fi
        ;;
esac

# 4. Standard pass-through fallback for state commands (exec, stop, down, etc.)
exec "$REAL_DEVCONTAINER" "$@"