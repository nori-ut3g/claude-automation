#!/usr/bin/env bash

# monitor.sh - GitHubリポジトリを監視するメインプロセス
# 
# 使用方法:
#   ./src/core/monitor.sh

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/git-utils.sh"

# 定数
readonly PID_FILE="${CLAUDE_AUTO_HOME}/monitor.pid"
readonly STATE_FILE="${CLAUDE_AUTO_HOME}/monitor.state"
readonly GITHUB_API_BASE="https://api.github.com"

# グローバル変数
MONITORING_ENABLED=true
LAST_CHECK_TIMES=()

# シグナルハンドラー
handle_signal() {
    log_info "Received signal, shutting down gracefully..."
    MONITORING_ENABLED=false
    cleanup
    exit 0
}

# クリーンアップ処理
cleanup() {
    log_info "Cleaning up..."
    rm -f "$PID_FILE"
    save_state
}

# エラーハンドラー
handle_error() {
    local exit_code=$?
    log_error "An error occurred (exit code: $exit_code)"
    cleanup
    exit $exit_code
}

# 状態の保存
save_state() {
    if [[ ${#LAST_CHECK_TIMES[@]} -gt 0 ]]; then
        printf '%s\n' "${LAST_CHECK_TIMES[@]}" > "$STATE_FILE"
    fi
}

# 状態の読み込み
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        mapfile -t LAST_CHECK_TIMES < "$STATE_FILE"
    fi
}

# PIDファイルのチェック
check_pid_file() {
    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$PID_FILE")
        
        if ps -p "$old_pid" > /dev/null 2>&1; then
            log_error "Monitor is already running (PID: $old_pid)"
            exit 1
        else
            log_warn "Removing stale PID file"
            rm -f "$PID_FILE"
        fi
    fi
    
    echo $$ > "$PID_FILE"
}

# GitHub API呼び出し
github_api_call() {
    local endpoint=$1
    local method=${2:-GET}
    local data=${3:-}
    
    local url="${GITHUB_API_BASE}${endpoint}"
    local github_token
    github_token=$(get_config_value "github.token" "" "integrations")
    
    if [[ -z "$github_token" ]]; then
        log_error "GitHub token not configured"
        return 1
    fi
    
    local curl_opts=(
        -s
        -H "Accept: application/vnd.github.v3+json"
        -H "Authorization: token ${github_token}"
        -H "User-Agent: Claude-Automation-System"
    )
    
    if [[ "$method" != "GET" ]]; then
        curl_opts+=(-X "$method")
    fi
    
    if [[ -n "$data" ]]; then
        curl_opts+=(-d "$data")
    fi
    
    local response
    local http_code
    
    response=$(curl "${curl_opts[@]}" -w "\n%{http_code}" "$url")
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    
    # レート制限のチェック
    if [[ "$http_code" == "403" ]]; then
        local rate_limit_remaining
        rate_limit_remaining=$(curl -s -H "Authorization: token ${github_token}" \
            "${GITHUB_API_BASE}/rate_limit" | jq -r '.rate.remaining')
        
        if [[ "$rate_limit_remaining" == "0" ]]; then
            log_error "GitHub API rate limit exceeded"
            local reset_time
            reset_time=$(curl -s -H "Authorization: token ${github_token}" \
                "${GITHUB_API_BASE}/rate_limit" | jq -r '.rate.reset')
            local wait_time=$((reset_time - $(date +%s)))
            log_info "Waiting $wait_time seconds for rate limit reset..."
            sleep "$wait_time"
            return 1
        fi
    fi
    
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$response"
        return 0
    else
        log_error "GitHub API call failed (HTTP $http_code): $response"
        return 1
    fi
}

# リポジトリのIssue/PRをチェック
check_repository_events() {
    local repo_name=$1
    local repo_config=$2
    
    log_debug "Checking repository: $repo_name"
    
    # 設定から情報を取得
    local labels
    labels=$(echo "$repo_config" | jq -r '.labels[]?' | tr '\n' ',' | sed 's/,$//')
    
    local keywords
    keywords=$(echo "$repo_config" | jq -r '.keywords[]?')
    
    # 最後のチェック時刻を取得
    local last_check=""
    for check_entry in "${LAST_CHECK_TIMES[@]:-}"; do
        if [[ "$check_entry" =~ ^${repo_name}= ]]; then
            last_check="${check_entry#*=}"
            break
        fi
    done
    
    # 現在時刻
    local current_time
    current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Issue のチェック
    check_issues "$repo_name" "$labels" "$keywords" "$last_check"
    
    # Pull Request のチェック
    check_pull_requests "$repo_name" "$labels" "$keywords" "$last_check"
    
    # 最終チェック時刻を更新
    update_last_check_time "$repo_name" "$current_time"
}

# Issue のチェック
check_issues() {
    local repo_name=$1
    local labels=$2
    local keywords=$3
    local since=$4
    
    local query="/repos/${repo_name}/issues?state=open&sort=updated&direction=desc"
    
    if [[ -n "$labels" ]]; then
        query="${query}&labels=${labels}"
    fi
    
    if [[ -n "$since" ]]; then
        query="${query}&since=${since}"
    fi
    
    local issues
    if ! issues=$(github_api_call "$query"); then
        return 1
    fi
    
    # Issue を処理
    echo "$issues" | jq -c '.[] | select(.pull_request == null)' | while read -r issue; do
        local issue_number
        issue_number=$(echo "$issue" | jq -r '.number')
        
        local issue_title
        issue_title=$(echo "$issue" | jq -r '.title')
        
        local issue_body
        issue_body=$(echo "$issue" | jq -r '.body // ""')
        
        local issue_labels
        issue_labels=$(echo "$issue" | jq -r '.labels[].name' | tr '\n' ',')
        
        # キーワードチェック
        local should_process=false
        
        # ラベルが一致する場合
        if [[ -n "$labels" ]]; then
            should_process=true
        fi
        
        # キーワードが含まれる場合
        if [[ -n "$keywords" ]]; then
            while IFS= read -r keyword; do
                if [[ "$issue_body" == *"$keyword"* ]] || [[ "$issue_title" == *"$keyword"* ]]; then
                    should_process=true
                    break
                fi
            done <<< "$keywords"
        fi
        
        if [[ "$should_process" == "true" ]]; then
            log_info "Found matching issue: #${issue_number} - ${issue_title}"
            
            # イベントプロセッサーに渡す
            process_event "issue" "$repo_name" "$issue"
        fi
    done
}

# Pull Request のチェック
check_pull_requests() {
    local repo_name=$1
    local labels=$2
    local keywords=$3
    local since=$4
    
    local query="/repos/${repo_name}/pulls?state=open&sort=updated&direction=desc"
    
    local pulls
    if ! pulls=$(github_api_call "$query"); then
        return 1
    fi
    
    # PR を処理
    echo "$pulls" | jq -c '.[]' | while read -r pr; do
        local pr_number
        pr_number=$(echo "$pr" | jq -r '.number')
        
        local pr_title
        pr_title=$(echo "$pr" | jq -r '.title')
        
        local pr_body
        pr_body=$(echo "$pr" | jq -r '.body // ""')
        
        local updated_at
        updated_at=$(echo "$pr" | jq -r '.updated_at')
        
        # 最終チェック時刻より新しいか確認
        if [[ -n "$since" ]] && [[ "$updated_at" < "$since" ]]; then
            continue
        fi
        
        # PR の詳細情報を取得（ラベルなど）
        local pr_detail
        if ! pr_detail=$(github_api_call "/repos/${repo_name}/pulls/${pr_number}"); then
            continue
        fi
        
        local pr_labels
        pr_labels=$(echo "$pr_detail" | jq -r '.labels[].name' | tr '\n' ',')
        
        # キーワードチェック
        local should_process=false
        
        # ラベルが一致する場合
        if [[ -n "$labels" ]] && [[ "$pr_labels" == *"$labels"* ]]; then
            should_process=true
        fi
        
        # キーワードが含まれる場合
        if [[ -n "$keywords" ]]; then
            while IFS= read -r keyword; do
                if [[ "$pr_body" == *"$keyword"* ]] || [[ "$pr_title" == *"$keyword"* ]]; then
                    should_process=true
                    break
                fi
            done <<< "$keywords"
        fi
        
        if [[ "$should_process" == "true" ]]; then
            log_info "Found matching PR: #${pr_number} - ${pr_title}"
            
            # イベントプロセッサーに渡す
            process_event "pull_request" "$repo_name" "$pr_detail"
        fi
    done
}

# イベントの処理
process_event() {
    local event_type=$1
    local repo_name=$2
    local event_data=$3
    
    # イベントプロセッサーを呼び出す
    local event_processor="${CLAUDE_AUTO_HOME}/src/core/event-processor.sh"
    
    if [[ -x "$event_processor" ]]; then
        echo "$event_data" | "$event_processor" "$event_type" "$repo_name"
    else
        log_warn "Event processor not found or not executable: $event_processor"
        
        # 一時的にイベントをファイルに保存
        local event_file="${CLAUDE_AUTO_HOME}/pending_events/$(date +%s)_${event_type}_${repo_name//\//_}.json"
        mkdir -p "$(dirname "$event_file")"
        echo "$event_data" > "$event_file"
        log_info "Event saved to: $event_file"
    fi
}

# 最終チェック時刻の更新
update_last_check_time() {
    local repo_name=$1
    local check_time=$2
    
    # 既存のエントリを削除
    local new_times=()
    for check_entry in "${LAST_CHECK_TIMES[@]:-}"; do
        if [[ ! "$check_entry" =~ ^${repo_name}= ]]; then
            new_times+=("$check_entry")
        fi
    done
    
    # 新しいエントリを追加
    new_times+=("${repo_name}=${check_time}")
    
    LAST_CHECK_TIMES=("${new_times[@]}")
}

# Organization のリポジトリを取得
get_organization_repos() {
    local org_name=$1
    local page=1
    local repos=()
    
    while true; do
        local response
        if ! response=$(github_api_call "/orgs/${org_name}/repos?type=all&page=${page}&per_page=100"); then
            break
        fi
        
        local repo_count
        repo_count=$(echo "$response" | jq '. | length')
        
        if [[ "$repo_count" -eq 0 ]]; then
            break
        fi
        
        # リポジトリ名を抽出
        while IFS= read -r repo; do
            repos+=("$repo")
        done < <(echo "$response" | jq -r '.[].full_name')
        
        ((page++))
    done
    
    printf '%s\n' "${repos[@]}"
}

# メイン監視ループ
monitor_loop() {
    log_info "Starting monitoring loop"
    
    while [[ "$MONITORING_ENABLED" == "true" ]]; do
        # 設定をリロード
        reload_config
        
        # チェック間隔を取得
        local check_interval
        check_interval=$(get_config_value "default_settings.check_interval" "60" "repositories")
        
        # 有効なリポジトリを取得
        local repos=()
        while IFS= read -r repo; do
            if [[ -n "$repo" ]]; then
                repos+=("$repo")
            fi
        done < <(get_enabled_repositories)
        
        # Organization の処理
        local orgs_count
        orgs_count=$(get_config_array_length "organizations" "repositories")
        
        for ((i=0; i<orgs_count; i++)); do
            local org_enabled
            org_enabled=$(get_config_value "organizations[$i].enabled" "false" "repositories")
            
            if [[ "$org_enabled" == "true" ]]; then
                local org_name
                org_name=$(get_config_value "organizations[$i].name" "" "repositories")
                
                if [[ -n "$org_name" ]]; then
                    log_info "Fetching repositories for organization: $org_name"
                    
                    # 除外パターンを取得
                    local exclude_patterns=()
                    while IFS= read -r pattern; do
                        if [[ -n "$pattern" ]]; then
                            exclude_patterns+=("$pattern")
                        fi
                    done < <(get_config_array "organizations[$i].exclude_repos" "repositories")
                    
                    # Organization のリポジトリを取得
                    while IFS= read -r repo; do
                        local should_exclude=false
                        
                        # 除外パターンのチェック
                        for pattern in "${exclude_patterns[@]}"; do
                            if [[ "$repo" == $pattern ]]; then
                                should_exclude=true
                                break
                            fi
                        done
                        
                        if [[ "$should_exclude" == "false" ]]; then
                            repos+=("$repo")
                        fi
                    done < <(get_organization_repos "$org_name")
                fi
            fi
        done
        
        # 各リポジトリをチェック
        log_info "Checking ${#repos[@]} repositories"
        
        for repo in "${repos[@]}"; do
            # リポジトリ設定を取得
            local repo_config
            if repo_config=$(get_repository_config "$repo"); then
                check_repository_events "$repo" "$repo_config"
            else
                # デフォルト設定で処理
                local default_config
                default_config=$(cat <<EOF
{
  "labels": $(get_config_array "default_settings.default_labels" "repositories" | jq -R . | jq -s .),
  "keywords": $(get_config_array "default_settings.default_keywords" "repositories" | jq -R . | jq -s .),
  "branch_strategy": "$(get_config_value "default_settings.branch_strategy" "github-flow" "repositories")",
  "base_branch": "$(get_config_value "default_settings.base_branch" "main" "repositories")"
}
EOF
                )
                check_repository_events "$repo" "$default_config"
            fi
            
            # レート制限を考慮して少し待機
            sleep 1
        done
        
        # 状態を保存
        save_state
        
        # 次のチェックまで待機
        log_info "Waiting ${check_interval} seconds until next check..."
        sleep "$check_interval"
    done
}

# メイン処理
main() {
    # シグナルハンドラーの設定
    trap handle_signal SIGINT SIGTERM
    trap handle_error ERR
    
    # 初期化
    log_info "Claude Automation Monitor starting..."
    
    # 依存関係のチェック
    check_dependencies || exit 1
    
    # 設定の検証
    validate_config || exit 1
    
    # PIDファイルのチェック
    check_pid_file
    
    # GitHub認証の設定
    setup_github_auth || exit 1
    
    # 状態の読み込み
    load_state
    
    # 監視ループの開始
    monitor_loop
    
    # クリーンアップ
    cleanup
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi