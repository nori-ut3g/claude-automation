# Claude DevOps Automation System

GitHub Issue/PR監視とClaude自動実行を基盤とした高度な開発自動化システム

## 概要

Claude DevOps Automation Systemは、GitHubのIssueやPull Requestを監視し、特定のラベルやキーワードを検出すると自動的にClaude Codeを実行してコード生成・PR作成を行うシステムです。

### 主な機能

- 🔍 **複数リポジトリ監視**: 設定ファイルで複数のリポジトリを同時監視
- 🤖 **Claude自動実行**: IssueからのClaude Code実行とPR作成
- 💻 **Terminal自動起動**: Claude Codeの対話的セッションを自動開始
- 💬 **智的な返信**: 議論や分析要求への自動応答
- 🌿 **高度なGitワークフロー**: Git-flow、GitHub Flow対応
- 📊 **ワークスペース管理**: 効率的な作業ディレクトリ管理
- 💬 **Slack連携**: 実行状況の通知とインタラクティブな操作
- 📋 **Jira連携**: チケット作成とステータス同期

## 必要条件

- macOS または Linux
- Bash 4.0以上
- 以下のツールがインストールされていること:
  - Git
  - curl
  - jq
  - yq
  - [Claude Code CLI](https://claude.ai/code)
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
    implementation_keywords: ["@claude-implement", "@claude-fix"]
    reply_keywords: ["@claude-reply", "@claude-discuss"]
    terminal_keywords: ["@claude-terminal", "@claude-interactive"]
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

## 実行モード

システムは3つの実行モードをサポートしています：

### 1. 実装モード（Implementation Mode）

自動的にコードを実装し、Pull Requestを作成します。

**キーワード**: `@claude-implement`, `@claude-create`, `@claude-fix`, `@claude-build`

```markdown
## タイトル
Add user authentication feature

## 本文
@claude-implement

### 要件
- ユーザー登録機能
- ログイン/ログアウト機能
- パスワードのハッシュ化
- セッション管理
```

**処理フロー**:
1. リポジトリをクローン
2. 新しいブランチを作成
3. Claude Codeで自動実装
4. 変更をコミット
5. Pull Requestを自動作成

### 2. Terminal自動起動モード（Terminal Mode）

Claude Codeの対話セッションを新しいTerminalで起動します。

**キーワード**: `@claude-terminal`, `@claude-interactive`, `@claude-visual`

```markdown
## タイトル
Complex refactoring task

## 本文
@claude-terminal

### 作業内容
- 複数ファイルの大規模リファクタリング
- インタラクティブな設計検討が必要
- 段階的な実装とテスト
```

**処理フロー**:
1. リポジトリをクローン
2. 新しいブランチを作成
3. Terminal.appでClaude Codeセッションを起動
4. ワークスペースを保持（自動削除しない）
5. 作業完了後、手動でPR作成

**PR作成**:
```bash
# ワークスペースからPRを作成
./scripts/create-pr.sh /path/to/workspace [issue_number]
```

### 3. 返信モード（Reply Mode）

リポジトリをクローンせずに、Issueに対して直接返信します。

**キーワード**: `@claude-reply`, `@claude-explain`, `@claude-help`, `@claude-discuss`, `@claude-analysis`

```markdown
## タイトル
How to implement caching strategy?

## 本文
@claude-discuss

### 質問
- Redis vs Memcached の選択基準
- キャッシュキーの設計方針
- TTL設定のベストプラクティス
```

**処理フロー**:
1. リポジトリクローンをスキップ
2. Claude Codeで返信を生成
3. GitHub Issueに自動コメント投稿

## ワークスペース管理

### アクティブワークスペースの確認

```bash
# アクティブなワークスペース一覧
cat logs/active_workspaces.json | jq '.'
```

### ワークスペースのクリーンアップ

```bash
# 24時間以上古いワークスペースを削除
./scripts/cleanup-workspaces.sh

# ドライラン（実際には削除しない）
./scripts/cleanup-workspaces.sh --dry-run

# 強制実行（確認なし）
./scripts/cleanup-workspaces.sh --force

# カスタム期間指定（72時間以上古い）
./scripts/cleanup-workspaces.sh --older-than 72
```

## GitHub Issueの書き方

### 基本的な使い方

1. **ラベルを使用**: Issueに `claude-auto` ラベルを付ける
2. **キーワードを使用**: Issue本文に適切なキーワードを含める

### 実装要求の例

```markdown
## タイトル
Add user authentication feature

## ラベル
- claude-auto
- enhancement

## 本文
@claude-implement

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

### 議論・相談の例

```markdown
## タイトル
Architecture decision: microservices vs monolith

## 本文
@claude-discuss

### 背景
現在のシステムをスケールアップする必要があります。

### 検討事項
- 開発チームのサイズ: 5名
- 予想トラフィック: 月1M PV
- 技術的制約: AWS環境、Python/Django

### 質問
どちらのアーキテクチャが適しているでしょうか？
```

### Terminal セッションの例

```markdown
## タイトル
Complex database migration

## 本文
@claude-terminal

### 作業内容
- 大規模なデータベーススキーマ変更
- データマイグレーションスクリプト作成
- 段階的なデプロイ戦略の検討

### 注意事項
- 本番データへの影響を最小限に
- ロールバック戦略も含めて実装
```

## ディレクトリ構造

```
claude-automation/
├── config/                    # 設定ファイル
│   ├── repositories.yaml      # リポジトリ設定
│   ├── integrations.yaml      # 外部サービス設定
│   └── claude-prompts.yaml    # Claudeプロンプト
├── src/
│   ├── core/                  # コアモジュール
│   │   ├── monitor.sh         # メイン監視プロセス
│   │   ├── event-processor.sh # イベント処理
│   │   ├── claude-executor.sh # Claude実行
│   │   ├── claude-reply.sh    # 返信生成
│   │   └── terminal-launcher.sh # Terminal起動
│   ├── integrations/          # 外部サービス連携
│   │   ├── slack-client.sh
│   │   ├── jira-client.sh
│   │   └── github-client.sh
│   └── utils/                 # ユーティリティ
│       ├── logger.sh
│       ├── config-loader.sh
│       └── git-utils.sh
├── scripts/                   # 操作スクリプト
│   ├── start.sh              # システム起動
│   ├── stop.sh               # システム停止
│   ├── health-check.sh       # ヘルスチェック
│   ├── create-pr.sh          # PR作成
│   └── cleanup-workspaces.sh # ワークスペースクリーンアップ
├── logs/                      # ログファイル
│   ├── claude-automation.log  # メインログ
│   ├── terminal_sessions.json # Terminalセッション記録
│   └── active_workspaces.json # アクティブワークスペース
└── workspace/                 # 作業ディレクトリ
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

### Terminal が無限に起動する

この問題は修正済みです。実行履歴管理により重複実行を防止しています。

```bash
# 実行履歴を確認
cat execution_history.json | jq '.'

# 古いワークスペースをクリーンアップ
./scripts/cleanup-workspaces.sh
```

### GitHub API制限

```bash
# レート制限を確認
curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/rate_limit
```

### Claude Code認証エラー

```bash
# Claude Codeの認証状態を確認
claude auth status

# 再認証
claude auth login
```

## 運用のベストプラクティス

### 定期メンテナンス

```bash
# 日次実行推奨
./scripts/cleanup-workspaces.sh --older-than 24

# 週次実行推奨  
./scripts/health-check.sh --verbose
```

### セキュリティ

- GitHubトークンは環境変数で管理
- ログ内の機密情報は自動マスキング
- 最小権限の原則に従った権限設定
- ワークスペースの定期クリーンアップ

### パフォーマンス最適化

- アクティブでないワークスペースの定期削除
- ログローテーションの設定
- モニタリング間隔の調整

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
4. [Claude Code documentation](https://docs.anthropic.com/claude/docs)

---

🤖 **Claude Automation System** - より効率的な開発ワークフローを実現