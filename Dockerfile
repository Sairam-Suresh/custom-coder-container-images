# STAGE 1: WORKSPACE (Base Image)
FROM debian:13 AS workspace

USER root

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
    bash \
    ca-certificates \
    curl \
    git \
    direnv \
    jq \
    locales \
    openssh-client \
    procps \
    sudo \
    xz-utils && \
    rm -rf /var/lib/apt/lists/*

# Generate the desired locale (en_US.UTF-8)
RUN if [ -f /etc/locale.gen ]; then \
        sed -i -e '/en_US.UTF-8/s/^# *//' /etc/locale.gen || true; \
    fi && \
    locale-gen en_US.UTF-8 || true && \
    update-locale LANG=en_US.UTF-8 || true

# Make typing unicode characters in the terminal work.
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install Nix package manager (multi-user mode)
# This enables `nix develop` / `nix build` for projects with flake.nix
RUN curl --proto '=https' --tlsv1.2 -sSf -L \
      https://install.determinate.systems/nix | \
      sh -s -- install linux \
      --init none \
      --no-confirm \
      --extra-conf "sandbox = false" \
      --extra-conf "experimental-features = nix-command flakes" && \
    echo 'if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; fi' \
      >> /etc/bash.bashrc && \
    echo 'if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; fi' \
      >> /etc/profile.d/nix.sh

RUN mkdir -p /etc/nix && \
    echo "trusted-users = root coder" >> /etc/nix/nix.conf && \
    chmod 644 /etc/nix/nix.conf

RUN if [ -d /nix/var/nix/profiles/default/bin ]; then \
            echo "Symlinking Nix binaries to /usr/bin..."; \
            for bin in /nix/var/nix/profiles/default/bin/*; do \
                echo "Linking $bin -> /usr/bin/$(basename "$bin")"; \
                ln -sf "$bin" "/usr/bin/$(basename "$bin")"; \
            done; \
        else \
            echo "ERROR: Nix default profile bin directory not found!" && exit 1; \
        fi

# Install Node.js (needed for devcontainer support)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
      apt-get install -y nodejs && \
      rm -rf /var/lib/apt/lists/*

RUN echo "prefix=/home/coder/.local" > /etc/npmrc

# Add coder user
RUN useradd coder \
    --create-home \
    --shell=/bin/bash \
    --uid=1000 \
    --user-group && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers.d/nopasswd

RUN mkdir -p /home/coder/.local/bin /home/coder/.local/lib && \
    chown -R coder:coder /home/coder/.local

USER coder

ENV NIX_REMOTE=daemon
ENV PATH=/home/coder/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/home/coder/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games

# Source Nix profile for the coder user so nix, nix-shell, nix develop etc. are available
RUN echo 'if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; fi' >> ~/.bashrc && \
    echo 'if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; fi' >> ~/.profile && \
    echo 'export NIX_REMOTE=daemon' >> ~/.bashrc

# Ensure system-wide environments also have NIX_REMOTE and NPM configuration presets
USER root
RUN echo 'export NIX_REMOTE=daemon' >> /etc/bash.bashrc && \
    echo 'export NIX_REMOTE=daemon' >> /etc/profile.d/nix.sh && \
    echo 'export NPM_CONFIG_PREFIX="/home/coder/.local"' >> /etc/bash.bashrc && \
    echo 'export PATH="/home/coder/.local/bin:$PATH"' >> /etc/bash.bashrc && \
    echo 'export NPM_CONFIG_PREFIX="/home/coder/.local"' >> /etc/profile.d/npm.sh && \
    echo 'export PATH="/home/coder/.local/bin:$PATH"' >> /etc/profile.d/npm.sh
USER coder

# Set up local prefix to allow global npm installations without root permissions
RUN export NPM_CONFIG_PREFIX="$HOME/.local" && \
        mkdir -p "$NPM_CONFIG_PREFIX" && \
        npm config set prefix "$NPM_CONFIG_PREFIX" && \
        if ! grep -q "NPM_CONFIG_PREFIX" ~/.bashrc; then \
            echo 'export NPM_CONFIG_PREFIX="$HOME/.local"' >> ~/.bashrc && \
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc; \
        fi && \
        export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"

RUN npm install -g @devcontainers/cli

USER root
RUN ln -sf /home/coder/.local/bin/devcontainer /usr/bin/devcontainer

USER coder

RUN mkdir -p "$HOME/.ssh" && \
    chmod 700 "$HOME/.ssh" && \
    (ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" || true) && \
    chmod 600 "$HOME/.ssh/known_hosts" || true

USER root
RUN mkdir -p /etc/coder-skeleton && \
    cp -rP /home/coder/. /etc/coder-skeleton/ && \
    chown -R coder:coder /etc/coder-skeleton

RUN cat > /usr/local/bin/coder-entrypoint.sh <<'EOF' && \
    chmod +x /usr/local/bin/coder-entrypoint.sh
#!/bin/bash
set -e

# 1. Start the Nix Daemon in the background as root (via passwordless sudo)
if command -v nix-daemon >/dev/null 2>&1; then
    echo "Starting Nix Daemon in the background..."
    sudo "$(command -v nix-daemon)" --daemon >/dev/null 2>&1 &
elif [ -x /nix/var/nix/profiles/default/bin/nix-daemon ]; then
    echo "Starting Nix Daemon in the background..."
    sudo /nix/var/nix/profiles/default/bin/nix-daemon --daemon >/dev/null 2>&1 &
fi

# 2. Populate /home/coder if it was masked by an empty persistent volume mount
if [ ! -f "$HOME/.bashrc" ] || [ ! -d "$HOME/.local" ]; then
    echo "Initializing empty persistent home from container skeleton..."
    cp -rT /etc/coder-skeleton "$HOME" 2>/dev/null || true
    chown -R coder:coder "$HOME"
fi

# 3. Exec standard shell command / Coder Agent
exec "$@"
EOF

USER coder

ENTRYPOINT ["/usr/local/bin/coder-entrypoint.sh"]
CMD ["bash", "-l", "/opt/coder/agent.sh"]

# STAGE 2: WORKSPACE-DESKTOP (Desktop environment)
FROM workspace AS workspace-desktop

USER root

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    apt-get install -y --no-install-recommends --no-install-suggests dbus-x11 libdatetime-perl openssl ssl-cert xfce4 xfce4-goodies

RUN set -eux; \
    curl -fsSL -o /root/kasmvncserver_bookworm_1.3.2_amd64.deb https://github.com/kasmtech/KasmVNC/releases/download/v1.3.2/kasmvncserver_bookworm_1.3.2_amd64.deb; \
    curl -fsSL -o /tmp/google-chrome-stable_current_amd64.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y /root/kasmvncserver_bookworm_1.3.2_amd64.deb /tmp/google-chrome-stable_current_amd64.deb; \
    rm -f /root/kasmvncserver_bookworm_1.3.2_amd64.deb /tmp/google-chrome-stable_current_amd64.deb; \
    rm -rf /var/lib/apt/lists/*

# Wrapper to ensure Chrome runs well inside containers (disable /dev/shm usage etc.)
RUN cat > /usr/local/bin/google-chrome <<'EOF' && \
    chmod +x /usr/local/bin/google-chrome
#!/bin/sh
exec /usr/bin/google-chrome "$@" --disable-dev-shm-usage
EOF

# Setting the required environment variables
ARG USER=coder
RUN echo 'LANG=en_US.UTF-8' >> /etc/default/locale; \
    echo 'export GNOME_SHELL_SESSION_MODE=debian' > /home/$USER/.xsessionrc; \
    echo 'export XDG_CURRENT_DESKTOP=xfce' >> /home/$USER/.xsessionrc; \
    echo 'export XDG_SESSION_TYPE=x11' >> /home/$USER/.xsessionrc;

# Sync the updated home directory to the desktop-stage skeleton
RUN cp -rP /home/coder/. /etc/coder-skeleton/ && \
    chown -R coder:coder /etc/coder-skeleton

USER coder

ENTRYPOINT ["/usr/local/bin/coder-entrypoint.sh"]
CMD ["bash", "-l", "/opt/coder/agent.sh"]