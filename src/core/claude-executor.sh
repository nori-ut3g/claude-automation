#!/usr/bin/env bash

# claude-executor.sh - Claude Codeを実行してコード生成・PR作成を管理
# 
# 使用方法:
#   echo "$execution_params" | ./src/core/claude-executor.sh

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/git-utils.sh"
source "${CLAUDE_AUTO_HOME}/src/integrations/github-client.sh"

# 定数
readonly WORKSPACE_BASE="${CLAUDE_AUTO_HOME}/workspace"
readonly CLAUDE_LOG_DIR="${CLAUDE_AUTO_HOME}/logs/claude"
readonly MAX_EXECUTION_TIME=600  # 10分

# グローバル変数
EXECUTION_PARAMS=""
WORKSPACE_DIR=""
EXECUTION_ID=""
EXECUTION_MODE="batch"  # batch, terminal, interactive

# 初期化
initialize() {
    # 実行パラメータを標準入力から読み込み
    EXECUTION_PARAMS=$(cat)
    
    # 実行IDの生成
    EXECUTION_ID=$(date +%s)_$$
    
    # ログディレクトリの作成
    mkdir -p "$CLAUDE_LOG_DIR"
    
    # ワークスペースディレクトリの作成
    mkdir -p "$WORKSPACE_BASE"
    
    # ワークスペースの権限確認
    if [[ ! -w "$WORKSPACE_BASE" ]]; then
        log_error "Workspace directory is not writable: $WORKSPACE_BASE"
        return 1
    fi
    
    log_info "Claude executor initialized (ID: $EXECUTION_ID)"
}

# 実行パラメータの解析
parse_execution_params() {
    # パラメータから必要な情報を抽出
    EVENT_TYPE=$(echo "$EXECUTION_PARAMS" | jq -r '.event_type')
    REPOSITORY=$(echo "$EXECUTION_PARAMS" | jq -r '.repository')
    
    case "$EVENT_TYPE" in
        "issue")
            ISSUE_NUMBER=$(echo "$EXECUTION_PARAMS" | jq -r '.issue_number')
            ISSUE_TITLE=$(echo "$EXECUTION_PARAMS" | jq -r '.issue_title')
            ISSUE_BODY=$(echo "$EXECUTION_PARAMS" | jq -r '.issue_body')
            ISSUE_LABELS=$(echo "$EXECUTION_PARAMS" | jq -r '.issue_labels // ""')
            BRANCH_NAME=$(echo "$EXECUTION_PARAMS" | jq -r '.branch_name')
            BASE_BRANCH=$(echo "$EXECUTION_PARAMS" | jq -r '.base_branch')
            
            # 実行モードの取得（JSONパラメータから）
            local json_execution_mode
            json_execution_mode=$(echo "$EXECUTION_PARAMS" | jq -r '.execution_mode // ""')
            if [[ -n "$json_execution_mode" ]]; then
                EXECUTION_MODE="$json_execution_mode"
            fi
            ;;
        "pull_request")
            PR_NUMBER=$(echo "$EXECUTION_PARAMS" | jq -r '.pr_number')
            PR_TITLE=$(echo "$EXECUTION_PARAMS" | jq -r '.pr_title')
            PR_BODY=$(echo "$EXECUTION_PARAMS" | jq -r '.pr_body')
            PR_BRANCH=$(echo "$EXECUTION_PARAMS" | jq -r '.pr_branch')
            ;;
        *)
            log_error "Unknown event type: $EVENT_TYPE"
            return 1
            ;;
    esac
}

# リポジトリのセットアップ
setup_repository() {
    # 返信のみモードの場合はクローン不要
    if [[ "$EXECUTION_MODE" == "reply" ]]; then
        log_info "Reply mode - skipping repository clone"
        WORKSPACE_DIR=""  # ワークスペースなし
        return 0
    fi
    
    local repo_url="https://github.com/${REPOSITORY}.git"
    
    # 適切なワークスペースディレクトリ名を生成
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local sanitized_repo=${REPOSITORY//\//_}
    WORKSPACE_DIR="${WORKSPACE_BASE}/${timestamp}_${sanitized_repo}"
    
    log_info "Setting up repository: $REPOSITORY in $WORKSPACE_DIR"
    
    # GitHubトークンの設定
    setup_github_auth || return 1
    
    # リポジトリをクローン
    if ! git_clone_repo "$repo_url" "$WORKSPACE_DIR"; then
        log_error "Failed to clone repository"
        return 1
    fi
    
    cd "$WORKSPACE_DIR" || return 1
    
    # Issue処理の場合は新しいブランチを作成
    if [[ "$EVENT_TYPE" == "issue" ]]; then
        if ! git_create_branch "$BRANCH_NAME" "$BASE_BRANCH" "$WORKSPACE_DIR"; then
            log_error "Failed to create branch: $BRANCH_NAME"
            return 1
        fi
    fi
    
    return 0
}

# Claudeプロンプトの生成
generate_claude_prompt() {
    local prompt_template=""
    local final_prompt=""
    
    case "$EVENT_TYPE" in
        "issue")
            # Issue解析用プロンプト
            local analyze_template
            analyze_template=$(get_prompt_template "base_prompts.analyze_issue" "claude-prompts")
            
            # タスクタイプの判定
            local task_type="feature"
            if [[ "$ISSUE_TITLE" =~ [Bb]ug|[Ff]ix ]]; then
                task_type="bugfix"
            elif [[ "$ISSUE_TITLE" =~ [Hh]otfix|[Cc]ritical|[Uu]rgent ]]; then
                task_type="hotfix"
            fi
            
            # 実装用プロンプト
            local implement_template
            implement_template=$(get_prompt_template "task_prompts.${task_type}.implementation" "claude-prompts")
            
            # プロンプトの構築
            final_prompt="${analyze_template}"
            final_prompt="${final_prompt//\{repository\}/$REPOSITORY}"
            final_prompt="${final_prompt//\{issue_number\}/$ISSUE_NUMBER}"
            final_prompt="${final_prompt//\{issue_title\}/$ISSUE_TITLE}"
            final_prompt="${final_prompt//\{issue_body\}/$ISSUE_BODY}"
            
            # プロジェクト構造の解析を追加
            local structure_prompt
            structure_prompt=$(get_prompt_template "context_prompts.understand_structure" "claude-prompts")
            
            # ディレクトリ構造を取得
            local directory_tree
            directory_tree=$(find . -type f -name "*.md" -o -name "*.json" -o -name "*.yaml" -o -name "*.yml" \
                -o -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" -o -name "*.java" | \
                grep -v node_modules | grep -v .git | sort)
            
            structure_prompt="${structure_prompt//\{directory_tree\}/$directory_tree}"
            
            final_prompt="${final_prompt}\n\n${structure_prompt}\n\n${implement_template}"
            ;;
            
        "pull_request")
            # PRレビュー用プロンプト
            prompt_template=$(get_prompt_template "review_prompts.code_review" "claude-prompts")
            
            # 変更内容を取得
            local changes
            changes=$(git diff origin/main...HEAD)
            
            final_prompt="${prompt_template}"
            final_prompt="${final_prompt//\{changes\}/$changes}"
            ;;
    esac
    
    echo "$final_prompt"
}

# Claude実行
execute_claude() {
    local prompt=$1
    local claude_log="${CLAUDE_LOG_DIR}/claude_${EXECUTION_ID}.log"
    
    log_info "Executing Claude Code..."
    
    # プロンプトファイルの作成
    local prompt_file
    if [[ -n "$WORKSPACE_DIR" ]]; then
        prompt_file="${WORKSPACE_DIR}/.claude_prompt"
    else
        # Reply mode - use temporary directory
        prompt_file="${CLAUDE_LOG_DIR}/.claude_prompt_${EXECUTION_ID}"
    fi
    
    # より詳細なプロンプトを作成
    local detailed_prompt
    detailed_prompt="I am working on a GitHub issue that needs to be addressed. Here are the details:

Repository: $REPOSITORY
Issue #$ISSUE_NUMBER: $ISSUE_TITLE

Issue Description:
$ISSUE_BODY

Please help me implement the solution for this issue. I'm currently in the project workspace and have access to all the files. Please analyze the request and implement the necessary changes.

If you need to see the current project structure, create files, or make modifications, please go ahead and do so. I'm ready to work on this with you."

    # プロンプトをファイルに保存
    echo "$detailed_prompt" > "$prompt_file"
    
    # プロンプトファイルの確認
    if [[ ! -f "$prompt_file" ]]; then
        log_error "Failed to create prompt file: $prompt_file"
        return 1
    fi
    
    log_info "Prompt file created: $prompt_file ($(wc -c < "$prompt_file") bytes)"
    
    # タイムアウト付きでClaude実行
    local start_time=$(date +%s)
    
    # 実際のClaude Code実行
    log_info "Running Claude Code in workspace: ${WORKSPACE_DIR:-'(reply mode)'}"
    log_info "Prompt file: $prompt_file"
    
    # Command construction - Claude requires prompt as argument, not stdin
    local claude_command
    if [[ -n "$WORKSPACE_DIR" ]]; then
        claude_command="cd '$WORKSPACE_DIR' && claude --print \"\$(cat '$prompt_file')\""
    else
        claude_command="claude --print \"\$(cat '$prompt_file')\""
    fi
    
    log_info "Command: $claude_command"
    log_info "Timeout: $MAX_EXECUTION_TIME seconds"
    
    # プロンプトファイルを使ってClaude Codeを実行（非対話モード）
    if timeout $MAX_EXECUTION_TIME bash -c "$claude_command" > "$claude_log" 2>&1; then
        log_info "Claude Code execution successful"
        
        # 実行時間の記録
        local end_time=$(date +%s)
        local execution_time=$((end_time - start_time))
        log_info "Claude execution completed in ${execution_time} seconds"
        
        # Claudeの出力をログに記録
        log_info "Claude output logged to: $claude_log"
        
        return 0
    else
        local exit_code=$?
        log_error "Claude Code execution failed (exit code: $exit_code)"
        
        # エラーログを表示
        if [[ -f "$claude_log" ]]; then
            log_error "Claude error output:"
            tail -20 "$claude_log" | while read -r line; do
                log_error "  $line"
            done
        else
            log_error "No log file was created at: $claude_log"
            log_error "This might indicate a command execution failure"
        fi
        
        # 追加のデバッグ情報
        log_error "Failed command: $claude_command"
        log_error "Working directory: $(pwd)"
        log_error "Prompt file exists: $([[ -f "$prompt_file" ]] && echo "yes" || echo "no")"
        
        return $exit_code
    fi
}

# サンプル実装の作成（開発用）
create_sample_implementation() {
    # 新しい機能ファイルを作成
    local feature_file="${WORKSPACE_DIR}/src/new_feature.sh"
    mkdir -p "$(dirname "$feature_file")"
    
    cat > "$feature_file" <<'EOF'
#!/usr/bin/env bash

# New feature implementation
# Generated by Claude Automation System

new_feature() {
    echo "This is a new feature implementation"
    # TODO: Implement actual functionality
}

# Export function
export -f new_feature
EOF
    
    chmod +x "$feature_file"
    
    # READMEの更新
    if [[ -f "${WORKSPACE_DIR}/README.md" ]]; then
        echo -e "\n## New Feature\n\nAdded new feature implementation.\n" >> "${WORKSPACE_DIR}/README.md"
    fi
}

# サンプルバグ修正の作成（開発用）
create_sample_bugfix() {
    # 既存ファイルの修正をシミュレート
    local target_file="${WORKSPACE_DIR}/src/existing_file.sh"
    
    if [[ ! -f "$target_file" ]]; then
        mkdir -p "$(dirname "$target_file")"
        echo "#!/usr/bin/env bash" > "$target_file"
        echo "# Existing file" >> "$target_file"
        echo "echo 'Original implementation'" >> "$target_file"
    fi
    
    # バグ修正を適用
    sed -i.bak 's/Original implementation/Fixed implementation/' "$target_file"
    rm -f "${target_file}.bak"
}

# デフォルト実装の作成（開発用）
create_default_implementation() {
    log_info "Creating default implementation"
    echo "# Default implementation for Issue #${ISSUE_NUMBER}" > "${WORKSPACE_DIR}/IMPLEMENTATION.md"
}

# 変更のコミット
commit_changes() {
    cd "$WORKSPACE_DIR" || return 1
    
    # 変更をステージング
    git_stage_changes "$WORKSPACE_DIR"
    
    # 変更があるかチェック
    if ! git diff --cached --quiet; then
        # コミットメッセージの生成
        local commit_type="feat"
        local commit_scope="${REPOSITORY##*/}"
        local commit_description="Implement Issue #${ISSUE_NUMBER}"
        
        if [[ "$ISSUE_TITLE" =~ [Bb]ug|[Ff]ix ]]; then
            commit_type="fix"
            commit_description="Fix Issue #${ISSUE_NUMBER}"
        fi
        
        local commit_message
        commit_message=$(generate_commit_message "$commit_type" "$commit_scope" "$commit_description" "$ISSUE_NUMBER" "$ISSUE_TITLE")
        
        # コミット
        if ! git_commit "$commit_message" "$WORKSPACE_DIR"; then
            log_error "Failed to commit changes"
            return 1
        fi
        
        log_info "Changes committed successfully"
    else
        log_warn "No changes to commit"
        return 1
    fi
    
    return 0
}

# Pull Requestの作成
create_pull_request() {
    cd "$WORKSPACE_DIR" || return 1
    
    # ブランチをプッシュ
    if ! git_push "$BRANCH_NAME" "$WORKSPACE_DIR"; then
        log_error "Failed to push branch"
        return 1
    fi
    
    # PR作成用のデータを準備
    local pr_title="[Claude Auto] ${ISSUE_TITLE}"
    local pr_body="## Summary

Automated implementation for Issue #${ISSUE_NUMBER}

## Changes

$(git log --oneline ${BASE_BRANCH}..HEAD | sed 's/^/- /')

## Related Issue

Closes #${ISSUE_NUMBER}

## Test Plan

- [x] Code implemented by Claude Automation System
- [x] Changes committed and pushed
- [ ] Manual testing recommended

---
🤖 This PR was created by [Claude Automation System](https://github.com/anthropics/claude-code)"
    
    log_info "Creating pull request..."
    
    # gh コマンドでPRを作成
    local pr_url
    if pr_url=$(gh pr create --repo "$REPOSITORY" --title "$pr_title" --body "$pr_body" --base "$BASE_BRANCH" --head "$BRANCH_NAME"); then
        local pr_number
        pr_number=$(echo "$pr_url" | grep -o '/pull/[0-9]*' | grep -o '[0-9]*')
        
        log_info "Pull request created: #${pr_number} - ${pr_url}"
        
        # PRにラベルを追加
        add_pr_labels "$pr_number"
        
        # Issueにコメントを追加
        add_issue_comment "$ISSUE_NUMBER" "🤖 Claude has created PR #${pr_number} to address this issue.

PR: ${pr_url}"
        
        return 0
    else
        log_error "Failed to create pull request"
        return 1
    fi
}

# PRにラベルを追加
add_pr_labels() {
    local pr_number=$1
    
    # gh コマンドでラベルを追加
    gh pr edit "$pr_number" --repo "$REPOSITORY" --add-label "claude-automated-pr" || true
}

# Issueにコメントを追加
add_issue_comment() {
    local issue_number=$1
    local comment=$2
    
    # gh コマンドでコメントを投稿
    gh issue comment "$issue_number" --repo "$REPOSITORY" --body "$comment" || true
}

# クリーンアップ
cleanup() {
    # Terminal モードの場合はワークスペースを保持
    if [[ "$EXECUTION_MODE" == "terminal" ]]; then
        if [[ -n "$WORKSPACE_DIR" ]] && [[ -d "$WORKSPACE_DIR" ]]; then
            log_info "Keeping workspace for terminal session: $WORKSPACE_DIR"
            # ワークスペース情報をファイルに記録
            local workspace_info="${CLAUDE_AUTO_HOME}/logs/active_workspaces.json"
            local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            local workspace_entry=$(cat <<EOF
{
    "workspace_path": "$WORKSPACE_DIR",
    "repository": "$REPOSITORY",
    "issue_number": $ISSUE_NUMBER,
    "branch_name": "$BRANCH_NAME",
    "created_at": "$timestamp",
    "execution_id": "$EXECUTION_ID"
}
EOF
            )
            
            # アクティブワークスペースファイルが存在しない場合は作成
            if [[ ! -f "$workspace_info" ]]; then
                echo "[]" > "$workspace_info"
            fi
            
            # 新しいエントリを追加
            local temp_file="${workspace_info}.tmp"
            jq ". += [$workspace_entry]" "$workspace_info" > "$temp_file" && mv "$temp_file" "$workspace_info"
        fi
    else
        # 通常のクリーンアップ
        if [[ -n "$WORKSPACE_DIR" ]] && [[ -d "$WORKSPACE_DIR" ]]; then
            log_info "Cleaning up workspace: $WORKSPACE_DIR"
            rm -rf "$WORKSPACE_DIR"
        fi
    fi
}

# 実行モードの決定
determine_execution_mode() {
    # 設定から実行モードを取得
    local default_mode
    default_mode=$(get_config_value "claude.execution.mode" "batch" "integrations")
    
    # Issue bodyから実行モードのヒントを検索
    local mode_hints=("@claude-terminal" "@claude-interactive" "@claude-visual")
    
    for hint in "${mode_hints[@]}"; do
        if [[ "$ISSUE_BODY" == *"$hint"* ]]; then
            case "$hint" in
                "@claude-terminal"|"@claude-interactive"|"@claude-visual")
                    EXECUTION_MODE="terminal"
                    log_info "Terminal execution mode detected from keyword: $hint"
                    return 0
                    ;;
            esac
        fi
    done
    
    # Issue labelsからTerminal実行モードを判定
    if [[ "$ISSUE_LABELS" == *"terminal-execution"* ]] || [[ "$ISSUE_LABELS" == *"interactive"* ]]; then
        EXECUTION_MODE="terminal"
        log_info "Terminal execution mode detected from labels"
        return 0
    fi
    
    # 複雑なタスクの自動判定
    if is_complex_task "$ISSUE_BODY"; then
        EXECUTION_MODE="terminal"
        log_info "Terminal execution mode auto-selected for complex task"
        return 0
    fi
    
    # デフォルトモードを使用
    EXECUTION_MODE="$default_mode"
    log_info "Using default execution mode: $EXECUTION_MODE"
}

# 複雑なタスクかどうかを判定
is_complex_task() {
    local issue_body=$1
    
    # 複雑さの指標
    local complexity_indicators=(
        "複数のファイル" "multiple files" "several files"
        "新しいAPI" "new API" "API endpoint"
        "データベース" "database" "DB"
        "テスト" "test" "testing"
        "リファクタリング" "refactor" "refactoring"
        "アーキテクチャ" "architecture"
        "マイグレーション" "migration"
        "設計" "design"
    )
    
    local indicator_count=0
    for indicator in "${complexity_indicators[@]}"; do
        if [[ "$issue_body" == *"$indicator"* ]]; then
            ((indicator_count++))
        fi
    done
    
    # 2つ以上の指標があれば複雑なタスクと判定
    [[ $indicator_count -ge 2 ]]
}

# Terminal自動起動でClaude実行
execute_claude_with_terminal() {
    log_info "Executing Claude with Terminal auto-launch..."
    
    # ターミナルランチャーのパス
    local terminal_launcher="${CLAUDE_AUTO_HOME}/src/core/terminal-launcher.sh"
    
    if [[ ! -x "$terminal_launcher" ]]; then
        log_error "Terminal launcher not found or not executable: $terminal_launcher"
        return 1
    fi
    
    # 実行タスクの準備
    local task_description="Issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}

${ISSUE_BODY}

## 実行環境
- Repository: ${REPOSITORY}
- Branch: ${BRANCH_NAME}
- Base Branch: ${BASE_BRANCH}
- Workspace: ${WORKSPACE_DIR}

## 次のステップ
1. プロジェクト構造を確認
2. 要求された機能を実装
3. テストを実行
4. 変更をコミット
5. プルリクエストを作成"
    
    # 使用するターミナルタイプを設定から取得
    local terminal_type
    terminal_type=$(get_config_value "claude.terminal.app" "Terminal" "integrations")
    
    # Terminal自動起動（Issue番号も渡す）
    if "$terminal_launcher" "$WORKSPACE_DIR" "$task_description" "$terminal_type" "$ISSUE_NUMBER"; then
        log_info "Terminal session launched successfully"
        
        # Issueに進行状況をコメント
        add_issue_comment "$ISSUE_NUMBER" "🚀 Claude Codeが新しい${terminal_type}セッションで起動されました。

**セッション情報:**
- プロジェクト: \`${WORKSPACE_DIR}\`
- ブランチ: \`${BRANCH_NAME}\`
- タスク: ${ISSUE_TITLE}

Claude Codeが自動的にタスクを実行し、完了後にプルリクエストを作成します。

⚠️ **注意**: Terminal セッションが起動されました。これ以上の自動処理は行いません。"
        
        # 実行履歴を更新して再処理を防ぐ
        # 注: この関数はevent-processor.shにあるため、ここでは手動で更新
        local execution_history_file="${CLAUDE_AUTO_HOME}/execution_history.json"
        if [[ -f "$execution_history_file" ]]; then
            # 既存の履歴に追加（Terminal実行は即座に "completed" とマーク）
            local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            
            # jqを使って安全にJSONエントリを追加
            local temp_file="${execution_history_file}.tmp"
            jq --arg repo "$REPOSITORY" \
               --arg issue_number "$ISSUE_NUMBER" \
               --arg status "completed" \
               --arg created_at "$timestamp" \
               --arg updated_at "$timestamp" \
               --arg retry_count "0" \
               --arg details "Terminal session launched - manual intervention required" \
               '. += [{
                   repo: $repo,
                   issue_number: ($issue_number | tonumber),
                   status: $status,
                   created_at: $created_at,
                   updated_at: $updated_at,
                   retry_count: ($retry_count | tonumber),
                   details: $details
               }]' "$execution_history_file" > "$temp_file" && mv "$temp_file" "$execution_history_file"
        fi
        
        return 0
    else
        log_error "Failed to launch terminal session"
        return 1
    fi
}

# エラーハンドラー
handle_error() {
    local exit_code=$?
    log_error "Claude executor failed (exit code: $exit_code)"
    
    # Issueにエラーコメントを追加
    if [[ -n "${ISSUE_NUMBER:-}" ]]; then
        add_issue_comment "$ISSUE_NUMBER" "❌ Claude execution failed. Please check the logs for details."
    fi
    
    cleanup
    exit $exit_code
}

# メイン処理
main() {
    # エラーハンドラーの設定
    trap handle_error ERR
    
    # 初期化
    initialize
    
    # パラメータの解析
    parse_execution_params || exit 1
    
    # リポジトリのセットアップ
    setup_repository || exit 1
    
    if [[ "$EVENT_TYPE" == "issue" ]]; then
        # 実行モードの決定
        determine_execution_mode
        
        if [[ "$EXECUTION_MODE" == "terminal" ]]; then
            # Terminal自動起動モード（ワークスペースはクリーンアップしない）
            execute_claude_with_terminal || exit 1
            # Terminal モードの場合はワークスペースを保持
            WORKSPACE_DIR=""  # クリーンアップを防ぐ
        else
            # バッチモード（従来の方式）
            # Claudeプロンプトの生成
            local prompt
            prompt=$(generate_claude_prompt)
            
            # Claude実行
            execute_claude "$prompt" || exit 1
            
            # 変更のコミット
            if commit_changes; then
                # Pull Requestの作成
                create_pull_request || exit 1
            fi
        fi
    elif [[ "$EVENT_TYPE" == "pull_request" ]]; then
        # PRレビューの実装（将来の拡張）
        log_info "PR review functionality not yet implemented"
    fi
    
    # クリーンアップ
    cleanup
    
    log_info "Claude executor completed successfully"
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi