# Claude Automation System - 動作テスト手順

## 1. 環境準備

### GitHub Token の設定
```bash
# GitHub Personal Access Token を設定
export GITHUB_TOKEN='your-github-personal-access-token'

# トークンの権限:
# - repo (Full control of private repositories)
# - workflow (Update GitHub Action workflows) ※オプション
```

### GitHub CLI の認証（Issueを作成する場合）
```bash
# GitHub CLI をインストール
brew install gh

# 認証
gh auth login
```

## 2. システムの起動

### フォアグラウンドで実行（ログを確認したい場合）
```bash
cd /Users/nori/claude-project/claude-automation
./scripts/start.sh --verbose
```

### バックグラウンドで実行
```bash
cd /Users/nori/claude-project/claude-automation
./scripts/start.sh --daemon
```

## 3. テスト Issue の作成

### 方法1: 付属のスクリプトを使用
```bash
./test-issue.sh
```

### 方法2: GitHub CLI で手動作成
```bash
gh issue create \
  --repo nori-ut3g/claude-automation \
  --title "Test: Add sample feature" \
  --body "@claude-execute
  
  Please implement a sample feature." \
  --label "claude-auto"
```

### 方法3: GitHub Web UI から作成
1. https://github.com/nori-ut3g/claude-automation/issues/new
2. タイトル: 任意
3. 本文に `@claude-execute` を含める
4. ラベル `claude-auto` を追加

## 4. 動作確認

### ログの確認
```bash
# アプリケーションログ
tail -f logs/claude-automation.log

# システムログ（デーモンモード）
tail -f logs/daemon.log
```

### プロセスの確認
```bash
# ヘルスチェック
./scripts/simple-health-check.sh

# プロセス確認
ps aux | grep monitor.sh
```

### 作成されたPRの確認
```bash
# GitHub CLI
gh pr list --repo nori-ut3g/claude-automation

# Web
# https://github.com/nori-ut3g/claude-automation/pulls
```

## 5. システムの停止

```bash
./scripts/stop.sh
```

## トラブルシューティング

### "API rate limit exceeded" エラー
- 監視間隔を増やす: `config/repositories.yaml` の `check_interval` を調整

### Claude実行がシミュレーションになる
- 現在の実装では、実際のClaude APIの代わりにシミュレーション実装
- `src/core/claude-executor.sh` の `execute_claude` 関数を確認

### Bash バージョンエラー
- macOS標準のBash 3.xに対応済み
- 新しいBashが必要な場合: `brew install bash`

## 注意事項

1. **テスト環境での実行を推奨**
   - 本番リポジトリでの実行前に、テストリポジトリで動作確認

2. **Claude実行の制限**
   - 現在はシミュレーション実装
   - 実際のClaude APIを使用する場合は実装の更新が必要

3. **セキュリティ**
   - GitHub Tokenは環境変数で管理
   - ログには機密情報が含まれないよう自動マスキング