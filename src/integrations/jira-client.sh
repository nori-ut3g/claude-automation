#!/usr/bin/env bash

# jira-client.sh - Jira連携クライアント
# 
# 使用方法:
#   ./src/integrations/jira-client.sh <action> [parameters...]
#   
# アクション:
#   create_issue <github_issue_data>
#   update_status <jira_issue_key> <status>
#   add_comment <jira_issue_key> <comment>
#   sync_from_github <github_issue_data>

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"

# Jira設定
JIRA_CONFIG=""
JIRA_BASE_URL=""
JIRA_USERNAME=""
JIRA_API_TOKEN=""

# Jira設定の読み込み
load_jira_config() {
    JIRA_CONFIG=$(get_jira_config)
    
    local enabled
    enabled=$(echo "$JIRA_CONFIG" | jq -r '.enabled // false')
    
    if [[ "$enabled" != "true" ]]; then
        log_debug "Jira integration is disabled"
        exit 0
    fi
    
    JIRA_BASE_URL=$(echo "$JIRA_CONFIG" | jq -r '.base_url // ""')
    JIRA_USERNAME=$(echo "$JIRA_CONFIG" | jq -r '.username // ""')
    JIRA_API_TOKEN=$(echo "$JIRA_CONFIG" | jq -r '.api_token // ""')
    
    if [[ -z "$JIRA_BASE_URL" ]] || [[ -z "$JIRA_USERNAME" ]] || [[ -z "$JIRA_API_TOKEN" ]]; then
        log_error "Jira configuration is incomplete"
        exit 1
    fi
}

# Jira API呼び出し
jira_api_call() {
    local endpoint=$1
    local method=${2:-GET}
    local data=${3:-}
    
    local url="${JIRA_BASE_URL}/rest/api/3${endpoint}"
    local auth
    auth=$(echo -n "${JIRA_USERNAME}:${JIRA_API_TOKEN}" | base64)
    
    local curl_opts=(
        -s
        -H "Authorization: Basic ${auth}"
        -H "Accept: application/json"
        -H "Content-Type: application/json"
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
    
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$response"
        return 0
    else
        log_error "Jira API call failed (HTTP $http_code): $response"
        return 1
    fi
}

# プロジェクトキーの取得
get_project_key() {
    local repository=$1
    local default_project
    default_project=$(echo "$JIRA_CONFIG" | jq -r '.default_project // "DEV"')
    
    # プロジェクトマッピングから検索
    local mapped_project
    mapped_project=$(echo "$JIRA_CONFIG" | jq -r --arg repo "$repository" '.project_mapping[$repo] // empty')
    
    if [[ -n "$mapped_project" ]]; then
        echo "$mapped_project"
    else
        # ワイルドカードマッピングをチェック
        local org_name="${repository%%/*}"
        mapped_project=$(echo "$JIRA_CONFIG" | jq -r --arg pattern "${org_name}/*" '.project_mapping[$pattern] // empty')
        
        if [[ -n "$mapped_project" ]]; then
            echo "$mapped_project"
        else
            echo "$default_project"
        fi
    fi
}

# GitHubからJiraへのステータスマッピング
map_github_to_jira_status() {
    local github_status=$1
    local mapped_status
    
    mapped_status=$(echo "$JIRA_CONFIG" | jq -r --arg status "$github_status" '.status_mapping.github_to_jira[$status] // "To Do"')
    echo "$mapped_status"
}

# JiraからGitHubへのステータスマッピング
map_jira_to_github_status() {
    local jira_status=$1
    local mapped_status
    
    mapped_status=$(echo "$JIRA_CONFIG" | jq -r --arg status "$jira_status" '.status_mapping.jira_to_github[$status] // "open"')
    echo "$mapped_status"
}

# Jiraチケットの作成
create_jira_issue() {
    local github_issue_data=$1
    
    # GitHub Issue情報の抽出
    local issue_number
    local issue_title
    local issue_body
    local issue_labels
    local repository
    local author
    local created_at
    
    issue_number=$(echo "$github_issue_data" | jq -r '.number')
    issue_title=$(echo "$github_issue_data" | jq -r '.title')
    issue_body=$(echo "$github_issue_data" | jq -r '.body // ""')
    issue_labels=$(echo "$github_issue_data" | jq -r '.labels[].name' | tr '\n' ',')
    repository=$(echo "$github_issue_data" | jq -r '.repository')
    author=$(echo "$github_issue_data" | jq -r '.user.login // "unknown"')
    created_at=$(echo "$github_issue_data" | jq -r '.created_at')
    
    # プロジェクトキーの取得
    local project_key
    project_key=$(get_project_key "$repository")
    
    # Issue タイプの取得
    local issue_type
    issue_type=$(echo "$JIRA_CONFIG" | jq -r '.issue_type // "Task"')
    
    # 説明文の生成
    local description="h3. GitHub Issue 情報\n"
    description+="* *Issue番号*: #${issue_number}\n"
    description+="* *リポジトリ*: ${repository}\n"
    description+="* *作成者*: ${author}\n"
    description+="* *作成日時*: ${created_at}\n"
    description+="\nh3. 元の説明\n${issue_body}\n"
    description+="\nh3. Claude実行情報\n"
    description+="* *実行ID*: $(date +%s)\n"
    description+="* *開始時刻*: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    
    # Jiraラベルの設定
    local jira_labels
    jira_labels=$(echo "$JIRA_CONFIG" | jq -r '.labels[]' | jq -R . | jq -s .)
    
    # カスタムフィールドの取得
    local github_issue_url_field
    local github_pr_url_field
    github_issue_url_field=$(echo "$JIRA_CONFIG" | jq -r '.field_mapping.custom_fields.github_issue_url // ""')
    github_pr_url_field=$(echo "$JIRA_CONFIG" | jq -r '.field_mapping.custom_fields.github_pr_url // ""')
    
    # Issueデータの構築
    local issue_data
    issue_data=$(jq -n \
        --arg project "$project_key" \
        --arg summary "[GitHub #${issue_number}] ${issue_title}" \
        --arg description "$description" \
        --arg issuetype "$issue_type" \
        --argjson labels "$jira_labels" \
        '{
            fields: {
                project: { key: $project },
                summary: $summary,
                description: {
                    type: "doc",
                    version: 1,
                    content: [
                        {
                            type: "paragraph",
                            content: [
                                {
                                    type: "text",
                                    text: $description
                                }
                            ]
                        }
                    ]
                },
                issuetype: { name: $issuetype },
                labels: $labels
            }
        }')
    
    # カスタムフィールドの追加
    if [[ -n "$github_issue_url_field" ]]; then
        local issue_url="https://github.com/${repository}/issues/${issue_number}"
        issue_data=$(echo "$issue_data" | jq --arg field "$github_issue_url_field" --arg url "$issue_url" '.fields[$field] = $url')
    fi
    
    log_info "Creating Jira issue for GitHub Issue #${issue_number}..."
    
    # Jira Issue の作成
    local response
    if response=$(jira_api_call "/issue" "POST" "$issue_data"); then
        local jira_key
        jira_key=$(echo "$response" | jq -r '.key')
        local jira_id
        jira_id=$(echo "$response" | jq -r '.id')
        
        log_info "Created Jira issue: ${jira_key}"
        
        # メタデータを保存
        save_issue_mapping "$repository" "$issue_number" "$jira_key" "$jira_id"
        
        echo "$jira_key"
        return 0
    else
        log_error "Failed to create Jira issue"
        return 1
    fi
}

# Issue マッピングの保存
save_issue_mapping() {
    local repository=$1
    local github_issue=$2
    local jira_key=$3
    local jira_id=$4
    
    local mapping_file="${CLAUDE_AUTO_HOME}/jira_mappings.json"
    
    # ファイルが存在しない場合は初期化
    if [[ ! -f "$mapping_file" ]]; then
        echo "[]" > "$mapping_file"
    fi
    
    # 新しいマッピングを追加
    local new_mapping
    new_mapping=$(jq -n \
        --arg repo "$repository" \
        --arg github "$github_issue" \
        --arg jira_key "$jira_key" \
        --arg jira_id "$jira_id" \
        --arg created "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            repository: $repo,
            github_issue: $github,
            jira_key: $jira_key,
            jira_id: $jira_id,
            created_at: $created
        }')
    
    jq ". += [$new_mapping]" "$mapping_file" > "${mapping_file}.tmp"
    mv "${mapping_file}.tmp" "$mapping_file"
}

# Issue マッピングの取得
get_issue_mapping() {
    local repository=$1
    local github_issue=$2
    
    local mapping_file="${CLAUDE_AUTO_HOME}/jira_mappings.json"
    
    if [[ ! -f "$mapping_file" ]]; then
        return 1
    fi
    
    jq -r --arg repo "$repository" --arg issue "$github_issue" \
        '.[] | select(.repository == $repo and .github_issue == $issue)' \
        "$mapping_file"
}

# Jiraステータスの更新
update_jira_status() {
    local jira_key=$1
    local new_status=$2
    
    log_info "Updating Jira issue ${jira_key} status to: ${new_status}"
    
    # トランジション IDの取得
    local transitions
    if ! transitions=$(jira_api_call "/issue/${jira_key}/transitions"); then
        return 1
    fi
    
    # 目的のステータスへのトランジションを検索
    local transition_id
    transition_id=$(echo "$transitions" | jq -r --arg status "$new_status" '.transitions[] | select(.to.name == $status) | .id' | head -1)
    
    if [[ -z "$transition_id" ]]; then
        log_error "No transition found to status: ${new_status}"
        return 1
    fi
    
    # トランジションの実行
    local transition_data
    transition_data=$(jq -n --arg id "$transition_id" '{ transition: { id: $id } }')
    
    if jira_api_call "/issue/${jira_key}/transitions" "POST" "$transition_data"; then
        log_info "Successfully updated Jira status"
        return 0
    else
        return 1
    fi
}

# Jiraコメントの追加
add_jira_comment() {
    local jira_key=$1
    local comment=$2
    
    log_info "Adding comment to Jira issue: ${jira_key}"
    
    local comment_data
    comment_data=$(jq -n --arg body "$comment" '{
        body: {
            type: "doc",
            version: 1,
            content: [
                {
                    type: "paragraph",
                    content: [
                        {
                            type: "text",
                            text: $body
                        }
                    ]
                }
            ]
        }
    }')
    
    if jira_api_call "/issue/${jira_key}/comment" "POST" "$comment_data"; then
        log_info "Successfully added comment"
        return 0
    else
        return 1
    fi
}

# 実行時間の記録
log_work_time() {
    local jira_key=$1
    local time_spent=$2  # 秒単位
    
    log_info "Logging work time for ${jira_key}: ${time_spent} seconds"
    
    # Jiraの時間形式に変換 (例: "1h 30m")
    local hours=$((time_spent / 3600))
    local minutes=$(((time_spent % 3600) / 60))
    
    local time_string=""
    [[ $hours -gt 0 ]] && time_string="${hours}h "
    [[ $minutes -gt 0 ]] && time_string="${time_string}${minutes}m"
    
    if [[ -z "$time_string" ]]; then
        time_string="1m"  # 最小1分
    fi
    
    local worklog_data
    worklog_data=$(jq -n \
        --arg time "$time_string" \
        --arg comment "Automated by Claude Automation System" \
        '{
            timeSpent: $time,
            comment: {
                type: "doc",
                version: 1,
                content: [
                    {
                        type: "paragraph",
                        content: [
                            {
                                type: "text",
                                text: $comment
                            }
                        ]
                    }
                ]
            }
        }')
    
    if jira_api_call "/issue/${jira_key}/worklog" "POST" "$worklog_data"; then
        log_info "Successfully logged work time"
        return 0
    else
        return 1
    fi
}

# GitHubとの同期
sync_from_github() {
    local github_issue_data=$1
    
    local repository
    local issue_number
    repository=$(echo "$github_issue_data" | jq -r '.repository')
    issue_number=$(echo "$github_issue_data" | jq -r '.number')
    
    # 既存のマッピングを確認
    local mapping
    if mapping=$(get_issue_mapping "$repository" "$issue_number"); then
        local jira_key
        jira_key=$(echo "$mapping" | jq -r '.jira_key')
        
        log_info "Found existing Jira issue: ${jira_key}"
        
        # ステータスの同期
        local github_state
        github_state=$(echo "$github_issue_data" | jq -r '.state')
        
        if [[ "$github_state" == "closed" ]]; then
            update_jira_status "$jira_key" "Done"
        fi
        
        echo "$jira_key"
    else
        # 新規作成
        create_jira_issue "$github_issue_data"
    fi
}

# メイン処理
main() {
    local action="${1:-}"
    
    if [[ -z "$action" ]]; then
        log_error "Usage: $0 <action> [parameters...]"
        exit 1
    fi
    
    # Jira設定の読み込み
    load_jira_config
    
    case "$action" in
        "create_issue")
            create_jira_issue "${2:-}"
            ;;
        "update_status")
            update_jira_status "${2:-}" "${3:-}"
            ;;
        "add_comment")
            add_jira_comment "${2:-}" "${3:-}"
            ;;
        "log_time")
            log_work_time "${2:-}" "${3:-}"
            ;;
        "sync_from_github")
            sync_from_github "${2:-}"
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