# ==============================================================================
# STAGE 1: WORKSPACE (Base CLI-only Workspace with Remote Podman Wrapper)
# ==============================================================================
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

RUN touch /etc/containers/nodocker

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
COPY podman-wrapper.sh /usr/local/bin/podman-wrapper
RUN chmod 755 /usr/local/bin/podman-wrapper && \
    ln -sf /usr/local/bin/podman-wrapper /usr/local/bin/podman && \
    ln -sf /usr/local/bin/podman-wrapper /usr/local/bin/docker
USER coder

RUN mkdir -p "$HOME/.ssh" && \
    chmod 700 "$HOME/.ssh" && \
    (ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" || true) && \
    chmod 600 "$HOME/.ssh/known_hosts" || true

USER root

# Standard default shell for the image
CMD ["/bin/bash"]


# ==============================================================================
# STAGE 2: WORKSPACE-PODMAN (CLI Workspace with Local Podman-in-Podman Engine)
# ==============================================================================
FROM workspace AS workspace-podman

USER root

# Install the actual Podman runtime, mapping tools, and standard routing configuration helper
RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
    podman \
    fuse-overlayfs \
    uidmap \
    slirp4netns \
    dbus-user-session \
    iptables && \
    rm -rf /var/lib/apt/lists/*

# Remove the remote wrapper to let local Podman run natively
RUN rm -f /usr/local/bin/podman /usr/local/bin/docker && \
    ln -sf /usr/bin/podman /usr/local/bin/docker

# Configure Sub-UIDs and Sub-GIDs mapping rules for root and coder
RUN echo "root:1:65535" > /etc/subuid && \
    echo "root:1:65535" > /etc/subgid && \
    echo "coder:1:65535" >> /etc/subuid && \
    echo "coder:1:65535" >> /etc/subgid

# Setup system-level Podman configuration files
RUN mkdir -p /etc/containers && \
    echo -e "[registries.search]\nregistries = ['docker.io', 'quay.io', 'gcr.io']" > /etc/containers/registries.conf && \
    echo -e "[storage]\ndriver = \"overlay\"\nrunroot = \"/run/containers/storage\"\ngraphroot = \"/var/lib/containers/storage\"\n\n[storage.options]\nadditionalimagestores = []\n\n[storage.options.overlay]\nmount_program = \"/usr/bin/fuse-overlayfs\"\nmountopt = \"nodev,fsync=0\"" > /etc/containers/storage.conf && \
    echo -e "[containers]\nnetns = \"host\"\n\n[engine]\ncgroup_manager = \"cgroupfs\"\nevents_logger = \"none\"\ndatabase_backend = \"sqlite\"" > /etc/containers/containers.conf

# Setup User-level (Rootless) Podman configurations for the 'coder' user
RUN mkdir -p /home/coder/.config/containers /home/coder/.local/share/containers && \
    echo -e "[storage]\ndriver = \"overlay\"\nrunroot = \"/run/user/1000/containers/storage\"\ngraphroot = \"/home/coder/.local/share/containers/storage\"\n\n[storage.options]\nadditionalimagestores = []\n\n[storage.options.overlay]\nmount_program = \"/usr/bin/fuse-overlayfs\"\nmountopt = \"nodev,fsync=0\"" > /home/coder/.config/containers/storage.conf && \
    echo -e "[containers]\nnetns = \"host\"\n\n[engine]\ncgroup_manager = \"cgroupfs\"\nevents_logger = \"none\"\ndatabase_backend = \"sqlite\"" > /home/coder/.config/containers/containers.conf && \
    chown -R coder:coder /home/coder/.config /home/coder/.local/share/containers

# Define Podman volumes for storage persistence
VOLUME /var/lib/containers
VOLUME /home/coder/.local/share/containers

ENV BUILDAH_ISOLATION=chroot

# Create the automated initialization script to expose the Rootful Podman socket inside the workspace
RUN cat > /usr/local/bin/init-local-podman.sh <<'EOF' && \
    chmod +x /usr/local/bin/init-local-podman.sh
#!/bin/bash
set -euo pipefail

SOCKET_PATH="/var/run/docker.sock"
echo "Initializing rootful Podman socket at $SOCKET_PATH..."

# Ensure we start with a clean runtime socket state
sudo rm -f "$SOCKET_PATH"
sudo mkdir -p "$(dirname "$SOCKET_PATH")"

# Launch the daemonless system service in the background as root
sudo podman system service --time 0 unix://"$SOCKET_PATH" >/dev/null 2>&1 &
SERVICE_PID=$!

# Wait for the system socket to initiate
for i in {1..25}; do
    if [ -S "$SOCKET_PATH" ]; then
        break
    fi
    sleep 0.2
done

if [ -S "$SOCKET_PATH" ]; then
    sudo chmod 0666 "$SOCKET_PATH"
    echo "Podman socket active and permissions set to 0666 successfully."
else
    echo "Error: Podman socket failed to initialize."
    exit 1
fi
EOF

USER coder
CMD ["/bin/bash"]


# ==============================================================================
# STAGE 3: WORKSPACE-DESKTOP (Desktop Environment, Remote Podman Wrapper)
# ==============================================================================
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

USER coder
CMD ["/bin/bash"]

# ==============================================================================
# STAGE 4: WORKSPACE-DESKTOP-PODMAN (Desktop Environment with Local Podman-in-Podman Engine)
# ==============================================================================
FROM workspace-podman AS workspace-desktop-podman

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

USER coder
CMD ["/bin/bash"]