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
        # Bash 3.x互換の読み込み方法
        while IFS= read -r line; do
            LAST_CHECK_TIMES+=("$line")
        done < "$STATE_FILE"
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

# gh CLI認証チェック
check_gh_auth() {
    if ! gh auth status >/dev/null 2>&1; then
        log_error "gh CLI is not authenticated. Please run 'gh auth login'"
        return 1
    fi
    return 0
}

# リポジトリのIssue/PRをチェック
check_repository_events() {
    local repo_name=$1
    local repo_config=$2
    
    # 設定から情報を取得
    local labels
    labels=$(echo "$repo_config" | jq -r '.labels[]?' | tr '\n' ',' | sed 's/,$//')
    
    # 実装キーワード、返信キーワード、Terminalキーワードを取得
    local impl_keywords
    impl_keywords=$(echo "$repo_config" | jq -r '.implementation_keywords[]?' 2>/dev/null || echo "")
    
    local reply_keywords  
    reply_keywords=$(echo "$repo_config" | jq -r '.reply_keywords[]?' 2>/dev/null || echo "")
    
    local terminal_keywords
    terminal_keywords=$(echo "$repo_config" | jq -r '.terminal_keywords[]?' 2>/dev/null || echo "")
    
    # 後方互換性のため、古いkeywords設定もチェック
    local legacy_keywords
    legacy_keywords=$(echo "$repo_config" | jq -r '.keywords[]?' 2>/dev/null || echo "")
    
    # デフォルト設定から取得
    if [[ -z "$impl_keywords" ]]; then
        impl_keywords=$(get_config_array "implementation_keywords" "repositories" | jq -r '.[]?')
    fi
    
    if [[ -z "$reply_keywords" ]]; then
        reply_keywords=$(get_config_array "reply_keywords" "repositories" | jq -r '.[]?')
    fi
    
    if [[ -z "$terminal_keywords" ]]; then
        terminal_keywords=$(get_config_array "terminal_keywords" "repositories" | jq -r '.[]?')
    fi
    
    log_info "Checking repository: $repo_name"
    log_info "Looking for labels: $labels"
    log_info "Looking for implementation keywords: $impl_keywords"
    log_info "Looking for reply keywords: $reply_keywords"
    log_info "Looking for terminal keywords: $terminal_keywords"
    
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
    check_issues "$repo_name" "$labels" "$impl_keywords" "$reply_keywords" "$terminal_keywords" "$last_check"
    
    # Issue コメントのチェック（Issue処理後に実行）
    check_issue_comments "$repo_name" "$labels" "$impl_keywords" "$reply_keywords" "$terminal_keywords"
    
    # Pull Request のチェック
    check_pull_requests "$repo_name" "$labels" "$impl_keywords" "$reply_keywords" "$terminal_keywords" "$last_check"
    
    # 最終チェック時刻を更新
    update_last_check_time "$repo_name" "$current_time"
}

# Issue のチェック
check_issues() {
    local repo_name=$1
    local labels=$2
    local impl_keywords=$3
    local reply_keywords=$4
    local terminal_keywords=$5
    local since=$6
    
    # gh CLIのオプションを構築
    local gh_opts=()
    gh_opts+=("--repo" "$repo_name")
    gh_opts+=("--state" "open")
    gh_opts+=("--json" "number,title,body,labels,updatedAt,state")
    
    # ラベル検索は実行せず、すべてのIssueを取得してから後でフィルタリング
    # gh CLIの--labelオプションはAND検索なので、OR検索が必要な場合は後でフィルタリング
    
    local issues
    if ! issues=$(gh issue list "${gh_opts[@]}"); then
        log_error "Failed to fetch issues for $repo_name"
        return 1
    fi
    
    local issue_count
    issue_count=$(echo "$issues" | jq '. | length')
    log_info "Found $issue_count open issues in $repo_name"
    
    # Issue を処理
    echo "$issues" | jq -c '.[]' | while read -r issue; do
        local issue_number
        issue_number=$(echo "$issue" | jq -r '.number')
        
        local issue_title
        issue_title=$(echo "$issue" | jq -r '.title')
        
        local issue_body
        issue_body=$(echo "$issue" | jq -r '.body // ""')
        
        local issue_labels
        issue_labels=$(echo "$issue" | jq -r '.labels[]?.name // ""' | tr '\n' ',')
        
        log_info "Processing issue #${issue_number}: $issue_title"
        log_info "Issue labels: $issue_labels"
        log_info "Issue body preview: ${issue_body:0:50}..."
        
        # キーワードチェック
        local should_process=false
        local keyword_type=""
        local found_keyword=""
        
        # ラベルが一致する場合（OR検索）
        if [[ -n "$labels" ]]; then
            IFS=',' read -ra label_array <<< "$labels"
            for target_label in "${label_array[@]}"; do
                target_label=$(echo "$target_label" | xargs)  # trim whitespace
                if [[ "$issue_labels" == *"$target_label"* ]]; then
                    should_process=true
                    break
                fi
            done
        fi
        
        # 実装キーワードをチェック
        if [[ "$should_process" == "true" ]] && [[ -n "$impl_keywords" ]]; then
            while IFS= read -r keyword; do
                keyword=$(echo "$keyword" | xargs)  # trim whitespace
                if [[ -n "$keyword" ]] && ([[ "$issue_body" == *"$keyword"* ]] || [[ "$issue_title" == *"$keyword"* ]]); then
                    log_info "Found implementation keyword '$keyword' in issue #${issue_number}"
                    keyword_type="implementation"
                    found_keyword="$keyword"
                    break
                fi
            done <<< "$impl_keywords"
        fi
        
        # 返信キーワードをチェック (実装キーワードが見つからなかった場合)
        if [[ "$should_process" == "true" ]] && [[ -z "$keyword_type" ]] && [[ -n "$reply_keywords" ]]; then
            while IFS= read -r keyword; do
                keyword=$(echo "$keyword" | xargs)  # trim whitespace
                if [[ -n "$keyword" ]] && ([[ "$issue_body" == *"$keyword"* ]] || [[ "$issue_title" == *"$keyword"* ]]); then
                    log_info "Found reply keyword '$keyword' in issue #${issue_number}"
                    keyword_type="reply"
                    found_keyword="$keyword"
                    break
                fi
            done <<< "$reply_keywords"
        fi
        
        # Terminalキーワードをチェック (他のキーワードが見つからなかった場合)
        if [[ "$should_process" == "true" ]] && [[ -z "$keyword_type" ]] && [[ -n "$terminal_keywords" ]]; then
            while IFS= read -r keyword; do
                keyword=$(echo "$keyword" | xargs)  # trim whitespace
                if [[ -n "$keyword" ]] && ([[ "$issue_body" == *"$keyword"* ]] || [[ "$issue_title" == *"$keyword"* ]]); then
                    log_info "Found terminal keyword '$keyword' in issue #${issue_number}"
                    keyword_type="terminal"
                    found_keyword="$keyword"
                    break
                fi
            done <<< "$terminal_keywords"
        fi
        
        # ラベルのみでキーワードがない場合は、デフォルトで実装として扱う
        if [[ "$should_process" == "true" ]] && [[ -z "$keyword_type" ]]; then
            keyword_type="implementation"
            log_info "No keywords found, treating as implementation request"
        fi
        
        if [[ "$should_process" == "true" ]] && [[ -n "$keyword_type" ]]; then
            log_info "Found matching issue: #${issue_number} - ${issue_title} (type: $keyword_type)"
            
            # キーワードタイプを Issue データに追加
            local enhanced_issue
            enhanced_issue=$(echo "$issue" | jq --arg kt "$keyword_type" --arg fk "$found_keyword" '. + {keyword_type: $kt, found_keyword: $fk}')
            
            # イベントプロセッサーに渡す
            process_event "issue" "$repo_name" "$enhanced_issue"
        fi
    done
}

# Issue コメントのチェック
check_issue_comments() {
    local repo_name=$1
    local labels=$2
    local impl_keywords=$3
    local reply_keywords=$4
    local terminal_keywords=$5
    
    log_info "Checking comments for issues in $repo_name"
    
    # コメント追跡ファイル
    local comment_tracker="${CLAUDE_AUTO_HOME}/comment_tracker.json"
    
    # 追跡ファイルが存在しない場合は作成
    if [[ ! -f "$comment_tracker" ]]; then
        echo '{"repositories":{}}' > "$comment_tracker"
    fi
    
    # このリポジトリの最後のチェック時刻を取得
    local last_check
    last_check=$(jq -r ".repositories[\"$repo_name\"].last_check // \"1970-01-01T00:00:00Z\"" "$comment_tracker")
    
    # claude-autoラベルのついたオープンIssueを取得
    local issues
    if ! issues=$(gh issue list --repo "$repo_name" --state open --label "claude-auto" --json number,title,labels); then
        log_error "Failed to fetch issues for comment check"
        return 1
    fi
    
    # 各Issueのコメントをチェック
    echo "$issues" | jq -c '.[]' | while read -r issue; do
        local issue_number
        issue_number=$(echo "$issue" | jq -r '.number')
        
        # このIssueのコメントを取得
        local comments
        if ! comments=$(gh api "repos/$repo_name/issues/$issue_number/comments" --jq '.[] | select(.created_at > "'"$last_check"'")'); then
            log_warn "Failed to fetch comments for issue #$issue_number"
            continue
        fi
        
        # 新しいコメントがある場合のみ処理
        if [[ -n "$comments" ]]; then
            echo "$comments" | jq -s '.' | jq -c '.[]' | while read -r comment; do
                local comment_body
                comment_body=$(echo "$comment" | jq -r '.body')
                local comment_author
                comment_author=$(echo "$comment" | jq -r '.user.login')
                local comment_created
                comment_created=$(echo "$comment" | jq -r '.created_at')
                
                log_info "Checking comment on issue #$issue_number by $comment_author"
                
                # キーワードチェック
                local keyword_type=""
                local found_keyword=""
                
                # 実装キーワードをチェック
                if [[ -n "$impl_keywords" ]]; then
                    while IFS= read -r keyword; do
                        keyword=$(echo "$keyword" | xargs)
                        if [[ -n "$keyword" ]] && [[ "$comment_body" == *"$keyword"* ]]; then
                            log_info "Found implementation keyword '$keyword' in comment on issue #$issue_number"
                            keyword_type="implementation"
                            found_keyword="$keyword"
                            break
                        fi
                    done <<< "$impl_keywords"
                fi
                
                # 返信キーワードをチェック
                if [[ -z "$keyword_type" ]] && [[ -n "$reply_keywords" ]]; then
                    while IFS= read -r keyword; do
                        keyword=$(echo "$keyword" | xargs)
                        if [[ -n "$keyword" ]] && [[ "$comment_body" == *"$keyword"* ]]; then
                            log_info "Found reply keyword '$keyword' in comment on issue #$issue_number"
                            keyword_type="reply"
                            found_keyword="$keyword"
                            break
                        fi
                    done <<< "$reply_keywords"
                fi
                
                # Terminalキーワードをチェック
                if [[ -z "$keyword_type" ]] && [[ -n "$terminal_keywords" ]]; then
                    while IFS= read -r keyword; do
                        keyword=$(echo "$keyword" | xargs)
                        if [[ -n "$keyword" ]] && [[ "$comment_body" == *"$keyword"* ]]; then
                            log_info "Found terminal keyword '$keyword' in comment on issue #$issue_number"
                            keyword_type="terminal"
                            found_keyword="$keyword"
                            break
                        fi
                    done <<< "$terminal_keywords"
                fi
                
                # キーワードが見つかった場合
                if [[ -n "$keyword_type" ]]; then
                    # Issueの詳細情報を取得
                    local issue_detail
                    if ! issue_detail=$(gh issue view "$issue_number" --repo "$repo_name" --json number,title,body,labels,state); then
                        log_error "Failed to fetch issue details for #$issue_number"
                        continue
                    fi
                    
                    # コメント情報を追加
                    local enhanced_issue
                    enhanced_issue=$(echo "$issue_detail" | jq \
                        --arg kt "$keyword_type" \
                        --arg fk "$found_keyword" \
                        --arg cb "$comment_body" \
                        --arg ca "$comment_author" \
                        --arg cc "$comment_created" \
                        '. + {
                            keyword_type: $kt,
                            found_keyword: $fk,
                            trigger_comment: {
                                body: $cb,
                                author: $ca,
                                created_at: $cc
                            }
                        }')
                    
                    log_info "Processing comment-triggered event for issue #$issue_number (type: $keyword_type)"
                    process_event "issue" "$repo_name" "$enhanced_issue"
                fi
            done
        fi
    done
    
    # 最後のチェック時刻を更新
    local current_time
    current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local temp_file="${comment_tracker}.tmp"
    jq --arg repo "$repo_name" --arg time "$current_time" \
        '.repositories[$repo] = {last_check: $time}' "$comment_tracker" > "$temp_file" && \
        mv "$temp_file" "$comment_tracker"
}

# Pull Request のチェック
check_pull_requests() {
    local repo_name=$1
    local labels=$2
    local impl_keywords=$3
    local reply_keywords=$4
    local terminal_keywords=$5
    local since=$6
    
    # gh CLIのオプションを構築
    local gh_opts=()
    gh_opts+=("--repo" "$repo_name")
    gh_opts+=("--state" "open")
    gh_opts+=("--json" "number,title,body,labels,updatedAt,state")
    
    local pulls
    if ! pulls=$(gh pr list "${gh_opts[@]}"); then
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
        updated_at=$(echo "$pr" | jq -r '.updatedAt')
        
        # 最終チェック時刻より新しいか確認
        if [[ -n "$since" ]] && [[ "$updated_at" < "$since" ]]; then
            continue
        fi
        
        local pr_labels
        pr_labels=$(echo "$pr" | jq -r '.labels[]?.name // ""' | tr '\n' ',')
        
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
            process_event "pull_request" "$repo_name" "$pr"
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
        # バックグラウンドで非同期実行
        (
            echo "$event_data" | "$event_processor" "$event_type" "$repo_name"
        ) &
        
        local pid=$!
        log_info "Started event processor in background (PID: $pid) for $event_type in $repo_name"
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
    
    # gh CLIでOrganizationのリポジトリを取得
    if gh repo list "$org_name" --limit 1000 --json nameWithOwner | jq -r '.[].nameWithOwner'; then
        return 0
    else
        log_error "Failed to get repositories for organization: $org_name"
        return 1
    fi
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
                local default_labels default_keywords default_branch_strategy default_base_branch
                default_labels=$(get_config_array "default_settings.default_labels" "repositories" | jq -R . | jq -s .)
                default_keywords=$(get_config_array "default_settings.default_keywords" "repositories" | jq -R . | jq -s .)
                default_branch_strategy=$(get_config_value "default_settings.branch_strategy" "github-flow" "repositories")
                default_base_branch=$(get_config_value "default_settings.base_branch" "main" "repositories")
                
                default_config=$(jq -nc \
                    --argjson labels "$default_labels" \
                    --argjson keywords "$default_keywords" \
                    --arg branch_strategy "$default_branch_strategy" \
                    --arg base_branch "$default_base_branch" \
                    '{
                        labels: $labels,
                        keywords: $keywords,
                        branch_strategy: $branch_strategy,
                        base_branch: $base_branch
                    }')
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
    
    # gh CLI認証のチェック
    check_gh_auth || exit 1
    
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