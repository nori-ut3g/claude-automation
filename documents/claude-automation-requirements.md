# Claude自動化システム開発要件書

## プロジェクト概要

GitHub Issue/PR監視とClaude自動実行を基盤とした、高度な開発自動化システムの構築

**プロジェクト名**: Claude DevOps Automation System  
**バージョン**: v2.0  
**作成日**: 2025-05-25  
**対象環境**: Mac（開発）→ Raspberry Pi（本番）

---

## 1. 機能要件

### 1.1 基本監視機能（実装済み拡張）

#### 1.1.1 複数リポジトリ監視
- [ ] 設定ファイルによる監視対象リポジトリ管理
- [ ] GitHub Organization全体の自動検出・監視
- [ ] リポジトリ別の設定カスタマイズ
- [ ] 動的なリポジトリ追加・削除

**技術仕様**:
```yaml
repositories:
  - name: "nori-ut3g/project-a"
    labels: ["claude-auto", "enhancement"]
    keywords: ["@claude-implement", "@claude-fix"]
    branch_strategy: "gitflow"
  - name: "nori-ut3g/project-b"
    labels: ["claude-auto"]
    keywords: ["@claude-execute"]
    branch_strategy: "github-flow"
organizations:
  - name: "your-organization"
    exclude: ["legacy-project", "archived-repo"]
```

#### 1.1.2 GitHub イベント監視拡張
- [ ] **Issue監視**: 複数ラベル・キーワード対応
- [ ] **Pull Request監視**: 新規PR、更新PR、レビュー要求
- [ ] **Release監視**: 新しいリリース作成時の自動対応
- [ ] **Security Alert監視**: 脆弱性検出時の自動修正
- [ ] **Workflow失敗監視**: CI/CD失敗時の自動デバッグ

**対応イベント**:
- `issues.opened`, `issues.labeled`, `issue_comment.created`
- `pull_request.opened`, `pull_request.synchronize`, `pull_request_review.submitted`
- `release.published`, `release.prereleased`
- `repository_vulnerability_alert.create`
- `workflow_run.failed`, `check_run.failed`

#### 1.1.3 高度なGitワークフロー
- [ ] **Git-flow対応**: feature/bugfix/hotfix/release ブランチ戦略
- [ ] **GitHub Flow対応**: シンプルなmainブランチベース
- [ ] **自動ブランチ命名**: Issue番号、タイプ、日時ベース
- [ ] **マルチベースブランチ**: develop, main, release/* への対応

**ブランチ戦略ロジック**:
```
Issue ラベル判定:
- "hotfix", "critical", "urgent" → hotfix/claude-auto-issue-{number}
- "bug", "fix" → bugfix/claude-auto-issue-{number}  
- "feature", "enhancement" → feature/claude-auto-issue-{number}
- その他 → タイトル内容で判定
```

### 1.2 外部サービス連携

#### 1.2.1 Slack連携
- [ ] **通知機能**: 実行開始、完了、エラー通知
- [ ] **インタラクティブ機能**: Slackからの承認・却下
- [ ] **スレッド機能**: 関連する通知のスレッド化
- [ ] **カスタム通知**: チャンネル別、チーム別設定

**Slack通知シナリオ**:
1. **実行開始通知**:
   ```
   🤖 Claude自動実行開始
   📋 Issue: #123 - 新機能追加
   🔗 リポジトリ: project-a
   ⏰ 開始時刻: 2025-05-25 22:30:00
   ```

2. **完了通知**:
   ```
   ✅ Claude自動実行完了
   📋 Issue: #123 - 新機能追加  
   🔗 作成PR: #456
   ⏱️ 実行時間: 5分30秒
   👀 レビュー依頼: @developer-team
   ```

3. **エラー通知**:
   ```
   ❌ Claude自動実行エラー
   📋 Issue: #123 - 新機能追加
   🚨 エラー: Claude実行タイムアウト
   🔧 対応: 手動確認が必要
   ```

**インタラクション**:
- ✅ 承認 / ❌ 却下 ボタン
- 🔄 再実行 / ⏸️ 一時停止 ボタン
- 📋 詳細確認 / 🔗 GitHub へ移動 ボタン

#### 1.2.2 Jira連携
- [ ] **自動チケット作成**: GitHub Issue → Jira チケット
- [ ] **ステータス同期**: GitHub PR状態 ↔ Jira チケット状態
- [ ] **コメント同期**: 両方向のコメント同期
- [ ] **時間記録**: Claude実行時間の自動記録

**Jira連携フロー**:
```
GitHub Issue作成 
→ Jira チケット自動作成
→ Claude実行開始
→ Jira「進行中」に更新
→ PR作成完了  
→ Jira「レビュー待ち」に更新
→ PR マージ
→ Jira「完了」に更新
```

**Jira フィールドマッピング**:
- GitHub Issue タイトル → Jira Summary
- GitHub Issue 本文 → Jira Description  
- GitHub ラベル → Jira Labels/Components
- GitHub Assignee → Jira Assignee
- Claude実行時間 → Jira Time Tracking

### 1.3 高度なClaude実行機能

#### 1.3.1 コンテキスト分析強化
- [ ] **プロジェクト構造分析**: 自動的なアーキテクチャ理解
- [ ] **依存関係分析**: package.json, requirements.txt等の解析
- [ ] **コーディング規約検出**: 既存コードからの規約学習
- [ ] **テスト戦略判定**: 既存テストパターンの分析

#### 1.3.2 マルチステップ実行
- [ ] **段階的実装**: 設計→実装→テスト→ドキュメント
- [ ] **中間レビュー**: 各段階でのレビューポイント挿入
- [ ] **ロールバック機能**: 問題発生時の自動復旧
- [ ] **並列実行**: 複数Issue の同時処理

#### 1.3.3 品質保証機能
- [ ] **自動テスト実行**: 実装後の自動テスト実行
- [ ] **静的解析**: ESLint, SonarQube等との連携
- [ ] **セキュリティスキャン**: 脆弱性の自動検出
- [ ] **パフォーマンステスト**: 基本的な性能測定

---

## 2. 非機能要件

### 2.1 性能要件
- **応答時間**: GitHub イベント検出から5分以内の実行開始
- **同時実行**: 最大3つのClaude タスク同時実行
- **監視間隔**: リポジトリあたり60秒間隔
- **リソース使用量**: Raspberry Pi 4B (4GB) で安定動作

### 2.2 可用性要件
- **稼働率**: 99%以上（月間約7時間停止許容）
- **自動復旧**: プロセス異常終了時の自動再起動
- **ログ保持**: 30日間のログ保持
- **バックアップ**: 設定ファイルの日次バックアップ

### 2.3 セキュリティ要件
- **認証**: GitHub Token, Slack Token, Jira API Token の安全な管理
- **権限**: 最小権限の原則（必要な権限のみ付与）
- **ログ**: 機密情報のマスキング
- **通信**: HTTPS/TLS での外部API通信

### 2.4 保守性要件
- **設定**: YAML/JSON による外部設定ファイル
- **モジュール**: 機能別のスクリプト分割
- **ログレベル**: DEBUG, INFO, WARN, ERROR レベル対応
- **モニタリング**: Slack/メール での異常通知

---

## 3. システム設計要件

### 3.1 アーキテクチャ
```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   GitHub API    │◄──►│  Main Monitor    │◄──►│   Claude Code   │
└─────────────────┘    │     Process      │    └─────────────────┘
                       └──────────────────┘
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

### 3.2 ディレクトリ構造
```
claude-automation-system/
├── config/
│   ├── repositories.yaml     # 監視対象設定
│   ├── integrations.yaml     # 外部サービス設定
│   └── claude-prompts.yaml   # Claude プロンプトテンプレート
├── src/
│   ├── core/
│   │   ├── monitor.sh        # メイン監視プロセス
│   │   ├── event-processor.sh # イベント処理
│   │   └── claude-executor.sh # Claude実行管理
│   ├── integrations/
│   │   ├── slack-client.sh   # Slack連携
│   │   ├── jira-client.sh    # Jira連携
│   │   └── github-client.sh  # GitHub API拡張
│   ├── utils/
│   │   ├── logger.sh         # ログ機能
│   │   ├── config-loader.sh  # 設定読み込み
│   │   └── git-utils.sh      # Git操作ユーティリティ
│   └── templates/
│       ├── pr-template.md    # PR テンプレート
│       └── issue-template.md # Issue テンプレート
├── scripts/
│   ├── install.sh           # インストールスクリプト
│   ├── start.sh             # 開始スクリプト
│   ├── stop.sh              # 停止スクリプト
│   └── health-check.sh      # ヘルスチェック
├── logs/                    # ログディレクトリ
├── workspace/               # 作業ディレクトリ
└── tests/                   # テストスクリプト
```

### 3.3 設定ファイル仕様

#### repositories.yaml
```yaml
default_settings:
  check_interval: 60
  max_concurrent: 3
  branch_strategy: "github-flow"
  base_branch: "main"

repositories:
  - name: "nori-ut3g/claude-automation-test"
    enabled: true
    labels: ["claude-auto"]
    keywords: ["@claude-execute", "@claude-implement"]
    branch_strategy: "gitflow"
    base_branch: "main"
    develop_branch: "develop"
    slack_channel: "#dev-automation"
    jira_project: "AUTO"
    
organizations:
  - name: "your-organization"
    enabled: false
    exclude_repos: ["legacy-*", "archive-*"]
    default_labels: ["claude-auto"]
```

#### integrations.yaml
```yaml
slack:
  enabled: true
  webhook_url: "${SLACK_WEBHOOK_URL}"
  default_channel: "#claude-automation"
  channels:
    error: "#claude-errors"
    success: "#claude-success"
    review: "#dev-team"
  mention_users:
    - "@developer-team"
    - "@devops-team"

jira:
  enabled: true
  base_url: "${JIRA_BASE_URL}"
  username: "${JIRA_USERNAME}"
  api_token: "${JIRA_API_TOKEN}"
  default_project: "DEV"
  issue_type: "Task"
  labels: ["claude-automated"]
  
github:
  token: "${GITHUB_TOKEN}"
  api_base: "https://api.github.com"
  max_retries: 3
  rate_limit_wait: 60
```

---

## 4. 実装計画

### Phase 1: 基盤拡張（Week 1-2）
- [ ] 複数リポジトリ監視の実装
- [ ] 設定ファイルシステムの構築
- [ ] 高度なGitワークフロー対応
- [ ] ログ・エラーハンドリング強化

### Phase 2: Slack連携（Week 3）
- [ ] Slack Webhook 通知機能
- [ ] インタラクティブボタン実装
- [ ] カスタムチャンネル設定
- [ ] エラー通知・アラート機能

### Phase 3: Jira連携（Week 4）
- [ ] Jira API クライアント実装
- [ ] チケット自動作成・更新
- [ ] ステータス同期機能
- [ ] 時間記録・コメント同期

### Phase 4: 品質向上（Week 5-6）
- [ ] 自動テスト実行機能
- [ ] パフォーマンス監視
- [ ] セキュリティ強化
- [ ] 本格運用設定

### Phase 5: 本番デプロイ（Week 7）
- [ ] Raspberry Pi 環境構築
- [ ] systemd サービス化
- [ ] 監視・アラート設定
- [ ] 運用ドキュメント整備

---

## 5. 受け入れ基準

### 5.1 基本機能
- ✅ 複数リポジトリの同時監視
- ✅ Issue/PR イベントの確実な検出
- ✅ Claude自動実行とPR作成
- ✅ エラー時の適切な通知

### 5.2 Slack連携
- ✅ 実行開始・完了・エラーの通知
- ✅ インタラクティブボタンでの操作
- ✅ チャンネル・ユーザー別設定
- ✅ 通知内容のカスタマイズ

### 5.3 Jira連携
- ✅ GitHub Issue → Jira チケット自動作成
- ✅ PR状態とJiraステータス同期
- ✅ 実行時間の自動記録
- ✅ 双方向コメント同期

### 5.4 運用面
- ✅ 24/7 安定動作（Raspberry Pi）
- ✅ 設定変更の即座反映
- ✅ ログ・監視体制の整備
- ✅ 障害時の自動復旧

---

## 6. 参考資料

### API ドキュメント
- [GitHub REST API](https://docs.github.com/en/rest)
- [GitHub GraphQL API](https://docs.github.com/en/graphql)
- [Slack Web API](https://api.slack.com/web)
- [Jira REST API](https://developer.atlassian.com/cloud/jira/platform/rest/v3/)

### Claude Code
- [Claude Code Documentation](https://docs.anthropic.com/claude-code)
- [Max Plan Usage](https://support.anthropic.com/claude-max-plan)

### インフラ
- [Raspberry Pi OS Setup](https://www.raspberrypi.org/software/)
- [systemd Service](https://www.freedesktop.org/software/systemd/man/systemd.service.html)

---

**この要件書に基づき、Claude Codeで段階的にシステムを実装していきます。**