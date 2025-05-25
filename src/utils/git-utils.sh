#!/usr/bin/env bash

# git-utils.sh - Git操作のユーティリティ関数
# 
# 使用方法:
#   source src/utils/git-utils.sh
#   git_clone_repo "https://github.com/user/repo.git" "/path/to/workspace"
#   git_create_branch "feature/new-feature" "main"

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${CLAUDE_AUTO_HOME}/workspace}"

# ログ関数のインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"

# Gitが利用可能かチェック
check_git() {
    if ! command -v git &> /dev/null; then
        log_error "Git is not installed"
        return 1
    fi
}

# GitHubトークンの設定
setup_github_auth() {
    local token=${1:-$GITHUB_TOKEN}
    
    if [[ -z "$token" ]]; then
        log_error "GitHub token is not set"
        return 1
    fi
    
    # Git認証ヘルパーの設定
    git config --global credential.helper "store"
    echo "https://x-access-token:${token}@github.com" > ~/.git-credentials
    
    # ユーザー情報の設定（未設定の場合）
    if [[ -z "$(git config --global user.name)" ]]; then
        git config --global user.name "Claude Automation System"
    fi
    
    if [[ -z "$(git config --global user.email)" ]]; then
        git config --global user.email "claude-automation@system.local"
    fi
}

# リポジトリのクローン
git_clone_repo() {
    local repo_url=$1
    local target_dir=$2
    local branch=${3:-}
    
    # HTTPSのURLに変換
    if [[ "$repo_url" =~ ^git@github\.com:(.*)\.git$ ]]; then
        repo_url="https://github.com/${BASH_REMATCH[1]}.git"
    fi
    
    # 既存のディレクトリがある場合は削除
    if [[ -d "$target_dir" ]]; then
        log_warn "Removing existing directory: $target_dir"
        rm -rf "$target_dir"
    fi
    
    # クローンコマンドの構築
    local clone_cmd="git clone"
    if [[ -n "$branch" ]]; then
        clone_cmd="$clone_cmd -b $branch"
    fi
    clone_cmd="$clone_cmd $repo_url $target_dir"
    
    log_info "Cloning repository: $repo_url"
    if $clone_cmd; then
        log_info "Repository cloned successfully"
        return 0
    else
        log_error "Failed to clone repository"
        return 1
    fi
}

# リポジトリの更新
git_pull_latest() {
    local repo_dir=$1
    local branch=${2:-$(git_get_current_branch "$repo_dir")}
    
    cd "$repo_dir" || return 1
    
    log_info "Fetching latest changes"
    git fetch origin
    
    log_info "Pulling latest changes from $branch"
    if git pull origin "$branch"; then
        log_info "Repository updated successfully"
        return 0
    else
        log_error "Failed to pull latest changes"
        return 1
    fi
}

# 現在のブランチを取得
git_get_current_branch() {
    local repo_dir=${1:-.}
    
    cd "$repo_dir" || return 1
    git branch --show-current
}

# ブランチの作成とチェックアウト
git_create_branch() {
    local branch_name=$1
    local base_branch=$2
    local repo_dir=${3:-.}
    
    cd "$repo_dir" || return 1
    
    # ベースブランチに切り替え
    log_info "Switching to base branch: $base_branch"
    git checkout "$base_branch"
    
    # 最新の変更を取得
    git pull origin "$base_branch"
    
    # 新しいブランチを作成
    log_info "Creating new branch: $branch_name"
    if git checkout -b "$branch_name"; then
        log_info "Branch created successfully: $branch_name"
        return 0
    else
        log_error "Failed to create branch: $branch_name"
        return 1
    fi
}

# ブランチの存在チェック
git_branch_exists() {
    local branch_name=$1
    local repo_dir=${2:-.}
    local check_remote=${3:-true}
    
    cd "$repo_dir" || return 1
    
    # ローカルブランチをチェック
    if git show-ref --verify --quiet "refs/heads/${branch_name}"; then
        return 0
    fi
    
    # リモートブランチをチェック
    if [[ "$check_remote" == "true" ]]; then
        git fetch origin
        if git show-ref --verify --quiet "refs/remotes/origin/${branch_name}"; then
            return 0
        fi
    fi
    
    return 1
}

# 変更のステージング
git_stage_changes() {
    local repo_dir=${1:-.}
    local files=("${@:2}")
    
    cd "$repo_dir" || return 1
    
    if [[ ${#files[@]} -eq 0 ]]; then
        # すべての変更をステージング
        log_info "Staging all changes"
        git add -A
    else
        # 指定されたファイルをステージング
        log_info "Staging specified files"
        git add "${files[@]}"
    fi
}

# コミットの作成
git_commit() {
    local message=$1
    local repo_dir=${2:-.}
    
    cd "$repo_dir" || return 1
    
    log_info "Creating commit"
    if git commit -m "$message"; then
        log_info "Commit created successfully"
        return 0
    else
        log_error "Failed to create commit"
        return 1
    fi
}

# プッシュ
git_push() {
    local branch=${1:-$(git_get_current_branch)}
    local repo_dir=${2:-.}
    local force=${3:-false}
    
    cd "$repo_dir" || return 1
    
    local push_cmd="git push origin $branch"
    if [[ "$force" == "true" ]]; then
        push_cmd="$push_cmd --force-with-lease"
    fi
    
    # 上流ブランチの設定
    if ! git rev-parse --abbrev-ref --symbolic-full-name "@{u}" &>/dev/null; then
        push_cmd="$push_cmd --set-upstream"
    fi
    
    log_info "Pushing changes to remote"
    if $push_cmd; then
        log_info "Changes pushed successfully"
        return 0
    else
        log_error "Failed to push changes"
        return 1
    fi
}

# ブランチ名の生成
generate_branch_name() {
    local issue_number=$1
    local issue_type=$2
    local branch_strategy=${3:-"github-flow"}
    local issue_title=${4:-""}
    
    local prefix=""
    local branch_name=""
    
    # ブランチプレフィックスの決定
    case "$issue_type" in
        "hotfix"|"critical"|"urgent")
            prefix="hotfix/"
            ;;
        "bug"|"fix"|"bugfix")
            prefix="bugfix/"
            ;;
        "feature"|"enhancement"|"new")
            prefix="feature/"
            ;;
        "release")
            prefix="release/"
            ;;
        *)
            prefix="feature/"
            ;;
    esac
    
    # GitHub Flow の場合はfeatureプレフィックスのみ
    if [[ "$branch_strategy" == "github-flow" && "$prefix" != "hotfix/" ]]; then
        prefix="feature/"
    fi
    
    # ブランチ名の生成
    branch_name="${prefix}claude-auto-issue-${issue_number}"
    
    # タイトルから追加の情報を含める場合
    if [[ -n "$issue_title" ]]; then
        # タイトルをブランチ名に適した形式に変換
        local sanitized_title
        sanitized_title=$(echo "$issue_title" | \
            tr '[:upper:]' '[:lower:]' | \
            sed 's/[^a-z0-9-]/-/g' | \
            sed 's/--*/-/g' | \
            sed 's/^-//' | \
            sed 's/-$//' | \
            cut -c1-30)
        
        if [[ -n "$sanitized_title" ]]; then
            branch_name="${branch_name}-${sanitized_title}"
        fi
    fi
    
    echo "$branch_name"
}

# Git状態の取得
git_get_status() {
    local repo_dir=${1:-.}
    
    cd "$repo_dir" || return 1
    
    # 状態情報を構造化して出力
    local branch
    branch=$(git_get_current_branch "$repo_dir")
    
    local status
    status=$(git status --porcelain)
    
    local ahead_behind
    ahead_behind=$(git rev-list --left-right --count HEAD...@{u} 2>/dev/null || echo "0	0")
    local ahead=$(echo "$ahead_behind" | cut -f1)
    local behind=$(echo "$ahead_behind" | cut -f2)
    
    cat <<EOF
{
  "branch": "$branch",
  "has_changes": $([ -n "$status" ] && echo "true" || echo "false"),
  "ahead": $ahead,
  "behind": $behind,
  "changes": $(echo "$status" | wc -l | tr -d ' ')
}
EOF
}

# マージコンフリクトのチェック
git_has_conflicts() {
    local repo_dir=${1:-.}
    
    cd "$repo_dir" || return 1
    
    if git diff --name-only --diff-filter=U | grep -q .; then
        return 0
    else
        return 1
    fi
}

# リポジトリのクリーンアップ
git_cleanup_repo() {
    local repo_dir=$1
    
    if [[ ! -d "$repo_dir" ]]; then
        return 0
    fi
    
    log_info "Cleaning up repository: $repo_dir"
    rm -rf "$repo_dir"
}

# 最新のコミットハッシュを取得
git_get_latest_commit() {
    local repo_dir=${1:-.}
    local branch=${2:-HEAD}
    
    cd "$repo_dir" || return 1
    git rev-parse "$branch"
}

# コミットメッセージの生成
generate_commit_message() {
    local type=$1
    local scope=$2
    local description=$3
    local issue_number=$4
    local body=${5:-""}
    
    local message="${type}"
    
    if [[ -n "$scope" ]]; then
        message="${message}(${scope})"
    fi
    
    message="${message}: ${description}"
    
    if [[ -n "$body" ]]; then
        message="${message}\n\n${body}"
    fi
    
    message="${message}\n\nIssue: #${issue_number}"
    message="${message}\nCo-authored-by: Claude <claude@anthropic.com>"
    message="${message}\nAutomated-by: Claude Automation System"
    
    echo -e "$message"
}

# 初期化
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 直接実行された場合のテスト
    echo "Testing git utilities..."
    
    check_git || exit 1
    
    # テスト用のブランチ名生成
    echo "Generated branch name: $(generate_branch_name 123 "feature" "gitflow" "Add new feature")"
    echo "Generated commit message:"
    echo "$(generate_commit_message "feat" "auth" "Add login functionality" "123")"
fi