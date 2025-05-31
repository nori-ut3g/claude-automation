# Claude Automation System - Docker Image
# Raspberry Pi 4 (ARM64) 対応

FROM arm64v8/ubuntu:22.04

# メタデータ
LABEL maintainer="Claude Automation System"
LABEL description="Claude Automation System for Raspberry Pi"
LABEL version="2.0"

# 環境変数設定
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Tokyo
ENV CLAUDE_AUTO_HOME=/opt/claude-automation
ENV PATH="${CLAUDE_AUTO_HOME}/scripts:${PATH}"

# タイムゾーン設定
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# 基本パッケージのインストール
RUN apt-get update && apt-get install -y \
    # 基本ツール
    curl \
    wget \
    git \
    jq \
    unzip \
    ca-certificates \
    gnupg \
    lsb-release \
    # 開発ツール
    build-essential \
    # Python
    python3 \
    python3-pip \
    # Node.js (GitHub CLI用)
    nodejs \
    npm \
    # システム管理
    systemd \
    supervisor \
    logrotate \
    # ネットワーク
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# yq (YAML処理) のインストール
RUN wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64 \
    && chmod +x /usr/local/bin/yq

# GitHub CLI のインストール
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# 非rootユーザーの作成
RUN useradd -m -s /bin/bash -u 1000 claude \
    && usermod -aG sudo claude \
    && echo 'claude ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# プロジェクトディレクトリの作成
RUN mkdir -p $CLAUDE_AUTO_HOME \
    && mkdir -p $CLAUDE_AUTO_HOME/logs \
    && mkdir -p $CLAUDE_AUTO_HOME/workspace \
    && mkdir -p /var/log/claude-automation \
    && chown -R claude:claude $CLAUDE_AUTO_HOME \
    && chown -R claude:claude /var/log/claude-automation

# プロジェクトファイルをコピー
COPY --chown=claude:claude . $CLAUDE_AUTO_HOME/

# 実行権限を設定
RUN chmod +x $CLAUDE_AUTO_HOME/scripts/*.sh \
    && chmod +x $CLAUDE_AUTO_HOME/src/core/*.sh \
    && chmod +x $CLAUDE_AUTO_HOME/src/integrations/*.sh \
    && chmod +x $CLAUDE_AUTO_HOME/src/utils/*.sh

# Supervisor設定
COPY docker/supervisord.conf /etc/supervisor/conf.d/claude-automation.conf

# ログローテーション設定
COPY docker/logrotate.conf /etc/logrotate.d/claude-automation

# ヘルスチェック用スクリプト
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh

# 作業ディレクトリを設定
WORKDIR $CLAUDE_AUTO_HOME

# ユーザーを切り替え
USER claude

# ヘルスチェック設定
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# ボリューム設定
VOLUME ["$CLAUDE_AUTO_HOME/config", "$CLAUDE_AUTO_HOME/logs", "$CLAUDE_AUTO_HOME/workspace"]

# ポート公開（必要に応じて）
# EXPOSE 8080

# 起動コマンド
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf", "-n"]