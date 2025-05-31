#!/usr/bin/env bash

# github-client.sh - GitHub API拡張クライアント（gh CLI版）
# 
# 使用方法:
#   ./src/integrations/github-client.sh <action> [parameters...]
#   
# アクション:
#   create_pr <repo> <title> <body> <head> <base>
#   add_labels <repo> <issue_number> <labels...>
#   request_review <repo> <pr_number> <reviewers...>
#   merge_pr <repo> <pr_number> [merge_method]

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"

# gh CLIの認証状態確認
check_gh_auth() {
    if ! gh auth status >/dev/null 2>&1; then
        log_error "gh CLI is not authenticated. Please run 'gh auth login'"
        exit 1
    fi
}

# レート制限の処理
handle_rate_limit() {
    log_warn "GitHub API rate limit reached, checking reset time..."
    
    local rate_info
    rate_info=$(gh api rate_limit)
    
    local remaining
    local reset_time
    remaining=$(echo "$rate_info" | jq -r '.rate.remaining')
    reset_time=$(echo "$rate_info" | jq -r '.rate.reset')
    
    if [[ "$remaining" == "0" ]]; then
        local current_time=$(date +%s)
        local wait_time=$((reset_time - current_time + 5))
        
        if [[ $wait_time -gt 0 ]]; then
            log_info "Waiting ${wait_time} seconds for rate limit reset..."
            sleep "$wait_time"
        fi
    fi
}

# Pull Request の作成（拡張版）
create_pull_request() {
    local repo=$1
    local title=$2
    local body=$3
    local head=$4
    local base=$5
    local draft=${6:-false}
    
    log_info "Creating pull request in ${repo}..."
    
    # PR設定の取得
    local pr_config
    pr_config=$(get_config_object "github.pr_settings" "integrations")
    
    local auto_merge
    auto_merge=$(echo "$pr_config" | jq -r '.auto_merge // false')
    
    # PRの作成
    local gh_opts=()
    gh_opts+=("--repo" "$repo")
    gh_opts+=("--title" "$title")
    gh_opts+=("--body" "$body")
    gh_opts+=("--head" "$head")
    gh_opts+=("--base" "$base")
    
    if [[ "$draft" == "true" ]]; then
        gh_opts+=("--draft")
    fi
    
    local pr_url
    if pr_url=$(gh pr create "${gh_opts[@]}"); then
        log_info "Created PR: ${pr_url}"
        
        # PR番号を取得
        local pr_number
        pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$')
        
        # 自動マージの設定
        if [[ "$auto_merge" == "true" ]]; then
            enable_auto_merge "$repo" "$pr_number"
        fi
        
        # PR情報を取得して返す
        gh pr view "$pr_number" --repo "$repo" --json number,url,title
        return 0
    else
        return 1
    fi
}

# ラベルの追加
add_labels() {
    local repo=$1
    local issue_number=$2
    shift 2
    local labels=("$@")
    
    log_info "Adding labels to ${repo}#${issue_number}..."
    
    # ラベルをカンマ区切りに変換
    local label_list
    label_list=$(IFS=,; echo "${labels[*]}")
    
    if gh issue edit "$issue_number" --repo "$repo" --add-label "$label_list"; then
        log_info "Labels added successfully"
        return 0
    else
        return 1
    fi
}

# レビュアーのリクエスト
request_review() {
    local repo=$1
    local pr_number=$2
    shift 2
    local reviewers=("$@")
    
    log_info "Requesting review for ${repo}#${pr_number}..."
    
    # レビュアーをカンマ区切りに変換
    local reviewer_list
    reviewer_list=$(IFS=,; echo "${reviewers[*]}")
    
    if gh pr edit "$pr_number" --repo "$repo" --add-reviewer "$reviewer_list"; then
        log_info "Review requested successfully"
        return 0
    else
        return 1
    fi
}

# PRのマージ
merge_pull_request() {
    local repo=$1
    local pr_number=$2
    local merge_method=${3:-merge}  # merge, squash, rebase
    
    log_info "Merging PR ${repo}#${pr_number} using ${merge_method}..."
    
    # マージ可能性のチェック
    local pr_info
    pr_info=$(gh pr view "$pr_number" --repo "$repo" --json mergeable,mergeStateStatus)
    
    local mergeable
    local merge_state
    mergeable=$(echo "$pr_info" | jq -r '.mergeable')
    merge_state=$(echo "$pr_info" | jq -r '.mergeStateStatus')
    
    if [[ "$mergeable" != "MERGEABLE" ]]; then
        log_error "PR is not mergeable (state: ${merge_state})"
        return 1
    fi
    
    # ブランチ削除設定の確認
    local delete_branch
    delete_branch=$(get_config_value "github.pr_settings.delete_branch" "true" "integrations")
    
    # マージオプションの設定
    local merge_opts=()
    merge_opts+=("--repo" "$repo")
    
    case "$merge_method" in
        "squash")
            merge_opts+=("--squash")
            ;;
        "rebase")
            merge_opts+=("--rebase")
            ;;
        "merge"|*)
            merge_opts+=("--merge")
            ;;
    esac
    
    if [[ "$delete_branch" == "true" ]]; then
        merge_opts+=("--delete-branch")
    fi
    
    # マージの実行
    if gh pr merge "$pr_number" "${merge_opts[@]}" --yes; then
        log_info "PR merged successfully"
        return 0
    else
        return 1
    fi
}

# 自動マージの有効化
enable_auto_merge() {
    local repo=$1
    local pr_number=$2
    
    log_info "Enabling auto-merge for ${repo}#${pr_number}..."
    
    # gh CLIでは直接auto-mergeを有効化できるコマンドがある
    if gh pr merge "$pr_number" --repo "$repo" --auto --squash; then
        log_info "Auto-merge enabled successfully"
        return 0
    else
        log_warn "Failed to enable auto-merge"
        return 1
    fi
}

# チェックランの状態取得
get_check_status() {
    local repo=$1
    local ref=$2
    
    log_info "Getting check status for ${repo} @ ${ref}..."
    
    local checks
    if ! checks=$(gh pr checks "$ref" --repo "$repo" 2>/dev/null || gh api "repos/${repo}/commits/${ref}/check-runs"); then
        return 1
    fi
    
    # テキスト形式で出力された場合の処理
    if [[ ! "$checks" =~ ^{.*}$ ]]; then
        echo "$checks"
        return 0
    fi
    
    # JSON形式の場合
    local total_count
    local success_count
    local failure_count
    
    total_count=$(echo "$checks" | jq -r '.total_count')
    success_count=$(echo "$checks" | jq -r '[.check_runs[] | select(.conclusion == "success")] | length')
    failure_count=$(echo "$checks" | jq -r '[.check_runs[] | select(.conclusion == "failure")] | length')
    
    echo "Total: ${total_count}, Success: ${success_count}, Failure: ${failure_count}"
    
    if [[ $failure_count -gt 0 ]]; then
        return 1
    else
        return 0
    fi
}

# ワークフローの実行
trigger_workflow() {
    local repo=$1
    local workflow_id=$2
    local ref=${3:-main}
    local inputs=${4:-"{}"}
    
    log_info "Triggering workflow ${workflow_id} in ${repo}..."
    
    # gh workflowコマンドを使用
    local workflow_opts=()
    workflow_opts+=("--repo" "$repo")
    workflow_opts+=("--ref" "$ref")
    
    # 入力パラメータの処理
    if [[ "$inputs" != "{}" ]]; then
        # inputsをkey=value形式に変換
        local input_args
        input_args=$(echo "$inputs" | jq -r 'to_entries | .[] | "--field \(.key)=\(.value)"' | tr '\n' ' ')
        eval "workflow_opts+=($input_args)"
    fi
    
    if gh workflow run "$workflow_id" "${workflow_opts[@]}"; then
        log_info "Workflow triggered successfully"
        return 0
    else
        return 1
    fi
}

# リリースの作成
create_release() {
    local repo=$1
    local tag_name=$2
    local name=$3
    local body=$4
    local draft=${5:-false}
    local prerelease=${6:-false}
    
    log_info "Creating release ${tag_name} in ${repo}..."
    
    local release_opts=()
    release_opts+=("--repo" "$repo")
    release_opts+=("--title" "$name")
    release_opts+=("--notes" "$body")
    
    if [[ "$draft" == "true" ]]; then
        release_opts+=("--draft")
    fi
    
    if [[ "$prerelease" == "true" ]]; then
        release_opts+=("--prerelease")
    fi
    
    if gh release create "$tag_name" "${release_opts[@]}"; then
        log_info "Release created successfully"
        return 0
    else
        return 1
    fi
}

# メイン処理
main() {
    local action="${1:-}"
    
    if [[ -z "$action" ]]; then
        log_error "Usage: $0 <action> [parameters...]"
        exit 1
    fi
    
    # gh CLIの認証確認
    check_gh_auth
    
    case "$action" in
        "create_pr")
            create_pull_request "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-false}"
            ;;
        "add_labels")
            shift
            add_labels "$@"
            ;;
        "request_review")
            shift
            request_review "$@"
            ;;
        "merge_pr")
            merge_pull_request "${2:-}" "${3:-}" "${4:-merge}"
            ;;
        "check_status")
            get_check_status "${2:-}" "${3:-}"
            ;;
        "trigger_workflow")
            trigger_workflow "${2:-}" "${3:-}" "${4:-main}" "${5:-{}}"
            ;;
        "create_release")
            create_release "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-false}" "${7:-false}"
            ;;
        *)
            log_error "Unknown action: $action"
            exit 1
            ;;
    esac
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi