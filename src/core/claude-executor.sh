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

# 定数
readonly WORKSPACE_BASE="${CLAUDE_AUTO_HOME}/workspace"
readonly CLAUDE_LOG_DIR="${CLAUDE_AUTO_HOME}/logs/claude"
readonly MAX_EXECUTION_TIME=600  # 10分

# グローバル変数
EXECUTION_PARAMS=""
WORKSPACE_DIR=""
EXECUTION_ID=""

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
            BRANCH_NAME=$(echo "$EXECUTION_PARAMS" | jq -r '.branch_name')
            BASE_BRANCH=$(echo "$EXECUTION_PARAMS" | jq -r '.base_branch')
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
    local repo_url="https://github.com/${REPOSITORY}.git"
    WORKSPACE_DIR="${WORKSPACE_BASE}/${EXECUTION_ID}_${REPOSITORY//\//_}"
    
    log_info "Setting up repository: $REPOSITORY"
    
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
    
    # Claude実行コマンドの構築
    local claude_cmd="claude"
    
    # プロンプトファイルの作成
    local prompt_file="${WORKSPACE_DIR}/.claude_prompt"
    echo "$prompt" > "$prompt_file"
    
    # タイムアウト付きでClaude実行
    local start_time=$(date +%s)
    
    # Claude実行（実際の実装では、Claude APIやCLIを使用）
    # ここでは仮の実装として、プロンプトに基づいてファイルを作成
    if [[ "$EVENT_TYPE" == "issue" ]]; then
        # 実装の仮シミュレーション
        log_info "Simulating Claude implementation..."
        
        # 実装ファイルの作成（例）
        case "$ISSUE_TITLE" in
            *"Add"*|*"Create"*|*"Implement"*)
                # 新機能の追加をシミュレート
                create_sample_implementation
                ;;
            *"Fix"*|*"Bug"*)
                # バグ修正をシミュレート
                create_sample_bugfix
                ;;
            *)
                # デフォルトの実装
                create_default_implementation
                ;;
        esac
        
        # 実行時間の記録
        local end_time=$(date +%s)
        local execution_time=$((end_time - start_time))
        log_info "Claude execution completed in ${execution_time} seconds"
        
        return 0
    fi
    
    return 0
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
    local pr_body
    pr_body=$(get_prompt_template "pr_prompts.pr_description" "claude-prompts")
    
    # PRボディの変数を置換
    pr_body="${pr_body//\{summary\}/Automated implementation for Issue #${ISSUE_NUMBER}}"
    pr_body="${pr_body//\{changes\}/See commits for detailed changes}"
    pr_body="${pr_body//\{issue_number\}/$ISSUE_NUMBER}"
    pr_body="${pr_body//\{test_description\}/Tests have been added/updated as needed}"
    
    # GitHub APIでPRを作成
    local pr_data
    pr_data=$(cat <<EOF
{
    "title": "$pr_title",
    "body": "$pr_body",
    "head": "$BRANCH_NAME",
    "base": "$BASE_BRANCH",
    "draft": false
}
EOF
    )
    
    log_info "Creating pull request..."
    
    local pr_response
    if pr_response=$(github_api_call "/repos/${REPOSITORY}/pulls" "POST" "$pr_data"); then
        local pr_number
        pr_number=$(echo "$pr_response" | jq -r '.number')
        local pr_url
        pr_url=$(echo "$pr_response" | jq -r '.html_url')
        
        log_info "Pull request created: #${pr_number} - ${pr_url}"
        
        # PRにラベルを追加
        add_pr_labels "$pr_number"
        
        # Issueにコメントを追加
        add_issue_comment "$ISSUE_NUMBER" "🤖 Claude has created PR #${pr_number} to address this issue.\n\nPR: ${pr_url}"
        
        return 0
    else
        log_error "Failed to create pull request"
        return 1
    fi
}

# PRにラベルを追加
add_pr_labels() {
    local pr_number=$1
    
    local labels='["claude-automated-pr"]'
    
    github_api_call "/repos/${REPOSITORY}/issues/${pr_number}/labels" "POST" "{\"labels\": $labels}" || true
}

# Issueにコメントを追加
add_issue_comment() {
    local issue_number=$1
    local comment=$2
    
    local comment_data
    comment_data=$(jq -n --arg body "$comment" '{body: $body}')
    
    github_api_call "/repos/${REPOSITORY}/issues/${issue_number}/comments" "POST" "$comment_data" || true
}

# クリーンアップ
cleanup() {
    if [[ -n "$WORKSPACE_DIR" ]] && [[ -d "$WORKSPACE_DIR" ]]; then
        log_info "Cleaning up workspace: $WORKSPACE_DIR"
        rm -rf "$WORKSPACE_DIR"
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