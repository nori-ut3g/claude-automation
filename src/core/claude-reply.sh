#!/usr/bin/env bash

# claude-reply.sh - GitHubのIssueに返信するためのClaude実行
# 
# 使用方法:
#   echo "$execution_params" | ./src/core/claude-reply.sh

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"
source "${CLAUDE_AUTO_HOME}/src/integrations/github-client.sh"

# 定数
readonly MAX_EXECUTION_TIME=600  # 10分

# 初期化
initialize_reply() {
    log_info "Claude Reply Handler starting..."
    
    # gh CLI認証チェック
    check_gh_auth
    
    # 実行パラメータを読み込み
    EXECUTION_PARAMS=$(cat)
    
    if [[ -z "$EXECUTION_PARAMS" ]]; then
        log_error "No execution parameters provided"
        exit 1
    fi
    
    log_debug "Execution parameters: $EXECUTION_PARAMS"
}

# Issue 情報の抽出
extract_issue_info() {
    REPOSITORY=$(echo "$EXECUTION_PARAMS" | jq -r '.repository')
    ISSUE_NUMBER=$(echo "$EXECUTION_PARAMS" | jq -r '.issue_number')
    ISSUE_TITLE=$(echo "$EXECUTION_PARAMS" | jq -r '.issue_title')
    ISSUE_BODY=$(echo "$EXECUTION_PARAMS" | jq -r '.issue_body')
    FOUND_KEYWORD=$(echo "$EXECUTION_PARAMS" | jq -r '.found_keyword // ""')
    
    # コメントトリガー情報の抽出
    TRIGGER_COMMENT=$(echo "$EXECUTION_PARAMS" | jq -r '.trigger_comment // empty')
    COMMENT_BODY=""
    COMMENT_AUTHOR=""
    
    if [[ -n "$TRIGGER_COMMENT" ]]; then
        COMMENT_BODY=$(echo "$TRIGGER_COMMENT" | jq -r '.body // ""')
        COMMENT_AUTHOR=$(echo "$TRIGGER_COMMENT" | jq -r '.author // ""')
        log_info "Comment-triggered reply requested by $COMMENT_AUTHOR"
    fi
    
    log_info "Processing reply for Issue #${ISSUE_NUMBER} in ${REPOSITORY}"
    log_info "Found keyword: ${FOUND_KEYWORD}"
}

# 返信プロンプトの生成
generate_reply_prompt() {
    local prompt_template
    
    # コメントトリガーの場合は別のプロンプトを使用
    if [[ -n "$COMMENT_BODY" ]]; then
        prompt_template=$(get_config_value "claude.comment_reply_prompt_template" "" "claude-prompts")
        
        if [[ -z "$prompt_template" ]]; then
            # デフォルトのコメント返信プロンプト
            prompt_template="GitHubのIssueのコメントに対して適切な返信を生成してください。

Issue情報:
- タイトル: {{ISSUE_TITLE}}
- 本文: {{ISSUE_BODY}}

コメント情報:
- コメント投稿者: {{COMMENT_AUTHOR}}
- コメント内容: {{COMMENT_BODY}}
- 見つかったキーワード: {{FOUND_KEYWORD}}

以下の点を考慮して返信してください:
1. コメント投稿者（{{COMMENT_AUTHOR}}）への直接的な返信として書く
2. コメントの内容に具体的に対応する
3. 技術的な質問には具体的な回答を提供する
4. 不明な点がある場合は追加情報を求める
5. 必要に応じて参考リンクや資料を提供する

返信のみを出力してください（マークダウン形式で）。"
        fi
    else
        prompt_template=$(get_config_value "claude.reply_prompt_template" "" "claude-prompts")
        
        if [[ -z "$prompt_template" ]]; then
            # デフォルトの返信プロンプト
            prompt_template="GitHubのIssueに対して適切な返信を生成してください。

Issue情報:
- タイトル: {{ISSUE_TITLE}}
- 内容: {{ISSUE_BODY}}
- 見つかったキーワード: {{FOUND_KEYWORD}}

以下の点を考慮して返信してください:
1. 丁寧で建設的な返信をする
2. 技術的な質問には具体的な回答を提供する
3. 不明な点がある場合は追加情報を求める
4. 必要に応じて参考リンクや資料を提供する

返信のみを出力してください（マークダウン形式で）。"
        fi
    fi
    
    # プレースホルダーの置換
    local detailed_prompt
    detailed_prompt="$prompt_template"
    detailed_prompt="${detailed_prompt//\{\{ISSUE_TITLE\}\}/$ISSUE_TITLE}"
    detailed_prompt="${detailed_prompt//\{\{ISSUE_BODY\}\}/$ISSUE_BODY}"
    detailed_prompt="${detailed_prompt//\{\{FOUND_KEYWORD\}\}/$FOUND_KEYWORD}"
    detailed_prompt="${detailed_prompt//\{\{REPOSITORY\}\}/$REPOSITORY}"
    detailed_prompt="${detailed_prompt//\{\{ISSUE_NUMBER\}\}/$ISSUE_NUMBER}"
    detailed_prompt="${detailed_prompt//\{\{COMMENT_BODY\}\}/$COMMENT_BODY}"
    detailed_prompt="${detailed_prompt//\{\{COMMENT_AUTHOR\}\}/$COMMENT_AUTHOR}"
    
    echo "$detailed_prompt"
}

# Claude による返信生成
execute_claude_reply() {
    local prompt=$1
    local claude_log="${CLAUDE_AUTO_HOME}/logs/claude-reply-${ISSUE_NUMBER}.log"
    local prompt_file="${CLAUDE_AUTO_HOME}/logs/claude-prompt-${ISSUE_NUMBER}.txt"
    
    log_info "Generating reply with Claude..."
    
    # プロンプトをファイルに書き込み
    echo "$prompt" > "$prompt_file"
    
    # Claudeを非対話的モードで実行
    local reply_content=""
    if timeout $MAX_EXECUTION_TIME claude --print "$(cat "$prompt_file")" > "$claude_log" 2>&1; then
        reply_content=$(cat "$claude_log")
        log_info "Claude reply generation successful"
    else
        log_error "Claude reply generation failed"
        log_error "Claude log: $(cat "$claude_log" 2>/dev/null || echo 'No log available')"
        rm -f "$prompt_file"
        return 1
    fi
    
    # クリーンアップ
    rm -f "$prompt_file"
    
    if [[ -z "$reply_content" ]]; then
        log_error "Claude generated empty reply"
        return 1
    fi
    
    echo "$reply_content"
}

# GitHub Issue にコメントを投稿
post_reply_comment() {
    local reply_content=$1
    
    log_info "Posting reply comment to Issue #${ISSUE_NUMBER}"
    
    # Claude自動生成であることを示すフッターを追加
    local full_comment
    full_comment="$reply_content

---
🤖 この返信は [Claude Automation System](https://github.com/anthropics/claude-code) によって自動生成されました。"
    
    # GitHub API を使用してコメントを投稿
    if gh issue comment "$ISSUE_NUMBER" --repo "$REPOSITORY" --body "$full_comment"; then
        log_info "Reply comment posted successfully"
        return 0
    else
        log_error "Failed to post reply comment"
        return 1
    fi
}

# メイン処理
main() {
    # 初期化
    initialize_reply
    
    # Issue 情報を抽出
    extract_issue_info
    
    # 返信プロンプトを生成
    local prompt
    prompt=$(generate_reply_prompt)
    
    # Claude で返信を生成
    local reply_content
    if reply_content=$(execute_claude_reply "$prompt"); then
        # GitHub にコメントを投稿
        if post_reply_comment "$reply_content"; then
            log_info "Reply process completed successfully"
            exit 0
        else
            log_error "Failed to post reply"
            exit 1
        fi
    else
        log_error "Failed to generate reply"
        exit 1
    fi
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi