# Claude Automation System - 運用ガイド

## 目次

1. [システム概要](#システム概要)
2. [初期セットアップ](#初期セットアップ)
3. [日常運用](#日常運用)
4. [監視とアラート](#監視とアラート)
5. [トラブルシューティング](#トラブルシューティング)
6. [メンテナンス](#メンテナンス)
7. [セキュリティ](#セキュリティ)
8. [パフォーマンスチューニング](#パフォーマンスチューニング)

## システム概要

Claude Automation Systemは、GitHub Issue/PRを監視し、自動的にClaude Codeを実行してコード生成・PR作成を行うシステムです。

### アーキテクチャ

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   GitHub API    │◄──►│  Monitor Process │◄──►│   Claude Code   │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  Event Processor │
                    └──────────────────┘
                              │
                    ┌─────────┴─────────┐
                    ▼                   ▼
            ┌──────────────┐    ┌──────────────┐
            │ Slack Client │    │ Jira Client  │
            └──────────────┘    └──────────────┘
```

## 初期セットアップ

### 1. 環境要件

- **OS**: macOS, Linux (Raspberry Pi OS推奨)
- **メモリ**: 最小 2GB RAM
- **ストレージ**: 最小 10GB 空き容量
- **ネットワーク**: インターネット接続必須

### 2. 必要な環境変数

```bash
# 必須
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"

# オプション（Slack連携）
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/xxx/xxx/xxx"

# オプション（Jira連携）
export JIRA_BASE_URL="https://your-domain.atlassian.net"
export JIRA_USERNAME="your-email@example.com"
export JIRA_API_TOKEN="your-jira-api-token"
```

### 3. インストール手順

#### ローカル環境

```bash
# リポジトリのクローン
git clone https://github.com/nori-ut3g/claude-automation.git
cd claude-automation

# 依存関係のインストール
./scripts/install.sh

# 設定ファイルの編集
vim config/repositories.yaml

# システムの起動
./scripts/start.sh --daemon
```

#### Raspberry Pi へのデプロイ

```bash
# 環境変数を設定
export GITHUB_TOKEN="your-token"

# デプロイの実行
./scripts/deploy.sh -t raspberry-pi.local -u pi -s
```

## 日常運用

### システムの起動・停止

```bash
# 起動
sudo systemctl start claude-automation

# 停止
sudo systemctl stop claude-automation

# 再起動
sudo systemctl restart claude-automation

# ステータス確認
sudo systemctl status claude-automation
```

### ヘルスチェック

```bash
# 基本的なヘルスチェック
/opt/claude-automation/scripts/health-check.sh

# 詳細情報付き
/opt/claude-automation/scripts/health-check.sh --verbose

# JSON形式（監視ツール連携用）
/opt/claude-automation/scripts/health-check.sh --json
```

### ログの確認

```bash
# systemd ログ
sudo journalctl -u claude-automation -f

# アプリケーションログ
tail -f /opt/claude-automation/logs/claude-automation.log

# エラーログのみ
grep "ERROR" /opt/claude-automation/logs/claude-automation.log
```

## 監視とアラート

### 監視項目

1. **プロセス監視**
   - Monitor プロセスの死活監視
   - CPU/メモリ使用率

2. **API監視**
   - GitHub API レート制限
   - 接続エラー率

3. **実行監視**
   - Claude実行の成功/失敗率
   - 実行時間

### Prometheus メトリクス（将来実装）

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'claude-automation'
    static_configs:
      - targets: ['localhost:9090']
```

### アラート設定

Slack通知が自動的に以下の場合に送信されます：

- Claude実行エラー
- システムエラー
- API レート制限到達

## トラブルシューティング

### よくある問題と解決方法

#### 1. システムが起動しない

```bash
# ログを確認
sudo journalctl -u claude-automation -n 100

# 設定の検証
/opt/claude-automation/scripts/health-check.sh --verbose

# 環境変数の確認
grep GITHUB_TOKEN /opt/claude-automation/.env
```

#### 2. GitHub API エラー

**症状**: "API rate limit exceeded" エラー

**解決方法**:
```bash
# レート制限の確認
curl -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/rate_limit

# 監視間隔を調整
vim /opt/claude-automation/config/repositories.yaml
# check_interval: 120  # 60秒から120秒に変更
```

#### 3. Claude実行が失敗する

**症状**: Claude実行がタイムアウトまたはエラー

**解決方法**:
```bash
# 実行履歴の確認
cat /opt/claude-automation/execution_history.json | jq .

# ワークスペースのクリーンアップ
rm -rf /opt/claude-automation/workspace/*

# ロックファイルの削除
rm -rf /opt/claude-automation/locks/*
```

### デバッグモード

```bash
# 詳細ログを有効化
export LOG_LEVEL="DEBUG"

# フォアグラウンドで実行
/opt/claude-automation/scripts/start.sh --verbose
```

## メンテナンス

### 定期メンテナンスタスク

#### 日次タスク

1. **ログの確認**
   ```bash
   # エラーログの確認
   grep -c ERROR /opt/claude-automation/logs/claude-automation.log
   ```

2. **ディスク容量の確認**
   ```bash
   df -h /opt/claude-automation
   du -sh /opt/claude-automation/workspace
   ```

#### 週次タスク

1. **古いワークスペースのクリーンアップ**
   ```bash
   find /opt/claude-automation/workspace -type d -mtime +7 -exec rm -rf {} +
   ```

2. **実行履歴のアーカイブ**
   ```bash
   cp /opt/claude-automation/execution_history.json \
      /opt/claude-automation/execution_history_$(date +%Y%m%d).json
   ```

#### 月次タスク

1. **システムアップデート**
   ```bash
   cd /opt/claude-automation
   git pull origin main
   sudo systemctl restart claude-automation
   ```

2. **依存関係の更新**
   ```bash
   sudo apt-get update
   sudo apt-get upgrade
   ```

### バックアップとリストア

#### バックアップ

```bash
#!/bin/bash
# backup.sh

BACKUP_DIR="/backup/claude-automation"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 設定ファイルのバックアップ
tar -czf "$BACKUP_DIR/config_$TIMESTAMP.tar.gz" \
  /opt/claude-automation/config \
  /opt/claude-automation/.env

# 実行履歴のバックアップ
cp /opt/claude-automation/execution_history.json \
   "$BACKUP_DIR/execution_history_$TIMESTAMP.json"
```

#### リストア

```bash
#!/bin/bash
# restore.sh

BACKUP_FILE=$1

# サービスの停止
sudo systemctl stop claude-automation

# バックアップからリストア
tar -xzf "$BACKUP_FILE" -C /

# サービスの起動
sudo systemctl start claude-automation
```

## セキュリティ

### セキュリティベストプラクティス

1. **最小権限の原則**
   - GitHub トークンは必要最小限の権限のみ付与
   - システムユーザーは非特権ユーザーを使用

2. **秘密情報の管理**
   - 環境変数はファイルで管理（`.env`）
   - ファイル権限は 600 に設定
   - ログ内の秘密情報は自動マスキング

3. **ネットワークセキュリティ**
   - アウトバウンドのみ許可
   - 不要なポートは閉じる

### GitHub トークンの権限

必要最小限の権限：
- `repo` - リポジトリへのフルアクセス
- `workflow` - GitHub Actions ワークフローの実行（オプション）

### 監査ログ

すべての実行は記録されます：
```bash
# 実行履歴の確認
jq '.[] | select(.status == "failed")' \
  /opt/claude-automation/execution_history.json
```

## パフォーマンスチューニング

### システムリソース

#### メモリ使用量の最適化

```bash
# 現在のメモリ使用量
ps aux | grep monitor.sh

# スワップの設定（Raspberry Pi）
sudo dphys-swapfile swapoff
sudo nano /etc/dphys-swapfile
# CONF_SWAPSIZE=2048
sudo dphys-swapfile setup
sudo dphys-swapfile swapon
```

#### CPU使用率の調整

```yaml
# config/repositories.yaml
default_settings:
  check_interval: 120  # 監視間隔を増やす
  max_concurrent: 2    # 同時実行数を減らす
```

### ネットワーク最適化

#### API呼び出しの削減

1. **キャッシュの活用**
   ```bash
   # 設定のキャッシュ（自動）
   # 状態ファイルの活用
   ```

2. **バッチ処理**
   - 複数のリポジトリをまとめてチェック
   - API呼び出しを最小化

### ログローテーション

```bash
# /etc/logrotate.d/claude-automation
/opt/claude-automation/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
}
```

## 高度な設定

### カスタムプロンプト

```yaml
# config/claude-prompts.yaml
custom_prompts:
  code_review:
    prompt: |
      以下の観点でコードをレビューしてください：
      - セキュリティ
      - パフォーマンス
      - 可読性
```

### Webhook設定（将来実装）

```yaml
# config/webhooks.yaml
webhooks:
  - url: "https://your-webhook.com/claude-events"
    events: ["execution_complete", "execution_error"]
    secret: "your-webhook-secret"
```

## サポート

問題が発生した場合：

1. [トラブルシューティング](#トラブルシューティング)を確認
2. ログファイルを確認
3. [GitHub Issues](https://github.com/nori-ut3g/claude-automation/issues)に報告

---

最終更新: 2025-05-25