#!/bin/bash

# 1. Locate the real underlying podman execution binary safely
if [ -x "/usr/bin/podman-remote" ]; then
    REAL_PODMAN="/usr/bin/podman-remote"
elif [ -x "/usr/bin/podman" ]; then
    REAL_PODMAN="/usr/bin/podman"
else
    # Fallback search excluding our own wrapper paths to prevent loop recursion
    REAL_PODMAN=$(type -p -a podman | grep -vE "/usr/local/bin/podman|/usr/local/bin/docker" | head -n 1)
fi

if [ -z "$REAL_PODMAN" ] || [ ! -x "$REAL_PODMAN" ]; then
    echo "Error: Could not locate the real 'podman' or 'podman-remote' binary on the system." >&2
    exit 1
fi

new_args=()
i=1

# 2. Parse arguments and drop any variant of the '--userns' option
while [ $i -le $# ]; do
    arg="${!i}"
    case "$arg" in
        --userns=*)
            # Drop '--userns=value'
            i=$((i+1))
            ;;
        --userns)
            # Drop '--userns' and the next space-separated value (e.g. 'keep-id')
            i=$((i+2))
            ;;
        *)
            # Keep all other arguments untouched
            new_args+=("$arg")
            i=$((i+1))
            ;;
    esac
done

# 3. Hand off clean arguments directly to the real podman engine
exec "$REAL_PODMAN" "${new_args[@]}"