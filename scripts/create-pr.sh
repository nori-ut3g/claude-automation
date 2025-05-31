#!/usr/bin/env bash

# create-pr.sh - 既存のワークスペースからPRを作成
# 
# 使用方法:
#   ./scripts/create-pr.sh <workspace_path> [issue_number]

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/git-utils.sh"
source "${CLAUDE_AUTO_HOME}/src/integrations/github-client.sh"

# 引数チェック
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <workspace_path> [issue_number]"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/workspace"
    echo "  $0 /path/to/workspace 123"
    exit 1
fi

WORKSPACE_PATH="$1"
ISSUE_NUMBER="${2:-}"

# ワークスペースの検証
if [[ ! -d "$WORKSPACE_PATH" ]]; then
    log_error "Workspace directory does not exist: $WORKSPACE_PATH"
    exit 1
fi

if [[ ! -d "$WORKSPACE_PATH/.git" ]]; then
    log_error "Not a git repository: $WORKSPACE_PATH"
    exit 1
fi

# ワークスペースに移動
cd "$WORKSPACE_PATH"

# リポジトリ情報を取得
get_repository_info() {
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    
    if [[ -z "$remote_url" ]]; then
        log_error "No origin remote found"
        exit 1
    fi
    
    # GitHub URL からリポジトリ名を抽出
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
        REPOSITORY="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        log_error "Could not parse GitHub repository from remote URL: $remote_url"
        exit 1
    fi
    
    # 現在のブランチを取得
    CURRENT_BRANCH=$(git branch --show-current)
    
    if [[ -z "$CURRENT_BRANCH" ]]; then
        log_error "Could not determine current branch"
        exit 1
    fi
    
    # ベースブランチを取得（通常はmainまたはmaster）
    BASE_BRANCH="main"
    if git show-ref --verify --quiet refs/remotes/origin/master; then
        BASE_BRANCH="master"
    fi
    
    log_info "Repository: $REPOSITORY"
    log_info "Current branch: $CURRENT_BRANCH"
    log_info "Base branch: $BASE_BRANCH"
}

# Issue番号を抽出またはプロンプト
get_issue_number() {
    if [[ -n "$ISSUE_NUMBER" ]]; then
        return 0
    fi
    
    # ブランチ名からIssue番号を抽出を試行
    if [[ "$CURRENT_BRANCH" =~ issue-([0-9]+) ]]; then
        ISSUE_NUMBER="${BASH_REMATCH[1]}"
        log_info "Extracted issue number from branch name: $ISSUE_NUMBER"
        return 0
    fi
    
    # ユーザーに入力を求める
    echo "Could not determine issue number automatically."
    read -p "Enter issue number (or press Enter to create PR without linking to issue): " -r
    ISSUE_NUMBER="$REPLY"
}

# コミットされていない変更をチェック
check_uncommitted_changes() {
    if ! git diff --quiet || ! git diff --cached --quiet; then
        log_warn "You have uncommitted changes"
        echo "Uncommitted changes found. What would you like to do?"
        echo "1. Commit changes and continue"
        echo "2. Stash changes and continue"
        echo "3. Cancel"
        read -p "Choose (1-3): " -r choice
        
        case $choice in
            1)
                local commit_message
                if [[ -n "$ISSUE_NUMBER" ]]; then
                    commit_message="Work on issue #${ISSUE_NUMBER}"
                else
                    commit_message="Updates for PR"
                fi
                
                git add -A
                git commit -m "$commit_message"
                log_info "Changes committed"
                ;;
            2)
                git stash push -m "Stashed before PR creation"
                log_info "Changes stashed"
                ;;
            3)
                log_info "PR creation cancelled"
                exit 0
                ;;
            *)
                log_error "Invalid choice"
                exit 1
                ;;
        esac
    fi
}

# Issue情報を取得
get_issue_info() {
    if [[ -z "$ISSUE_NUMBER" ]]; then
        ISSUE_TITLE=""
        ISSUE_BODY=""
        return 0
    fi
    
    log_info "Fetching issue #${ISSUE_NUMBER} information..."
    
    # GitHubトークンの設定
    setup_github_auth || exit 1
    
    local issue_response
    if issue_response=$(github_api_call "/repos/${REPOSITORY}/issues/${ISSUE_NUMBER}" "GET"); then
        ISSUE_TITLE=$(echo "$issue_response" | jq -r '.title')
        ISSUE_BODY=$(echo "$issue_response" | jq -r '.body // ""')
        log_info "Issue title: $ISSUE_TITLE"
    else
        log_error "Failed to fetch issue #${ISSUE_NUMBER}"
        ISSUE_TITLE=""
        ISSUE_BODY=""
    fi
}

# PR タイトルとボディを生成
generate_pr_content() {
    if [[ -n "$ISSUE_NUMBER" ]] && [[ -n "$ISSUE_TITLE" ]]; then
        PR_TITLE="[Claude Auto] ${ISSUE_TITLE}"
        PR_BODY="## Summary

Automated implementation for Issue #${ISSUE_NUMBER}

## Changes

$(git log --oneline ${BASE_BRANCH}..HEAD | sed 's/^/- /')

## Related Issue

Closes #${ISSUE_NUMBER}

## Test Plan

- [ ] Manual testing completed
- [ ] Automated tests pass
- [ ] Code review completed

---
🤖 This PR was created by [Claude Automation System](https://github.com/anthropics/claude-code)"
    else
        # Issue番号がない場合の汎用PR
        local branch_name_clean=${CURRENT_BRANCH//[_-]/ }
        PR_TITLE="$(echo ${branch_name_clean} | sed 's/\b\w/\U&/g')"
        PR_BODY="## Summary

Changes implemented in branch \`${CURRENT_BRANCH}\`

## Changes

$(git log --oneline ${BASE_BRANCH}..HEAD | sed 's/^/- /')

## Test Plan

- [ ] Manual testing completed
- [ ] Automated tests pass
- [ ] Code review completed

---
🤖 This PR was created by [Claude Automation System](https://github.com/anthropics/claude-code)"
    fi
}

# ブランチをプッシュ
push_branch() {
    log_info "Pushing branch to origin..."
    
    if git push -u origin "$CURRENT_BRANCH"; then
        log_info "Branch pushed successfully"
    else
        log_error "Failed to push branch"
        exit 1
    fi
}

# PR を作成
create_pull_request() {
    log_info "Creating pull request..."
    
    local pr_data
    pr_data=$(cat <<EOF
{
    "title": $(echo "$PR_TITLE" | jq -Rs .),
    "body": $(echo "$PR_BODY" | jq -Rs .),
    "head": "$CURRENT_BRANCH",
    "base": "$BASE_BRANCH",
    "draft": false
}
EOF
    )
    
    local pr_response
    if pr_response=$(github_api_call "/repos/${REPOSITORY}/pulls" "POST" "$pr_data"); then
        local pr_number
        pr_number=$(echo "$pr_response" | jq -r '.number')
        local pr_url
        pr_url=$(echo "$pr_response" | jq -r '.html_url')
        
        log_info "Pull request created successfully!"
        log_info "PR #${pr_number}: ${pr_url}"
        
        # ラベルを追加
        add_pr_labels "$pr_number"
        
        # Issue にコメントを追加（Issue番号がある場合）
        if [[ -n "$ISSUE_NUMBER" ]]; then
            add_issue_comment "$ISSUE_NUMBER" "🤖 Pull request created: ${pr_url}"
        fi
        
        echo ""
        echo "✅ Pull Request created successfully!"
        echo "📋 PR #${pr_number}: ${pr_url}"
        
        return 0
    else
        log_error "Failed to create pull request"
        return 1
    fi
}

# PR にラベルを追加
add_pr_labels() {
    local pr_number=$1
    
    local labels='["claude-automated-pr"]'
    
    if [[ -n "$ISSUE_NUMBER" ]]; then
        labels='["claude-automated-pr", "enhancement"]'
    fi
    
    github_api_call "/repos/${REPOSITORY}/issues/${pr_number}/labels" "POST" "{\"labels\": $labels}" || true
}

# Issue にコメントを追加
add_issue_comment() {
    local issue_number=$1
    local comment=$2
    
    local comment_data
    comment_data=$(jq -n --arg body "$comment" '{body: $body}')
    
    github_api_call "/repos/${REPOSITORY}/issues/${issue_number}/comments" "POST" "$comment_data" || true
}

# メイン処理
main() {
    log_info "Starting PR creation from workspace: $WORKSPACE_PATH"
    
    # リポジトリ情報を取得
    get_repository_info
    
    # Issue番号を取得
    get_issue_number
    
    # コミットされていない変更をチェック
    check_uncommitted_changes
    
    # Issue情報を取得
    get_issue_info
    
    # PR コンテンツを生成
    generate_pr_content
    
    # 確認プロンプト
    echo ""
    echo "PR Details:"
    echo "  Title: $PR_TITLE"
    echo "  From: $CURRENT_BRANCH"
    echo "  To: $BASE_BRANCH"
    if [[ -n "$ISSUE_NUMBER" ]]; then
        echo "  Issue: #$ISSUE_NUMBER"
    fi
    echo ""
    
    read -p "Create this pull request? (y/N): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "PR creation cancelled"
        exit 0
    fi
    
    # ブランチをプッシュ
    push_branch
    
    # PR を作成
    create_pull_request
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi