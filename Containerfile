FROM registry.opensuse.org/opensuse/tumbleweed:latest

RUN zypper --non-interactive refresh && \
    zypper --non-interactive install --no-recommends \
      git ripgrep curl tar gzip openssh-clients && \
    zypper clean --all

ENV OPENCODE_INSTALL_DIR=/usr/local/bin

RUN curl -fsSL https://opencode.ai/v2/install -o /tmp/install.sh && \
    bash /tmp/install.sh && \
    install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode && \
    rm -rf /root/.opencode /tmp/install.sh && \
    opencode --version

RUN useradd -m -u 1000 -s /bin/bash agent

USER agent
WORKDIR /work

CMD ["bash"]

