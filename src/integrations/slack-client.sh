#!/usr/bin/env bash

# slack-client.sh - Slack通知クライアント
# 
# 使用方法:
#   ./src/integrations/slack-client.sh <notification_type> <issue_number> <title> <repo>

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"

# 引数
NOTIFICATION_TYPE="${1:-}"
ISSUE_NUMBER="${2:-}"
TITLE="${3:-}"
REPOSITORY="${4:-}"

# Slack設定の読み込み
load_slack_config() {
    local slack_config
    slack_config=$(get_slack_config)
    
    SLACK_ENABLED=$(echo "$slack_config" | jq -r '.enabled // false')
    SLACK_WEBHOOK_URL=$(echo "$slack_config" | jq -r '.webhook_url // ""')
    
    if [[ "$SLACK_ENABLED" != "true" ]]; then
        log_debug "Slack integration is disabled"
        exit 0
    fi
    
    if [[ -z "$SLACK_WEBHOOK_URL" ]]; then
        log_error "Slack webhook URL is not configured"
        exit 1
    fi
}

# チャンネルの決定
get_channel() {
    local notification_type=$1
    local default_channel
    default_channel=$(get_config_value "slack.default_channel" "#general" "integrations")
    
    case "$notification_type" in
        "error"|"execution_error"|"pr_review_error")
            get_config_value "slack.channels.error" "$default_channel" "integrations"
            ;;
        "success"|"execution_complete")
            get_config_value "slack.channels.success" "$default_channel" "integrations"
            ;;
        "pr_review_complete"|"review_requested")
            get_config_value "slack.channels.review" "$default_channel" "integrations"
            ;;
        "critical"|"hotfix")
            get_config_value "slack.channels.critical" "$default_channel" "integrations"
            ;;
        *)
            echo "$default_channel"
            ;;
    esac
}

# メンションユーザーの取得
get_mentions() {
    local notification_type=$1
    local mentions=""
    
    case "$notification_type" in
        "error"|"execution_error"|"pr_review_error")
            mentions=$(get_config_array "slack.mention_users.error" "integrations" | tr '\n' ' ')
            ;;
        "pr_review_complete"|"review_requested")
            mentions=$(get_config_array "slack.mention_users.review" "integrations" | tr '\n' ' ')
            ;;
        "critical"|"hotfix")
            mentions=$(get_config_array "slack.mention_users.critical" "integrations" | tr '\n' ' ')
            ;;
    esac
    
    echo "$mentions"
}

# タイムスタンプの生成
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S %Z'
}

# 実行時間の計算
calculate_execution_time() {
    local start_time=$1
    local end_time=$2
    local duration=$((end_time - start_time))
    
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    if [[ $hours -gt 0 ]]; then
        echo "${hours}時間${minutes}分${seconds}秒"
    elif [[ $minutes -gt 0 ]]; then
        echo "${minutes}分${seconds}秒"
    else
        echo "${seconds}秒"
    fi
}

# 通知メッセージの生成
generate_message() {
    local notification_type=$1
    local timestamp
    timestamp=$(get_timestamp)
    
    local message=""
    local color=""
    local mentions
    mentions=$(get_mentions "$notification_type")
    
    case "$notification_type" in
        "execution_start")
            color="warning"
            message="🤖 *Claude自動実行開始*\n"
            message+="📋 Issue: #${ISSUE_NUMBER} - ${TITLE}\n"
            message+="🔗 リポジトリ: ${REPOSITORY}\n"
            message+="⏰ 開始時刻: ${timestamp}"
            ;;
            
        "execution_complete")
            color="good"
            message="✅ *Claude自動実行完了*\n"
            message+="📋 Issue: #${ISSUE_NUMBER} - ${TITLE}\n"
            message+="🔗 リポジトリ: ${REPOSITORY}\n"
            message+="⏰ 完了時刻: ${timestamp}\n"
            message+="📝 <https://github.com/${REPOSITORY}/pulls|PRを確認>"
            ;;
            
        "execution_error")
            color="danger"
            message="❌ *Claude自動実行エラー*\n"
            message+="📋 Issue: #${ISSUE_NUMBER} - ${TITLE}\n"
            message+="🔗 リポジトリ: ${REPOSITORY}\n"
            message+="🚨 エラー発生時刻: ${timestamp}\n"
            message+="🔧 対応: 手動確認が必要です"
            if [[ -n "$mentions" ]]; then
                message+="\n👥 ${mentions}"
            fi
            ;;
            
        "pr_review_complete")
            color="good"
            message="✅ *PRレビュー完了*\n"
            message+="📋 PR: #${ISSUE_NUMBER} - ${TITLE}\n"
            message+="🔗 リポジトリ: ${REPOSITORY}\n"
            message+="👀 レビュー完了時刻: ${timestamp}"
            ;;
            
        "pr_review_error")
            color="danger"
            message="❌ *PRレビューエラー*\n"
            message+="📋 PR: #${ISSUE_NUMBER} - ${TITLE}\n"
            message+="🔗 リポジトリ: ${REPOSITORY}\n"
            message+="🚨 エラー発生時刻: ${timestamp}"
            if [[ -n "$mentions" ]]; then
                message+="\n👥 ${mentions}"
            fi
            ;;
            
        *)
            color="#439FE0"
            message="ℹ️ *Claude Automation通知*\n"
            message+="タイプ: ${notification_type}\n"
            message+="詳細: #${ISSUE_NUMBER} - ${TITLE}\n"
            message+="リポジトリ: ${REPOSITORY}"
            ;;
    esac
    
    # JSON形式でメッセージを構築
    local json_payload
    json_payload=$(jq -n \
        --arg channel "$(get_channel "$notification_type")" \
        --arg username "Claude Automation" \
        --arg icon_emoji ":robot_face:" \
        --arg text "$message" \
        --arg color "$color" \
        '{
            channel: $channel,
            username: $username,
            icon_emoji: $icon_emoji,
            attachments: [{
                color: $color,
                text: $text,
                footer: "Claude Automation System",
                footer_icon: "https://github.com/favicon.ico",
                ts: now | floor
            }]
        }')
    
    echo "$json_payload"
}

# インタラクティブメッセージの生成
generate_interactive_message() {
    local notification_type=$1
    local message
    message=$(generate_message "$notification_type")
    
    # インタラクティブボタンを追加
    if [[ "$notification_type" == "execution_start" ]] || [[ "$notification_type" == "execution_error" ]]; then
        local actions
        actions=$(jq -n '[
            {
                type: "button",
                text: "🔄 再実行",
                style: "default",
                value: "retry_' + "$REPOSITORY" + '_' + "$ISSUE_NUMBER" + '"
            },
            {
                type: "button",
                text: "⏸️ 一時停止",
                style: "warning",
                value: "pause_' + "$REPOSITORY" + '_' + "$ISSUE_NUMBER" + '"
            },
            {
                type: "button",
                text: "📋 詳細確認",
                style: "primary",
                url: "https://github.com/' + "$REPOSITORY" + '/issues/' + "$ISSUE_NUMBER" + '"
            }
        ]')
        
        message=$(echo "$message" | jq --argjson actions "$actions" '.attachments[0].actions = $actions')
    fi
    
    echo "$message"
}

# Slackへの送信
send_to_slack() {
    local payload=$1
    
    log_debug "Sending Slack notification..."
    
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H 'Content-type: application/json' \
        -d "$payload" \
        "$SLACK_WEBHOOK_URL")
    
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]]; then
        log_info "Slack notification sent successfully"
        return 0
    else
        log_error "Failed to send Slack notification (HTTP $http_code): $response"
        return 1
    fi
}

# スレッドへの返信
send_thread_reply() {
    local parent_ts=$1
    local message=$2
    local channel=$3
    
    # Slack Web APIを使用する場合の実装
    # ここではWebhook URLのみを使用するため、スレッド機能は制限される
    log_warn "Thread reply feature requires Slack Web API token"
}

# メイン処理
main() {
    # 引数チェック
    if [[ -z "$NOTIFICATION_TYPE" ]] || [[ -z "$ISSUE_NUMBER" ]] || [[ -z "$REPOSITORY" ]]; then
        log_error "Usage: $0 <notification_type> <issue_number> <title> <repo>"
        exit 1
    fi
    
    # Slack設定の読み込み
    load_slack_config
    
    # メッセージの生成
    local message
    if [[ "$NOTIFICATION_TYPE" == "execution_start" ]] || [[ "$NOTIFICATION_TYPE" == "execution_error" ]]; then
        message=$(generate_interactive_message "$NOTIFICATION_TYPE")
    else
        message=$(generate_message "$NOTIFICATION_TYPE")
    fi
    
    # Slackへの送信
    send_to_slack "$message"
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi