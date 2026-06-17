# STAGE 1: WORKSPACE (Base Image)
FROM debian:13 AS workspace

USER root

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# Install baseline packages
RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
    bash \
    build-essential \
    curl \
    htop \
    jq \
    locales \
    man \
    pipx \
    python3 \
    python3-pip \
    podman-compose \
    sudo \
    procps \
    unzip \
    vim \
    wget \
    openssh-client \
    rsync \
    iproute2 \
    podman-remote \
    git

RUN ln -s "$(command -v podman-remote)" /usr/local/bin/podman && \
    ln -s "$(command -v podman-remote)" /usr/local/bin/docker

# Generate the desired locale (en_US.UTF-8)
# Ensure en_US.UTF-8 is enabled and generated to avoid setlocale warnings
RUN if [ -f /etc/locale.gen ]; then \
        sed -i -e '/en_US.UTF-8/s/^# *//' /etc/locale.gen || true; \
    fi && \
    locale-gen en_US.UTF-8 || true && \
    update-locale LANG=en_US.UTF-8 || true

# Make typing unicode characters in the terminal work.
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
      apt-get install -y nodejs && \
      rm -rf /var/lib/apt/lists/*

# Add coder user
RUN useradd coder \
    --create-home \
    --shell=/bin/bash \
    --uid=1000 \
    --user-group && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers.d/nopasswd

USER coder

ENV PATH=/home/coder/.local/bin:/home/coder/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games

RUN export NPM_CONFIG_PREFIX="$HOME/.local" && \
        mkdir -p "$NPM_CONFIG_PREFIX" && \
        npm config set prefix "$NPM_CONFIG_PREFIX" && \
        if ! grep -q "NPM_CONFIG_PREFIX" ~/.bashrc; then \
            echo 'export NPM_CONFIG_PREFIX="$HOME/.local"' >> ~/.bashrc && \
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc; \
        fi && \
        export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"

RUN npm install -g @devcontainers/cli

RUN mkdir -p "$HOME/.ssh" && \
    chmod 700 "$HOME/.ssh" && \
    (ssh-keyscan -H github.com >> "$HOME/.ssh/known_hosts" || true) && \
    chmod 600 "$HOME/.ssh/known_hosts" || true

RUN pipx ensurepath

# STAGE 2: WORKSPACE-DESKTOP
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