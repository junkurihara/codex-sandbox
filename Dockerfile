FROM ubuntu:24.04

ARG TZ=Asia/Tokyo
ARG CODEX_VERSION=latest
ARG NODE_VERSION=lts
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

ENV TZ="${TZ}" \
  DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
  aggregate \
  build-essential \
  ca-certificates \
  curl \
  dnsutils \
  fzf \
  git \
  gnupg2 \
  iproute2 \
  ipset \
  iptables \
  jq \
  less \
  locales \
  man-db \
  nano \
  openssh-client \
  pkg-config \
  procps \
  sudo \
  tmux \
  unzip \
  vim \
  wget \
  zsh \
  libssl-dev \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8 ja_JP.UTF-8 && update-locale LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8 \
  LC_ALL=en_US.UTF-8

RUN set -eux; \
  if getent passwd ubuntu >/dev/null; then userdel -r ubuntu; fi; \
  groupadd -g "${USER_GID}" "${USERNAME}"; \
  useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/zsh "${USERNAME}"; \
  printf '%s ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh\n' "${USERNAME}" > "/etc/sudoers.d/${USERNAME}-firewall"; \
  chmod 0440 "/etc/sudoers.d/${USERNAME}-firewall"

# Install Node via n, then install Codex CLI from npm.
RUN curl -fsSL https://raw.githubusercontent.com/tj/n/master/bin/n -o /usr/local/bin/n \
  && chmod +x /usr/local/bin/n \
  && n "${NODE_VERSION}" \
  && npm install -g npm@latest \
  && npm install -g "@openai/codex@${CODEX_VERSION}" \
  && npm cache clean --force

RUN mkdir -p /workspace "/home/${USERNAME}/.codex" /commandhistory /usr/local/share/codex-sandbox/rules \
  && touch /commandhistory/.zsh_history \
  && chown -R "${USER_UID}:${USER_GID}" /workspace "/home/${USERNAME}/.codex" /commandhistory

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY install-tools.sh /usr/local/bin/install-tools
COPY wt-preupdate.sh /usr/local/bin/wt-preupdate
COPY entrypoint.sh /usr/local/bin/codex-sandbox-entrypoint
COPY sandbox-AGENTS.md /usr/local/share/codex-sandbox/sandbox-AGENTS.md
COPY sandbox-config.toml /usr/local/share/codex-sandbox/sandbox-config.toml
COPY sandbox-rules/default.rules /usr/local/share/codex-sandbox/rules/default.rules
RUN chmod +x \
  /usr/local/bin/init-firewall.sh \
  /usr/local/bin/install-tools \
  /usr/local/bin/wt-preupdate \
  /usr/local/bin/codex-sandbox-entrypoint

RUN printf '%s\n' \
  'unbind C-b' \
  'set -g prefix C-Space' \
  'bind C-Space send-prefix' \
  'set -g mouse on' \
  'set -g history-limit 50000' \
  'setw -g mode-keys emacs' \
  > "/home/${USERNAME}/.tmux.conf" \
  && printf '%s\n' \
  'export HISTFILE=/commandhistory/.zsh_history' \
  'export SAVEHIST=50000' \
  'export HISTSIZE=50000' \
  'setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS' \
  > "/home/${USERNAME}/.zshrc" \
  && chown "${USER_UID}:${USER_GID}" "/home/${USERNAME}/.tmux.conf" "/home/${USERNAME}/.zshrc"

ENV DEVCONTAINER=true \
  SHELL=/bin/zsh \
  EDITOR=nano \
  CODEX_HOME=/home/${USERNAME}/.codex \
  HISTFILE=/commandhistory/.zsh_history

USER "${USERNAME}"
WORKDIR "/home/${USERNAME}"

RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
  && sh /tmp/rustup-init.sh -y --default-toolchain stable --profile minimal --component clippy --component rustfmt \
  && rm /tmp/rustup-init.sh

ENV PATH="/home/${USERNAME}/.cargo/bin:${PATH}"

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/codex-sandbox-entrypoint"]
