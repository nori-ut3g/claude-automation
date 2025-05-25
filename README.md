# Claude DevOps Automation System

GitHub Issue/PR監視とClaude自動実行を基盤とした高度な開発自動化システム

## 概要

Claude DevOps Automation Systemは、GitHubのIssueやPull Requestを監視し、特定のラベルやキーワードを検出すると自動的にClaude Codeを実行してコード生成・PR作成を行うシステムです。

### 主な機能

- 🔍 **複数リポジトリ監視**: 設定ファイルで複数のリポジトリを同時監視
- 🤖 **Claude自動実行**: IssueからのClaude Code実行とPR作成
- 🌿 **高度なGitワークフロー**: Git-flow、GitHub Flow対応
- 💬 **Slack連携**: 実行状況の通知とインタラクティブな操作
- 📋 **Jira連携**: チケット作成とステータス同期
- 📊 **ヘルスチェック**: システム状態の監視

## 必要条件

- macOS または Linux
- Bash 4.0以上
- 以下のツールがインストールされていること:
  - Git
  - curl
  - jq
  - yq
- GitHub Personal Access Token
- Claude API アクセス（Claude Max Plan推奨）

## インストール

### 1. リポジトリのクローン

```bash
git clone https://github.com/your-username/claude-automation.git
cd claude-automation
```

### 2. 依存関係のインストール

```bash
./scripts/install.sh
```

### 3. 環境変数の設定

```bash
export GITHUB_TOKEN="your-github-personal-access-token"
export SLACK_WEBHOOK_URL="your-slack-webhook-url"  # オプション
export JIRA_BASE_URL="https://your-domain.atlassian.net"  # オプション
export JIRA_USERNAME="your-email@example.com"  # オプション
export JIRA_API_TOKEN="your-jira-api-token"  # オプション
```

### 4. 設定ファイルの編集

#### `config/repositories.yaml`

監視するリポジトリとその設定を定義します:

```yaml
repositories:
  - name: "your-org/your-repo"
    enabled: true
    labels: ["claude-auto"]
    keywords: ["@claude-execute"]
    branch_strategy: "github-flow"
    base_branch: "main"
```

## 使い方

### システムの起動

```bash
# フォアグラウンドで実行
./scripts/start.sh

# バックグラウンドで実行
./scripts/start.sh --daemon

# 詳細ログ付きで実行
./scripts/start.sh --verbose
```

### システムの停止

```bash
# グレースフルシャットダウン
./scripts/stop.sh

# 強制終了
./scripts/stop.sh --force
```

### ヘルスチェック

```bash
# 基本的な状態確認
./scripts/health-check.sh

# 詳細情報付き
./scripts/health-check.sh --verbose

# JSON形式で出力（監視ツール向け）
./scripts/health-check.sh --json
```

## GitHub Issueの書き方

### 自動実行をトリガーする方法

1. **ラベルを使用**: Issueに `claude-auto` ラベルを付ける
2. **キーワードを使用**: Issue本文に `@claude-execute` を含める

### Issue例

```markdown
## タイトル
Add user authentication feature

## ラベル
- claude-auto
- enhancement

## 本文
@claude-execute

### 要件
- ユーザー登録機能
- ログイン/ログアウト機能
- パスワードのハッシュ化
- セッション管理

### 技術仕様
- Express.jsを使用
- bcryptでパスワードハッシュ化
- JWTトークンでセッション管理
```

## ディレクトリ構造

```
claude-automation/
├── config/                 # 設定ファイル
│   ├── repositories.yaml   # リポジトリ設定
│   ├── integrations.yaml   # 外部サービス設定
│   └── claude-prompts.yaml # Claudeプロンプト
├── src/
│   ├── core/              # コアモジュール
│   │   ├── monitor.sh     # メイン監視プロセス
│   │   ├── event-processor.sh
│   │   └── claude-executor.sh
│   ├── integrations/      # 外部サービス連携
│   │   ├── slack-client.sh
│   │   └── jira-client.sh
│   └── utils/             # ユーティリティ
│       ├── logger.sh
│       ├── config-loader.sh
│       └── git-utils.sh
├── scripts/               # 操作スクリプト
├── logs/                  # ログファイル
└── workspace/             # 作業ディレクトリ
```

## 高度な設定

### Git-flow対応

```yaml
repositories:
  - name: "your-org/your-repo"
    branch_strategy: "gitflow"
    base_branch: "develop"
    labels: ["claude-auto"]
```

### 複数Organization監視

```yaml
organizations:
  - name: "your-organization"
    enabled: true
    exclude_repos: ["legacy-*", "test-*"]
    default_labels: ["claude-auto"]
```

### カスタムプロンプト

`config/claude-prompts.yaml`でClaude実行時のプロンプトをカスタマイズできます。

## トラブルシューティング

### システムが起動しない

```bash
# 環境をチェック
./scripts/health-check.sh --verbose

# ログを確認
tail -f logs/claude-automation.log
```

### GitHub API制限

```bash
# レート制限を確認
curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/rate_limit
```

## セキュリティ

- GitHubトークンは環境変数で管理
- ログ内の機密情報は自動マスキング
- 最小権限の原則に従った権限設定

## ライセンス

MIT License

## コントリビューション

Issues、Pull Requestsは歓迎します。
大きな変更を行う場合は、まずIssueで議論してください。

## サポート

問題が発生した場合は、以下をご確認ください:

1. [トラブルシューティング](#トラブルシューティング)セクション
2. GitHubのIssuesページ
3. ログファイル（`logs/`ディレクトリ）