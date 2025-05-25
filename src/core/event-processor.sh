#!/usr/bin/env bash

# event-processor.sh - GitHubイベントを処理してClaude実行を判断
# 
# 使用方法:
#   echo "$event_data" | ./src/core/event-processor.sh <event_type> <repo_name>

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/git-utils.sh"

# 定数
readonly EXECUTION_LOCK_DIR="${CLAUDE_AUTO_HOME}/locks"
readonly EXECUTION_HISTORY_FILE="${CLAUDE_AUTO_HOME}/execution_history.json"

# グローバル変数
EVENT_TYPE="${1:-}"
REPO_NAME="${2:-}"
EVENT_DATA=""

# 初期化
initialize() {
    # 引数チェック
    if [[ -z "$EVENT_TYPE" ]] || [[ -z "$REPO_NAME" ]]; then
        log_error "Usage: $0 <event_type> <repo_name>"
        exit 1
    fi
    
    # イベントデータを標準入力から読み込み
    EVENT_DATA=$(cat)
    
    # ロックディレクトリの作成
    mkdir -p "$EXECUTION_LOCK_DIR"
    
    log_info "Processing $EVENT_TYPE event for $REPO_NAME"
}

# 実行履歴のチェック
check_execution_history() {
    local issue_number=$1
    local repo_name=$2
    
    if [[ ! -f "$EXECUTION_HISTORY_FILE" ]]; then
        echo "[]" > "$EXECUTION_HISTORY_FILE"
        return 1
    fi
    
    # 実行履歴から該当するエントリを検索
    local history_entry
    history_entry=$(jq -r ".[] | select(.repo == \"$repo_name\" and .issue_number == $issue_number)" "$EXECUTION_HISTORY_FILE")
    
    if [[ -n "$history_entry" ]]; then
        local status
        status=$(echo "$history_entry" | jq -r '.status')
        
        case "$status" in
            "completed")
                log_info "Issue #${issue_number} has already been processed"
                return 0
                ;;
            "in_progress")
                log_info "Issue #${issue_number} is currently being processed"
                return 0
                ;;
            "failed")
                local retry_count
                retry_count=$(echo "$history_entry" | jq -r '.retry_count // 0')
                local max_retries
                max_retries=$(get_config_value "claude.execution.max_retries" "2" "integrations")
                
                if [[ $retry_count -ge $max_retries ]]; then
                    log_warn "Issue #${issue_number} has reached maximum retry attempts"
                    return 0
                else
                    log_info "Retrying Issue #${issue_number} (attempt $((retry_count + 1)))"
                    return 1
                fi
                ;;
        esac
    fi
    
    return 1
}

# 実行履歴の更新
update_execution_history() {
    local issue_number=$1
    local repo_name=$2
    local status=$3
    local details=${4:-""}
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # 既存のエントリを検索
    local existing_entry
    existing_entry=$(jq -r ".[] | select(.repo == \"$repo_name\" and .issue_number == $issue_number)" "$EXECUTION_HISTORY_FILE")
    
    if [[ -n "$existing_entry" ]]; then
        # 既存エントリを更新
        local retry_count
        retry_count=$(echo "$existing_entry" | jq -r '.retry_count // 0')
        
        if [[ "$status" == "failed" ]]; then
            ((retry_count++))
        fi
        
        jq "map(if .repo == \"$repo_name\" and .issue_number == $issue_number then 
            .status = \"$status\" | 
            .updated_at = \"$timestamp\" | 
            .retry_count = $retry_count | 
            .details = \"$details\" 
        else . end)" "$EXECUTION_HISTORY_FILE" > "${EXECUTION_HISTORY_FILE}.tmp"
    else
        # 新規エントリを追加
        jq ". += [{
            \"repo\": \"$repo_name\",
            \"issue_number\": $issue_number,
            \"status\": \"$status\",
            \"created_at\": \"$timestamp\",
            \"updated_at\": \"$timestamp\",
            \"retry_count\": 0,
            \"details\": \"$details\"
        }]" "$EXECUTION_HISTORY_FILE" > "${EXECUTION_HISTORY_FILE}.tmp"
    fi
    
    mv "${EXECUTION_HISTORY_FILE}.tmp" "$EXECUTION_HISTORY_FILE"
}

# ロックの取得
acquire_lock() {
    local lock_name=$1
    local lock_file="${EXECUTION_LOCK_DIR}/${lock_name}.lock"
    local timeout=300  # 5分のタイムアウト
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if mkdir "$lock_file" 2>/dev/null; then
            echo $$ > "${lock_file}/pid"
            log_debug "Acquired lock: $lock_name"
            return 0
        fi
        
        # 既存のロックが古い場合は削除
        if [[ -f "${lock_file}/pid" ]]; then
            local lock_pid
            lock_pid=$(cat "${lock_file}/pid")
            if ! ps -p "$lock_pid" > /dev/null 2>&1; then
                log_warn "Removing stale lock: $lock_name"
                rm -rf "$lock_file"
                continue
            fi
        fi
        
        sleep 5
        ((elapsed += 5))
    done
    
    log_error "Failed to acquire lock: $lock_name (timeout)"
    return 1
}

# ロックの解放
release_lock() {
    local lock_name=$1
    local lock_file="${EXECUTION_LOCK_DIR}/${lock_name}.lock"
    
    if [[ -d "$lock_file" ]]; then
        rm -rf "$lock_file"
        log_debug "Released lock: $lock_name"
    fi
}

# Issue イベントの処理
process_issue_event() {
    local issue_data=$1
    
    # Issue情報を抽出
    local issue_number
    issue_number=$(echo "$issue_data" | jq -r '.number')
    
    local issue_title
    issue_title=$(echo "$issue_data" | jq -r '.title')
    
    local issue_body
    issue_body=$(echo "$issue_data" | jq -r '.body // ""')
    
    local issue_labels
    issue_labels=$(echo "$issue_data" | jq -r '.labels[].name' | tr '\n' ' ')
    
    local issue_state
    issue_state=$(echo "$issue_data" | jq -r '.state')
    
    log_info "Processing Issue #${issue_number}: ${issue_title}"
    
    # クローズされたIssueはスキップ
    if [[ "$issue_state" != "open" ]]; then
        log_info "Skipping closed issue #${issue_number}"
        return 0
    fi
    
    # 実行履歴をチェック
    if check_execution_history "$issue_number" "$REPO_NAME"; then
        return 0
    fi
    
    # ロックを取得
    local lock_name="${REPO_NAME//\//_}_issue_${issue_number}"
    if ! acquire_lock "$lock_name"; then
        log_error "Failed to acquire lock for Issue #${issue_number}"
        return 1
    fi
    
    # 実行履歴を更新（処理開始）
    update_execution_history "$issue_number" "$REPO_NAME" "in_progress" "Processing started"
    
    # リポジトリ設定を取得
    local repo_config
    if ! repo_config=$(get_repository_config "$REPO_NAME"); then
        repo_config=$(get_config_object "default_settings" "repositories")
    fi
    
    # ブランチ戦略を決定
    local branch_strategy
    branch_strategy=$(echo "$repo_config" | jq -r '.branch_strategy // "github-flow"')
    
    # ブランチタイプを決定
    local branch_type="feature"
    local label_mapping
    label_mapping=$(get_config_array "label_to_branch_type" "repositories")
    
    while IFS= read -r mapping; do
        local mapping_labels
        mapping_labels=$(echo "$mapping" | jq -r '.labels[]')
        local mapping_type
        mapping_type=$(echo "$mapping" | jq -r '.branch_type')
        
        while IFS= read -r label; do
            if [[ " $issue_labels " == *" $label "* ]]; then
                branch_type="$mapping_type"
                break 2
            fi
        done <<< "$mapping_labels"
    done <<< "$label_mapping"
    
    # ブランチ名を生成
    local branch_name
    branch_name=$(generate_branch_name "$issue_number" "$branch_type" "$branch_strategy" "$issue_title")
    
    log_info "Generated branch name: $branch_name"
    
    # Claude実行パラメータを準備
    local execution_params
    execution_params=$(cat <<EOF
{
    "event_type": "issue",
    "repository": "$REPO_NAME",
    "issue_number": $issue_number,
    "issue_title": $(echo "$issue_title" | jq -Rs .),
    "issue_body": $(echo "$issue_body" | jq -Rs .),
    "issue_labels": $(echo "$issue_labels" | jq -Rs .),
    "branch_name": "$branch_name",
    "branch_strategy": "$branch_strategy",
    "branch_type": "$branch_type",
    "base_branch": $(echo "$repo_config" | jq -r '.base_branch // "main"' | jq -Rs .)
}
EOF
    )
    
    # Claude実行
    local claude_executor="${CLAUDE_AUTO_HOME}/src/core/claude-executor.sh"
    
    if [[ -x "$claude_executor" ]]; then
        log_info "Executing Claude for Issue #${issue_number}"
        
        if echo "$execution_params" | "$claude_executor"; then
            update_execution_history "$issue_number" "$REPO_NAME" "completed" "Successfully processed"
            send_slack_notification "success" "$issue_number" "$issue_title" "$REPO_NAME"
        else
            update_execution_history "$issue_number" "$REPO_NAME" "failed" "Claude execution failed"
            send_slack_notification "error" "$issue_number" "$issue_title" "$REPO_NAME"
        fi
    else
        log_error "Claude executor not found or not executable"
        update_execution_history "$issue_number" "$REPO_NAME" "failed" "Claude executor not available"
    fi
    
    # ロックを解放
    release_lock "$lock_name"
}

# Pull Request イベントの処理
process_pr_event() {
    local pr_data=$1
    
    # PR情報を抽出
    local pr_number
    pr_number=$(echo "$pr_data" | jq -r '.number')
    
    local pr_title
    pr_title=$(echo "$pr_data" | jq -r '.title')
    
    local pr_body
    pr_body=$(echo "$pr_data" | jq -r '.body // ""')
    
    local pr_state
    pr_state=$(echo "$pr_data" | jq -r '.state')
    
    local pr_labels
    pr_labels=$(echo "$pr_data" | jq -r '.labels[].name' | tr '\n' ' ')
    
    log_info "Processing PR #${pr_number}: ${pr_title}"
    
    # クローズされたPRはスキップ
    if [[ "$pr_state" != "open" ]]; then
        log_info "Skipping closed PR #${pr_number}"
        return 0
    fi
    
    # Claude自動生成のPRはスキップ
    if [[ " $pr_labels " == *" claude-automated-pr "* ]]; then
        log_info "Skipping Claude-generated PR #${pr_number}"
        return 0
    fi
    
    # レビュー要求のチェック
    local review_keywords=("@claude-review" "@claude-update" "@claude-fix")
    local should_process=false
    
    for keyword in "${review_keywords[@]}"; do
        if [[ "$pr_body" == *"$keyword"* ]] || [[ "$pr_title" == *"$keyword"* ]]; then
            should_process=true
            break
        fi
    done
    
    if [[ "$should_process" != "true" ]]; then
        log_debug "No Claude keywords found in PR #${pr_number}"
        return 0
    fi
    
    # ロックを取得
    local lock_name="${REPO_NAME//\//_}_pr_${pr_number}"
    if ! acquire_lock "$lock_name"; then
        log_error "Failed to acquire lock for PR #${pr_number}"
        return 1
    fi
    
    # Claude実行パラメータを準備
    local execution_params
    execution_params=$(cat <<EOF
{
    "event_type": "pull_request",
    "repository": "$REPO_NAME",
    "pr_number": $pr_number,
    "pr_title": $(echo "$pr_title" | jq -Rs .),
    "pr_body": $(echo "$pr_body" | jq -Rs .),
    "pr_labels": $(echo "$pr_labels" | jq -Rs .),
    "pr_branch": $(echo "$pr_data" | jq -r '.head.ref' | jq -Rs .)
}
EOF
    )
    
    # Claude実行
    local claude_executor="${CLAUDE_AUTO_HOME}/src/core/claude-executor.sh"
    
    if [[ -x "$claude_executor" ]]; then
        log_info "Executing Claude for PR #${pr_number}"
        
        if echo "$execution_params" | "$claude_executor"; then
            send_slack_notification "pr_review_complete" "$pr_number" "$pr_title" "$REPO_NAME"
        else
            send_slack_notification "pr_review_error" "$pr_number" "$pr_title" "$REPO_NAME"
        fi
    else
        log_error "Claude executor not found or not executable"
    fi
    
    # ロックを解放
    release_lock "$lock_name"
}

# Slack通知の送信
send_slack_notification() {
    local notification_type=$1
    local issue_or_pr_number=$2
    local title=$3
    local repo=$4
    
    # Slack設定を確認
    local slack_enabled
    slack_enabled=$(get_config_value "slack.enabled" "false" "integrations")
    
    if [[ "$slack_enabled" != "true" ]]; then
        return 0
    fi
    
    # 通知クライアントが利用可能か確認
    local slack_client="${CLAUDE_AUTO_HOME}/src/integrations/slack-client.sh"
    
    if [[ -x "$slack_client" ]]; then
        "$slack_client" "$notification_type" "$issue_or_pr_number" "$title" "$repo"
    else
        log_warn "Slack client not available"
    fi
}

# メイン処理
main() {
    # 初期化
    initialize
    
    # イベントタイプに応じて処理を分岐
    case "$EVENT_TYPE" in
        "issue")
            process_issue_event "$EVENT_DATA"
            ;;
        "pull_request")
            process_pr_event "$EVENT_DATA"
            ;;
        *)
            log_error "Unknown event type: $EVENT_TYPE"
            exit 1
            ;;
    esac
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi