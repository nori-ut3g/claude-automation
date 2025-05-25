#!/usr/bin/env bash

# github-client.sh - GitHub API拡張クライアント
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

# GitHub API設定
GITHUB_TOKEN=""
GITHUB_API_BASE=""

# GitHub設定の読み込み
load_github_config() {
    local github_config
    github_config=$(get_github_config)
    
    GITHUB_TOKEN=$(echo "$github_config" | jq -r '.token // ""')
    GITHUB_API_BASE=$(echo "$github_config" | jq -r '.api_base // "https://api.github.com"')
    
    if [[ -z "$GITHUB_TOKEN" ]]; then
        log_error "GitHub token is not configured"
        exit 1
    fi
}

# GitHub API呼び出し（既存のものを拡張）
github_api_call() {
    local endpoint=$1
    local method=${2:-GET}
    local data=${3:-}
    
    local url="${GITHUB_API_BASE}${endpoint}"
    
    local curl_opts=(
        -s
        -H "Accept: application/vnd.github.v3+json"
        -H "Authorization: token ${GITHUB_TOKEN}"
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
    
    # レート制限のチェックと処理
    if [[ "$http_code" == "403" ]] || [[ "$http_code" == "429" ]]; then
        handle_rate_limit
        # リトライ
        response=$(curl "${curl_opts[@]}" -w "\n%{http_code}" "$url")
        http_code=$(echo "$response" | tail -n1)
        response=$(echo "$response" | sed '$d')
    fi
    
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$response"
        return 0
    else
        log_error "GitHub API call failed (HTTP $http_code): $response"
        return 1
    fi
}

# レート制限の処理
handle_rate_limit() {
    log_warn "GitHub API rate limit reached, checking reset time..."
    
    local rate_limit_response
    rate_limit_response=$(curl -s \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "${GITHUB_API_BASE}/rate_limit")
    
    local remaining
    local reset_time
    remaining=$(echo "$rate_limit_response" | jq -r '.rate.remaining')
    reset_time=$(echo "$rate_limit_response" | jq -r '.rate.reset')
    
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
    
    # PRデータの構築
    local pr_data
    pr_data=$(jq -n \
        --arg title "$title" \
        --arg body "$body" \
        --arg head "$head" \
        --arg base "$base" \
        --arg draft "$draft" \
        '{
            title: $title,
            body: $body,
            head: $head,
            base: $base,
            draft: ($draft == "true")
        }')
    
    # PRの作成
    local response
    if response=$(github_api_call "/repos/${repo}/pulls" "POST" "$pr_data"); then
        local pr_number
        local pr_url
        pr_number=$(echo "$response" | jq -r '.number')
        pr_url=$(echo "$response" | jq -r '.html_url')
        
        log_info "Created PR #${pr_number}: ${pr_url}"
        
        # 自動マージの設定
        if [[ "$auto_merge" == "true" ]]; then
            enable_auto_merge "$repo" "$pr_number"
        fi
        
        echo "$response"
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
    
    # ラベルデータの構築
    local label_data
    label_data=$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s '{labels: .}')
    
    if github_api_call "/repos/${repo}/issues/${issue_number}/labels" "POST" "$label_data" > /dev/null; then
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
    
    # レビュアーデータの構築
    local reviewer_data
    reviewer_data=$(printf '%s\n' "${reviewers[@]}" | jq -R . | jq -s '{reviewers: .}')
    
    if github_api_call "/repos/${repo}/pulls/${pr_number}/requested_reviewers" "POST" "$reviewer_data" > /dev/null; then
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
    if ! pr_info=$(github_api_call "/repos/${repo}/pulls/${pr_number}"); then
        return 1
    fi
    
    local mergeable
    local merge_state
    mergeable=$(echo "$pr_info" | jq -r '.mergeable')
    merge_state=$(echo "$pr_info" | jq -r '.mergeable_state')
    
    if [[ "$mergeable" != "true" ]]; then
        log_error "PR is not mergeable (state: ${merge_state})"
        return 1
    fi
    
    # マージデータの構築
    local merge_data
    merge_data=$(jq -n --arg method "$merge_method" '{merge_method: $method}')
    
    # ブランチ削除設定の確認
    local delete_branch
    delete_branch=$(get_config_value "github.pr_settings.delete_branch" "true" "integrations")
    
    if [[ "$delete_branch" == "true" ]]; then
        merge_data=$(echo "$merge_data" | jq '.delete_branch_on_merge = true')
    fi
    
    # マージの実行
    if github_api_call "/repos/${repo}/pulls/${pr_number}/merge" "PUT" "$merge_data" > /dev/null; then
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
    
    # GraphQL APIを使用（REST APIでは利用不可）
    local query
    query=$(cat <<EOF
mutation {
  enablePullRequestAutoMerge(input: {
    pullRequestId: "${pr_number}",
    mergeMethod: SQUASH
  }) {
    pullRequest {
      autoMergeRequest {
        enabledAt
        enabledBy {
          login
        }
      }
    }
  }
}
EOF
    )
    
    log_warn "Auto-merge requires GraphQL API (not implemented in this version)"
}

# チェックランの状態取得
get_check_status() {
    local repo=$1
    local ref=$2
    
    log_info "Getting check status for ${repo} @ ${ref}..."
    
    local check_runs
    if ! check_runs=$(github_api_call "/repos/${repo}/commits/${ref}/check-runs"); then
        return 1
    fi
    
    local total_count
    local success_count
    local failure_count
    
    total_count=$(echo "$check_runs" | jq -r '.total_count')
    success_count=$(echo "$check_runs" | jq -r '[.check_runs[] | select(.conclusion == "success")] | length')
    failure_count=$(echo "$check_runs" | jq -r '[.check_runs[] | select(.conclusion == "failure")] | length')
    
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
    
    local workflow_data
    workflow_data=$(jq -n \
        --arg ref "$ref" \
        --argjson inputs "$inputs" \
        '{
            ref: $ref,
            inputs: $inputs
        }')
    
    if github_api_call "/repos/${repo}/actions/workflows/${workflow_id}/dispatches" "POST" "$workflow_data"; then
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
    
    local release_data
    release_data=$(jq -n \
        --arg tag "$tag_name" \
        --arg name "$name" \
        --arg body "$body" \
        --arg draft "$draft" \
        --arg prerelease "$prerelease" \
        '{
            tag_name: $tag,
            name: $name,
            body: $body,
            draft: ($draft == "true"),
            prerelease: ($prerelease == "true")
        }')
    
    if github_api_call "/repos/${repo}/releases" "POST" "$release_data" > /dev/null; then
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
    
    # GitHub設定の読み込み
    load_github_config
    
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