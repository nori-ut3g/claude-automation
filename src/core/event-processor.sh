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
    
    # 依存関係のチェック（bcは不要になったため削除）
    
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
    
    # ファイルの内容を検証し、破損している場合は復旧
    if ! jq . "$EXECUTION_HISTORY_FILE" >/dev/null 2>&1; then
        log_warn "Execution history file is corrupted during check, resetting to empty array"
        echo "[]" > "$EXECUTION_HISTORY_FILE"
        return 1
    fi
    
    # 実行履歴から該当するエントリを検索
    local history_entry
    history_entry=$(jq -r ".[] | select(.repo == \"$repo_name\" and .issue_number == $issue_number)" "$EXECUTION_HISTORY_FILE" 2>/dev/null || echo "")
    
    if [[ -n "$history_entry" ]]; then
        local status
        status=$(echo "$history_entry" | jq -r '.status' 2>/dev/null || echo "")
        
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
                retry_count=$(echo "$history_entry" | jq -r '.retry_count // 0' 2>/dev/null || echo 0)
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

# 実行履歴の更新（改良されたファイルロック付き）
update_execution_history() {
    local issue_number=$1
    local repo_name=$2
    local status=$3
    local details=${4:-""}
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # 実行履歴ファイルのロック（改良版）
    local history_lock="${EXECUTION_LOCK_DIR}/execution_history.lock"
    local lock_timeout=60  # タイムアウトを60秒に延長
    local retry_interval=1  # リトライ間隔（整数）
    local elapsed=0
    local my_pid=$$
    local lock_acquired=false
    
    # ロック取得のリトライループ
    while [[ $elapsed -lt $lock_timeout ]]; do
        # アトミックなロック取得の試行
        if mkdir "$history_lock" 2>/dev/null; then
            # ロックディレクトリにPIDとタイムスタンプを記録
            echo "$my_pid" > "${history_lock}/pid"
            echo "$(date +%s)" > "${history_lock}/timestamp"
            echo "$repo_name:$issue_number" > "${history_lock}/resource"
            lock_acquired=true
            log_debug "Acquired execution history lock (PID: $my_pid)"
            break
        fi
        
        # 既存のロックが古い場合は削除を試行
        if [[ -d "$history_lock" ]]; then
            local lock_pid=""
            local lock_time=""
            
            # ロック情報を安全に読み取り
            if [[ -f "${history_lock}/pid" ]]; then
                lock_pid=$(cat "${history_lock}/pid" 2>/dev/null || echo "")
            fi
            if [[ -f "${history_lock}/timestamp" ]]; then
                lock_time=$(cat "${history_lock}/timestamp" 2>/dev/null || echo "")
            fi
            
            local current_time
            current_time=$(date +%s)
            local should_remove=false
            
            # プロセスが存在しない場合
            if [[ -n "$lock_pid" ]] && ! ps -p "$lock_pid" > /dev/null 2>&1; then
                log_warn "Removing stale lock: process $lock_pid no longer exists"
                should_remove=true
            # ロックが古すぎる場合（5分以上）
            elif [[ -n "$lock_time" ]] && [[ $((current_time - lock_time)) -gt 300 ]]; then
                log_warn "Removing expired lock: locked for more than 5 minutes"
                should_remove=true
            fi
            
            # 古いロックの削除を試行
            if [[ "$should_remove" == "true" ]]; then
                # アトミックに削除を試行（他のプロセスが先に削除する可能性があるため）
                if rmdir "$history_lock" 2>/dev/null; then
                    log_info "Successfully removed stale lock"
                    continue  # すぐに次の取得を試行
                else
                    log_debug "Lock was already removed by another process"
                fi
            fi
        fi
        
        sleep $retry_interval
        elapsed=$((elapsed + 1))  # 简化为整数运算
    done
    
    if [[ "$lock_acquired" != "true" ]]; then
        log_error "Failed to acquire execution history lock after ${lock_timeout}s timeout"
        return 1
    fi
    
    # ファイルが存在しない場合は初期化
    if [[ ! -f "$EXECUTION_HISTORY_FILE" ]]; then
        echo "[]" > "$EXECUTION_HISTORY_FILE"
    fi
    
    # ファイルの内容を検証し、破損している場合は復旧
    if ! jq . "$EXECUTION_HISTORY_FILE" >/dev/null 2>&1; then
        log_warn "Execution history file is corrupted, resetting to empty array"
        echo "[]" > "$EXECUTION_HISTORY_FILE"
    fi
    
    # 既存のエントリを検索
    local existing_entry
    existing_entry=$(jq -r ".[] | select(.repo == \"$repo_name\" and .issue_number == $issue_number)" "$EXECUTION_HISTORY_FILE" 2>/dev/null || echo "")
    
    # 改良されたトランザクション的な更新
    local temp_file="${EXECUTION_HISTORY_FILE}.tmp.${my_pid}.$(date +%s%N)"
    local update_success=false
    
    # 最大3回の更新試行
    for attempt in {1..3}; do
        if [[ -n "$existing_entry" ]]; then
            # 既存エントリを更新
            local retry_count
            retry_count=$(echo "$existing_entry" | jq -r '.retry_count // 0' 2>/dev/null || echo 0)
            
            if [[ "$status" == "failed" ]]; then
                ((retry_count++))
            fi
            
            if jq "map(if .repo == \"$repo_name\" and .issue_number == $issue_number then 
                .status = \"$status\" | 
                .updated_at = \"$timestamp\" | 
                .retry_count = $retry_count | 
                .details = \"$details\" 
            else . end)" "$EXECUTION_HISTORY_FILE" > "$temp_file" 2>/dev/null; then
                update_success=true
                break
            fi
        else
            # 新規エントリを追加
            if jq ". += [{
                \"repo\": \"$repo_name\",
                \"issue_number\": $issue_number,
                \"status\": \"$status\",
                \"created_at\": \"$timestamp\",
                \"updated_at\": \"$timestamp\",
                \"retry_count\": 0,
                \"details\": \"$details\"
            }]" "$EXECUTION_HISTORY_FILE" > "$temp_file" 2>/dev/null; then
                update_success=true
                break
            fi
        fi
        
        log_warn "Update attempt $attempt failed, retrying..."
        sleep 0.1
    done
    
    # 更新が成功した場合のみファイルを置換
    if [[ "$update_success" == "true" ]] && [[ -f "$temp_file" ]] && jq . "$temp_file" >/dev/null 2>&1; then
        # アトミックな置換
        if mv "$temp_file" "$EXECUTION_HISTORY_FILE" 2>/dev/null; then
            log_debug "Execution history updated successfully"
        else
            log_error "Failed to atomically update execution history file"
            rm -f "$temp_file"
        fi
    else
        log_error "Failed to update execution history after 3 attempts"
        rm -f "$temp_file"
    fi
    
    # ロックを解放
    rm -rf "$history_lock" 2>/dev/null || log_warn "Failed to remove execution history lock"
}

# 改良されたロック取得機能
acquire_lock() {
    local lock_name=$1
    local lock_file="${EXECUTION_LOCK_DIR}/${lock_name}.lock"
    local timeout=600  # 10分のタイムアウト（長時間実行に対応）
    local retry_interval=1
    local elapsed=0
    local my_pid=$$
    
    log_debug "Attempting to acquire lock: $lock_name (PID: $my_pid)"
    
    while [[ $elapsed -lt $timeout ]]; do
        # アトミックなロック取得の試行
        if mkdir "$lock_file" 2>/dev/null; then
            # ロック情報を記録
            echo "$my_pid" > "${lock_file}/pid"
            echo "$(date +%s)" > "${lock_file}/timestamp"
            echo "$(hostname)" > "${lock_file}/host"
            echo "$lock_name" > "${lock_file}/resource"
            
            log_debug "Successfully acquired lock: $lock_name (PID: $my_pid)"
            return 0
        fi
        
        # 既存のロックの状態をチェック
        if [[ -d "$lock_file" ]]; then
            local lock_pid=""
            local lock_time=""
            local lock_host=""
            
            # ロック情報を安全に読み取り
            if [[ -f "${lock_file}/pid" ]]; then
                lock_pid=$(cat "${lock_file}/pid" 2>/dev/null || echo "")
            fi
            if [[ -f "${lock_file}/timestamp" ]]; then
                lock_time=$(cat "${lock_file}/timestamp" 2>/dev/null || echo "")
            fi
            if [[ -f "${lock_file}/host" ]]; then
                lock_host=$(cat "${lock_file}/host" 2>/dev/null || echo "")
            fi
            
            local current_time
            current_time=$(date +%s)
            local should_remove=false
            local reason=""
            
            # プロセスが存在しない場合（同一ホスト上でのみチェック）
            if [[ -n "$lock_pid" ]] && [[ "$lock_host" == "$(hostname)" ]]; then
                if ! ps -p "$lock_pid" > /dev/null 2>&1; then
                    should_remove=true
                    reason="process $lock_pid no longer exists"
                fi
            # ロックが古すぎる場合（15分以上）
            elif [[ -n "$lock_time" ]] && [[ $((current_time - lock_time)) -gt 900 ]]; then
                should_remove=true
                reason="lock expired (older than 15 minutes)"
            # ロック情報が不完全な場合
            elif [[ -z "$lock_pid" ]] || [[ -z "$lock_time" ]]; then
                should_remove=true
                reason="incomplete lock information"
            fi
            
            # 古いロックの削除を試行
            if [[ "$should_remove" == "true" ]]; then
                log_warn "Attempting to remove stale lock '$lock_name': $reason"
                
                # アトミックに削除を試行
                if rm -rf "$lock_file" 2>/dev/null; then
                    log_info "Successfully removed stale lock: $lock_name"
                    continue  # すぐに次の取得を試行
                else
                    log_debug "Lock was already handled by another process"
                fi
            else
                # ロックが有効な場合は詳細をログ出力
                if [[ $((elapsed % 30)) -eq 0 ]]; then  # 30秒ごとにログ出力
                    log_info "Waiting for lock '$lock_name' (held by PID: $lock_pid on $lock_host, age: $((current_time - lock_time))s)"
                fi
            fi
        fi
        
        sleep $retry_interval
        ((elapsed += retry_interval))
    done
    
    log_error "Failed to acquire lock '$lock_name' after ${timeout}s timeout"
    return 1
}

# 改良されたロック解放機能
release_lock() {
    local lock_name=$1
    local lock_file="${EXECUTION_LOCK_DIR}/${lock_name}.lock"
    local my_pid=$$
    
    if [[ -d "$lock_file" ]]; then
        # ロックの所有権を確認
        local lock_pid=""
        if [[ -f "${lock_file}/pid" ]]; then
            lock_pid=$(cat "${lock_file}/pid" 2>/dev/null || echo "")
        fi
        
        # 自分が所有者でない場合は警告
        if [[ -n "$lock_pid" ]] && [[ "$lock_pid" != "$my_pid" ]]; then
            log_warn "Attempting to release lock '$lock_name' owned by different process (PID: $lock_pid, current: $my_pid)"
        fi
        
        # ロックを削除
        if rm -rf "$lock_file" 2>/dev/null; then
            log_debug "Successfully released lock: $lock_name (PID: $my_pid)"
        else
            log_warn "Failed to remove lock directory: $lock_name"
        fi
    else
        log_debug "Lock already released or never acquired: $lock_name"
    fi
}

# ロック管理のクリーンアップ機能
cleanup_stale_locks() {
    local max_age=${1:-900}  # デフォルト15分
    local current_time
    current_time=$(date +%s)
    local cleaned_count=0
    
    log_info "Cleaning up stale locks older than ${max_age} seconds"
    
    if [[ ! -d "$EXECUTION_LOCK_DIR" ]]; then
        return 0
    fi
    
    # ロックディレクトリ内の全ロックをチェック
    find "$EXECUTION_LOCK_DIR" -name "*.lock" -type d 2>/dev/null | while IFS= read -r lock_file; do
        local lock_name
        lock_name=$(basename "$lock_file" .lock)
        local should_remove=false
        local reason=""
        
        # ロック情報を読み取り
        local lock_pid=""
        local lock_time=""
        local lock_host=""
        
        if [[ -f "${lock_file}/pid" ]]; then
            lock_pid=$(cat "${lock_file}/pid" 2>/dev/null || echo "")
        fi
        if [[ -f "${lock_file}/timestamp" ]]; then
            lock_time=$(cat "${lock_file}/timestamp" 2>/dev/null || echo "")
        fi
        if [[ -f "${lock_file}/host" ]]; then
            lock_host=$(cat "${lock_file}/host" 2>/dev/null || echo "")
        fi
        
        # クリーンアップ条件の判定
        if [[ -z "$lock_pid" ]] || [[ -z "$lock_time" ]]; then
            should_remove=true
            reason="incomplete lock information"
        elif [[ "$lock_host" == "$(hostname)" ]] && ! ps -p "$lock_pid" > /dev/null 2>&1; then
            should_remove=true
            reason="process $lock_pid no longer exists"
        elif [[ $((current_time - lock_time)) -gt $max_age ]]; then
            should_remove=true
            reason="lock expired (age: $((current_time - lock_time))s)"
        fi
        
        # 古いロックを削除
        if [[ "$should_remove" == "true" ]]; then
            if rm -rf "$lock_file" 2>/dev/null; then
                log_info "Cleaned up stale lock: $lock_name ($reason)"
                ((cleaned_count++))
            fi
        fi
    done
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned up $cleaned_count stale locks"
    else
        log_debug "No stale locks found"
    fi
}

# グローバル実行調整機能
check_global_processing_limit() {
    local max_concurrent=${1:-3}  # 最大同時実行数
    local current_count=0
    
    if [[ ! -d "$EXECUTION_LOCK_DIR" ]]; then
        return 0
    fi
    
    # アクティブなロック数をカウント
    find "$EXECUTION_LOCK_DIR" -name "*.lock" -type d 2>/dev/null | while IFS= read -r lock_file; do
        if [[ -f "${lock_file}/pid" ]]; then
            local lock_pid
            lock_pid=$(cat "${lock_file}/pid" 2>/dev/null || echo "")
            
            # プロセスが実際に存在するかチェック
            if [[ -n "$lock_pid" ]] && ps -p "$lock_pid" > /dev/null 2>&1; then
                ((current_count++))
            fi
        fi
    done
    
    if [[ $current_count -ge $max_concurrent ]]; then
        log_info "Global processing limit reached: $current_count/$max_concurrent active processes"
        return 1
    fi
    
    return 0
}

# エラーハンドリング用のクリーンアップトラップ設定
setup_lock_cleanup_trap() {
    local lock_name=$1
    
    # 既存のトラップを保存
    local existing_trap
    existing_trap=$(trap -p EXIT)
    
    # 新しいクリーンアップトラップを設定
    trap "
        log_debug 'Process $$ exiting, cleaning up lock: $lock_name'
        release_lock '$lock_name'
        $existing_trap
    " EXIT INT TERM
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
    issue_state=$(echo "$issue_data" | jq -r '.state // "unknown"')
    
    local keyword_type
    keyword_type=$(echo "$issue_data" | jq -r '.keyword_type // "implementation"')
    
    local found_keyword
    found_keyword=$(echo "$issue_data" | jq -r '.found_keyword // ""')
    
    log_info "Processing Issue #${issue_number}: ${issue_title}"
    log_info "Issue state: '$issue_state'"
    log_info "Keyword type: '$keyword_type'"
    log_info "Found keyword: '$found_keyword'"
    log_info "Issue data keys: $(echo "$issue_data" | jq -r 'keys | join(", ")')"
    
    # Issue状態のチェック（OPENまたはopenの場合のみ処理）
    if [[ "$issue_state" != "open" ]] && [[ "$issue_state" != "OPEN" ]] && [[ "$issue_state" != "unknown" ]]; then
        log_info "Skipping closed issue #${issue_number} (state: $issue_state)"
        return 0
    fi
    
    # stateフィールドがない場合はgh CLIで直接確認
    if [[ "$issue_state" == "unknown" ]]; then
        log_info "Issue state unknown, checking with gh CLI..."
        local gh_state
        gh_state=$(gh issue view "$issue_number" --repo "$REPO_NAME" --json state | jq -r '.state')
        log_info "GitHub state from gh CLI: '$gh_state'"
        
        if [[ "$gh_state" != "OPEN" ]]; then
            log_info "Skipping closed issue #${issue_number} (gh state: $gh_state)"
            return 0
        fi
    fi
    
    log_info "Proceeding to process OPEN issue #${issue_number}"
    
    # 実行履歴をチェック
    if check_execution_history "$issue_number" "$REPO_NAME"; then
        return 0
    fi
    
    # 古いロックのクリーンアップを実行
    cleanup_stale_locks
    
    # グローバル同時実行制限をチェック
    if ! check_global_processing_limit; then
        log_warn "Cannot process Issue #${issue_number}: global processing limit reached"
        return 1
    fi
    
    # ロックを取得
    local lock_name="${REPO_NAME//\//_}_issue_${issue_number}"
    if ! acquire_lock "$lock_name"; then
        log_error "Failed to acquire lock for Issue #${issue_number}"
        return 1
    fi
    
    # クリーンアップトラップを設定
    setup_lock_cleanup_trap "$lock_name"
    
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
    
    # キーワードタイプに基づいて処理を分岐
    if [[ "$keyword_type" == "reply" ]]; then
        # 返信モード: Claude で返信を生成してコメントを投稿
        log_info "Handling as reply request for Issue #${issue_number}"
        
        local reply_params
        reply_params=$(cat <<EOF
{
    "event_type": "reply",
    "repository": "$REPO_NAME",
    "issue_number": $issue_number,
    "issue_title": $(echo "$issue_title" | jq -Rs .),
    "issue_body": $(echo "$issue_body" | jq -Rs .),
    "issue_labels": $(echo "$issue_labels" | jq -Rs .),
    "found_keyword": $(echo "$found_keyword" | jq -Rs .)
}
EOF
        )
        
        local claude_reply="${CLAUDE_AUTO_HOME}/src/core/claude-reply.sh"
        
        if [[ -x "$claude_reply" ]]; then
            log_info "Executing Claude Reply for Issue #${issue_number}"
            
            if echo "$reply_params" | "$claude_reply"; then
                update_execution_history "$issue_number" "$REPO_NAME" "completed" "Reply posted successfully"
                send_slack_notification "reply_success" "$issue_number" "$issue_title" "$REPO_NAME"
            else
                update_execution_history "$issue_number" "$REPO_NAME" "failed" "Claude reply failed"
                send_slack_notification "reply_error" "$issue_number" "$issue_title" "$REPO_NAME"
            fi
        else
            log_error "Claude reply handler not found or not executable"
            update_execution_history "$issue_number" "$REPO_NAME" "failed" "Claude reply handler not available"
        fi
    elif [[ "$keyword_type" == "terminal" ]]; then
        # Terminal自動起動モード: Terminal を自動起動してClaude Code実行
        log_info "Handling as terminal execution request for Issue #${issue_number}"
        
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
    "base_branch": $(echo "$repo_config" | jq -r '.base_branch // "main"' | jq -Rs .),
    "found_keyword": $(echo "$found_keyword" | jq -Rs .),
    "execution_mode": "terminal"
}
EOF
        )
        
        local claude_executor="${CLAUDE_AUTO_HOME}/src/core/claude-executor.sh"
        
        if [[ -x "$claude_executor" ]]; then
            log_info "Executing Claude with Terminal auto-launch for Issue #${issue_number}"
            
            if echo "$execution_params" | "$claude_executor"; then
                update_execution_history "$issue_number" "$REPO_NAME" "completed" "Terminal session launched successfully"
                send_slack_notification "terminal_success" "$issue_number" "$issue_title" "$REPO_NAME"
            else
                update_execution_history "$issue_number" "$REPO_NAME" "failed" "Terminal execution failed"
                send_slack_notification "terminal_error" "$issue_number" "$issue_title" "$REPO_NAME"
            fi
        else
            log_error "Claude executor not found or not executable"
            update_execution_history "$issue_number" "$REPO_NAME" "failed" "Claude executor not available"
        fi
    else
        # 実装モード: 従来通りのClaude実行による実装
        log_info "Handling as implementation request for Issue #${issue_number}"
        
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
    "base_branch": $(echo "$repo_config" | jq -r '.base_branch // "main"' | jq -Rs .),
    "found_keyword": $(echo "$found_keyword" | jq -Rs .)
}
EOF
        )
        
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
    
    # 古いロックのクリーンアップを実行
    cleanup_stale_locks
    
    # グローバル同時実行制限をチェック
    if ! check_global_processing_limit; then
        log_warn "Cannot process PR #${pr_number}: global processing limit reached"
        return 1
    fi
    
    # ロックを取得
    local lock_name="${REPO_NAME//\//_}_pr_${pr_number}"
    if ! acquire_lock "$lock_name"; then
        log_error "Failed to acquire lock for PR #${pr_number}"
        return 1
    fi
    
    # クリーンアップトラップを設定
    setup_lock_cleanup_trap "$lock_name"
    
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