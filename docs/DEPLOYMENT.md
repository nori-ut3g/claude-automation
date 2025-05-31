# Claude Automation System - デプロイガイド

このドキュメントでは、Claude Automation SystemをRaspberry Pi及びDockerでデプロイする方法について詳しく説明します。

## 目次

1. [Raspberry Pi デプロイ](#raspberry-pi-デプロイ)
2. [Docker デプロイ](#docker-デプロイ)
3. [システム要件](#システム要件)
4. [事前準備](#事前準備)
5. [トラブルシューティング](#トラブルシューティング)

---

## Raspberry Pi デプロイ

Raspberry Pi上でClaude Automation Systemを直接実行する方法です。

### 必要なもの

- **Raspberry Pi 4** (推奨: 4GB以上のRAM)
- **Raspberry Pi OS** (64-bit推奨)
- **SDカード** (32GB以上推奨)
- **安定したインターネット接続**

### 1. Raspberry Piの準備

#### Raspberry Pi OSの設定

```bash
# システムの更新
sudo apt update && sudo apt upgrade -y

# SSH有効化（まだの場合）
sudo systemctl enable ssh
sudo systemctl start ssh

# 必要に応じて固定IPを設定
sudo nano /etc/dhcpcd.conf
```

#### SSH鍵の設定（推奨）

```bash
# ローカルマシンから
ssh-copy-id pi@<raspberry_pi_ip>
```

### 2. 自動デプロイの実行

プロジェクトルートで以下のコマンドを実行：

```bash
# 基本デプロイ
./scripts/deploy-to-raspberry-pi.sh 192.168.1.100

# ユーザー名を指定
./scripts/deploy-to-raspberry-pi.sh 192.168.1.100 ubuntu

# ホスト名での指定
./scripts/deploy-to-raspberry-pi.sh claude-pi.local
```

### 3. デプロイ後の設定

Raspberry Piにログインして以下を実行：

```bash
# Raspberry Piにログイン
ssh pi@<raspberry_pi_ip>

# デプロイディレクトリに移動
cd /opt/claude-automation

# 環境変数を設定
nano .env
```

#### .env ファイルの設定例

```bash
# GitHub設定（必須）
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
GITHUB_USERNAME=your_username

# Claude設定（Claude Code CLIで自動設定される場合は不要）
# ANTHROPIC_API_KEY=your_api_key

# Slack通知（オプション）
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/xxx/xxx/xxx

# ログ設定
LOG_LEVEL=info
LOG_FILE=/var/log/claude-automation/claude-automation.log

# システム設定
CLAUDE_AUTO_HOME=/opt/claude-automation
TZ=Asia/Tokyo
```

#### リポジトリ設定

```bash
# 監視対象リポジトリを設定
nano config/repositories.yaml
```

### 4. Claude Code CLIの認証

```bash
# Claude Code CLIの認証
claude auth login

# GitHub CLIの認証
gh auth login
```

### 5. サービスの開始

```bash
# systemdサービスとして開始
sudo systemctl start claude-automation
sudo systemctl enable claude-automation

# サービス状態の確認
sudo systemctl status claude-automation

# ログの確認
tail -f /var/log/claude-automation/claude-automation.log
```

### 6. システム管理

```bash
# サービス制御
sudo systemctl start claude-automation      # 開始
sudo systemctl stop claude-automation       # 停止
sudo systemctl restart claude-automation    # 再起動
sudo systemctl reload claude-automation     # リロード

# ログ確認
sudo journalctl -u claude-automation -f     # systemdログ
tail -f /var/log/claude-automation/*.log    # アプリケーションログ

# ヘルスチェック
/opt/claude-automation/scripts/health-check.sh
```

---

## Docker デプロイ

Docker環境でClaude Automation Systemを実行する方法です。

### 必要なもの

- **Docker Engine** 20.10以上
- **Docker Compose** V2
- **メモリ** 2GB以上推奨

### 1. Dockerのインストール

#### Raspberry Pi の場合

```bash
# Dockerのインストール
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# ユーザーをdockerグループに追加
sudo usermod -aG docker $USER

# ログインし直すか以下を実行
newgrp docker

# Docker Composeのインストール
sudo apt-get install docker-compose-plugin
```

#### 他のLinuxディストリビューションの場合

公式ドキュメントを参照: https://docs.docker.com/engine/install/

### 2. プロジェクトの準備

```bash
# プロジェクトをクローン
git clone https://github.com/your-username/claude-automation.git
cd claude-automation

# 環境変数ファイルを作成
cp .env.example .env
nano .env
```

### 3. デプロイの実行

#### 基本デプロイ

```bash
# 通常のデプロイ
./scripts/deploy-docker.sh

# クリーンデプロイ（既存のコンテナを削除）
./scripts/deploy-docker.sh --clean

# イメージビルドのみ
./scripts/deploy-docker.sh --build-only
```

#### 監視機能付きデプロイ

```bash
# Prometheus + Grafana監視付き
./scripts/deploy-docker.sh --monitoring

# クリーン + 監視付き
./scripts/deploy-docker.sh --clean --monitoring
```

### 4. 手動でのDocker Compose操作

```bash
# サービス開始
docker-compose up -d

# 監視サービス付きで開始
docker-compose --profile monitoring up -d

# サービス停止
docker-compose down

# ボリューム含めて完全削除
docker-compose down --volumes

# ログ確認
docker-compose logs -f claude-automation

# コンテナ内でシェル実行
docker-compose exec claude-automation bash
```

### 5. コンテナ内での認証

```bash
# Claude Code CLIの認証
docker-compose exec claude-automation claude auth login

# GitHub CLIの認証
docker-compose exec claude-automation gh auth login
```

### 6. 監視ダッシュボード

監視機能を有効にした場合：

- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3000 (admin/admin)

### 7. Docker管理コマンド

```bash
# サービス状態確認
docker-compose ps

# ヘルスチェック
docker-compose exec claude-automation /opt/claude-automation/scripts/health-check.sh

# リソース使用量確認
docker stats claude-automation

# ログ確認
docker-compose logs -f claude-automation

# 設定リロード
docker-compose restart claude-automation
```

---

## システム要件

### 最小要件

| 項目 | Raspberry Pi | Docker |
|------|--------------|--------|
| CPU | ARM64 (Pi 4以上) | ARM64/x64 |
| メモリ | 2GB | 2GB |
| ストレージ | 16GB | 10GB |
| OS | Raspberry Pi OS 64-bit | Linux/macOS/Windows |

### 推奨要件

| 項目 | Raspberry Pi | Docker |
|------|--------------|--------|
| CPU | ARM64 (Pi 4 4GB/8GB) | 2+ cores |
| メモリ | 4GB以上 | 4GB以上 |
| ストレージ | 32GB以上 | 20GB以上 |
| ネットワーク | 有線接続推奨 | 安定した接続 |

---

## 事前準備

### 1. GitHubの設定

#### Personal Access Tokenの作成

1. GitHub → Settings → Developer settings → Personal access tokens
2. "Generate new token (classic)"を選択
3. 必要なスコープを選択：
   - `repo` - プライベートリポジトリアクセス
   - `public_repo` - パブリックリポジトリアクセス
   - `workflow` - GitHub Actionsアクセス

### 2. Claude Code CLIの準備

ローカルマシンでClaude Code CLIをテスト：

```bash
# インストール確認
claude --version

# 認証テスト
claude auth status

# 簡単なテスト
echo "Hello, Claude!" | claude
```

### 3. ネットワーク設定

#### ファイアウォール設定

```bash
# UFW（Ubuntu Firewall）の場合
sudo ufw allow ssh
sudo ufw allow out 443  # HTTPS
sudo ufw allow out 53   # DNS
```

#### ポートフォワーディング（必要に応じて）

- **SSH**: 22
- **HTTP**: 80 (リバースプロキシ使用時)
- **HTTPS**: 443 (リバースプロキシ使用時)
- **Grafana**: 3000 (監視使用時)

---

## トラブルシューティング

### 一般的な問題

#### 1. SSH接続エラー

**エラー**: `Permission denied (publickey)`

**解決方法**:
```bash
# パスワード認証を有効化
sudo nano /etc/ssh/sshd_config
# PasswordAuthentication yes

# SSHサービス再起動
sudo systemctl restart ssh

# または SSH鍵を追加
ssh-copy-id pi@<raspberry_pi_ip>
```

#### 2. 依存関係インストールエラー

**エラー**: パッケージインストール失敗

**解決方法**:
```bash
# パッケージリストを更新
sudo apt update

# 破損したパッケージを修復
sudo apt --fix-broken install

# 再試行
sudo apt install -y curl jq git
```

#### 3. Claude Code CLI認証エラー

**エラー**: Claude認証失敗

**解決方法**:
```bash
# 認証情報をクリア
claude auth logout

# 再認証
claude auth login

# 認証状態確認
claude auth status
```

#### 4. GitHub API制限エラー

**エラー**: API rate limit exceeded

**解決方法**:
- Personal Access Tokenが正しく設定されているか確認
- API使用量を確認: `gh api rate_limit`
- 必要に応じて監視間隔を調整

#### 5. Docker関連のエラー

**エラー**: Docker build失敗

**解決方法**:
```bash
# Docker daemonの確認
sudo systemctl status docker

# ディスク容量確認
df -h

# 不要なイメージ削除
docker system prune -a
```

#### 6. ログ関連の問題

**エラー**: ログファイルが作成されない

**解決方法**:
```bash
# ログディレクトリの作成
sudo mkdir -p /var/log/claude-automation

# 権限設定
sudo chown -R $USER:$USER /var/log/claude-automation

# ログローテーション確認
sudo logrotate -d /etc/logrotate.d/claude-automation
```

### パフォーマンス最適化

#### メモリ不足の場合

```bash
# スワップファイル作成
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# 永続化
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

#### CPU使用率が高い場合

```bash
# 同時実行数を制限
nano config/repositories.yaml
# max_concurrent: 1

# 監視間隔を延長
# check_interval: 120
```

### ログ分析

#### よく確認すべきログ

```bash
# システムログ
sudo journalctl -u claude-automation -f

# アプリケーションログ
tail -f /var/log/claude-automation/claude-automation.log

# Dockerログ（Docker使用時）
docker-compose logs -f claude-automation

# 特定のエラーを検索
grep -i error /var/log/claude-automation/*.log
grep -i "failed" /var/log/claude-automation/*.log
```

#### ログレベルの調整

```bash
# デバッグレベルでログを出力
export LOG_LEVEL=debug

# または .env ファイルで設定
echo "LOG_LEVEL=debug" >> .env
```

### サポート

問題が解決しない場合：

1. [Issues](https://github.com/your-username/claude-automation/issues)で既存の問題を確認
2. 新しいIssueを作成する際は以下の情報を含める：
   - OS/環境情報
   - エラーメッセージ
   - 関連するログ
   - 実行したコマンド

---

## セキュリティ考慮事項

### 認証情報の管理

- **GitHub Token**: 最小権限で作成
- **環境変数**: `.env`ファイルの権限を600に設定
- **SSH鍵**: 強力なパスフレーズを使用

### ネットワークセキュリティ

- **ファイアウォール**: 必要最小限のポートのみ開放
- **VPN**: 可能な場合はVPN経由でアクセス
- **更新**: 定期的なセキュリティアップデート

### 監査とモニタリング

- **ログ監視**: 異常なアクティビティの検出
- **リソース監視**: CPU/メモリ使用量の監視
- **定期チェック**: ヘルスチェックの自動実行

このデプロイガイドに従うことで、Raspberry PiまたはDocker環境でClaude Automation Systemを安全かつ効率的に運用できます。