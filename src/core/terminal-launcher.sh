#!/usr/bin/env bash

# terminal-launcher.sh - Terminalを自動起動してClaude Codeセッションを開始
# 
# 使用方法:
#   ./src/core/terminal-launcher.sh <project_path> <prompt_text> [terminal_type]

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"

# 定数
readonly SUPPORTED_TERMINALS=("Terminal" "iTerm" "Warp")
readonly DEFAULT_TERMINAL="Terminal"

# グローバル変数
PROJECT_PATH=""
PROMPT_TEXT=""
TERMINAL_TYPE=""
SESSION_ID=""

# 使用方法の表示
show_usage() {
    cat << EOF
使用方法: $0 <project_path> <prompt_text> [terminal_type]

引数:
  project_path    - プロジェクトディレクトリのパス
  prompt_text     - Claude Codeに渡すプロンプト
  terminal_type   - 使用するターミナルアプリ (Terminal, iTerm, Warp)

例:
  $0 "/path/to/project" "新しいAPIを実装してください" Terminal
  $0 "/path/to/project" "バグを修正してください" iTerm
EOF
}

# 引数の検証
validate_arguments() {
    if [[ $# -lt 2 ]]; then
        log_error "引数が不足しています"
        show_usage
        exit 1
    fi
    
    PROJECT_PATH="$1"
    PROMPT_TEXT="$2"
    TERMINAL_TYPE="${3:-$DEFAULT_TERMINAL}"
    ISSUE_NUMBER="${4:-}"
    
    # プロジェクトパスの存在確認
    if [[ ! -d "$PROJECT_PATH" ]]; then
        log_error "プロジェクトディレクトリが存在しません: $PROJECT_PATH"
        exit 1
    fi
    
    # ターミナルタイプの確認
    local is_supported=false
    for supported in "${SUPPORTED_TERMINALS[@]}"; do
        if [[ "$TERMINAL_TYPE" == "$supported" ]]; then
            is_supported=true
            break
        fi
    done
    
    if [[ "$is_supported" != "true" ]]; then
        log_error "サポートされていないターミナルタイプ: $TERMINAL_TYPE"
        log_info "サポート対象: ${SUPPORTED_TERMINALS[*]}"
        exit 1
    fi
    
    # セッションIDの生成
    SESSION_ID="claude_auto_$(date +%s)_$$"
    
    log_info "Terminal Launcher initialized"
    log_info "Project: $PROJECT_PATH"
    log_info "Terminal: $TERMINAL_TYPE"
    log_info "Session ID: $SESSION_ID"
}

# Claude Codeが利用可能か確認
check_claude_availability() {
    if ! command -v claude &> /dev/null; then
        log_error "Claude Code CLI が見つかりません"
        log_info "インストール方法: https://claude.ai/code"
        exit 1
    fi
    
    # Claude認証状態確認
    if ! claude --version &> /dev/null; then
        log_error "Claude Codeの認証に問題があります"
        log_info "認証確認: claude config"
        exit 1
    fi
    
    log_info "Claude Code is available and authenticated"
}

# 既存のセッションをチェック
check_existing_sessions() {
    local session_log="${CLAUDE_AUTO_HOME}/logs/terminal_sessions.json"
    
    if [[ ! -f "$session_log" ]]; then
        return 0
    fi
    
    # Issueに関連する既存セッションを検索
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local existing_session
        existing_session=$(jq -r ".[] | select(.prompt_text | contains(\"Issue #${ISSUE_NUMBER}\")) | select(.status == \"launched\")" "$session_log" 2>/dev/null || echo "")
        
        if [[ -n "$existing_session" ]]; then
            local session_id
            session_id=$(echo "$existing_session" | jq -r '.session_id')
            log_warn "既にIssue #${ISSUE_NUMBER}のセッションが起動されています: $session_id"
            log_info "重複起動を防ぐため、処理を中止します"
            exit 0
        fi
    fi
}

# プロンプトファイルの作成
create_prompt_file() {
    local prompt_file="${CLAUDE_AUTO_HOME}/logs/terminal_prompt_${SESSION_ID}.txt"
    
    cat > "$prompt_file" << EOF
# Claude Automation System - 自動実行タスク

## プロジェクト情報
- ディレクトリ: $PROJECT_PATH
- セッションID: $SESSION_ID
- 開始時刻: $(date)

## 実行タスク
$PROMPT_TEXT

## 実行指針
1. 現在のプロジェクト構造を確認してください
2. 要求されたタスクを理解し、必要なファイルを特定してください
3. 適切なコード変更・追加を行ってください
4. 変更内容をテストし、動作確認を行ってください
5. 変更をコミットし、必要に応じてプルリクエストを作成してください

プロジェクトディレクトリ: $PROJECT_PATH
EOF
    
    echo "$prompt_file"
}

# Terminal.app でセッションを起動
launch_terminal_app() {
    local prompt_file=$1
    
    log_info "Launching Terminal.app session..."
    
    # シンプルなAppleScriptでTerminalを開く
    osascript << EOF
tell application "Terminal"
    activate
    do script "cd '$PROJECT_PATH' && echo 'Claude Automation System - セッション開始' && echo 'プロジェクト: $PROJECT_PATH' && echo 'タスク: $PROMPT_TEXT' && echo '' && claude --print \"\$(cat '$prompt_file')\""
end tell
EOF
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_info "Terminal session launched successfully"
        return 0
    else
        log_error "Failed to launch Terminal session (exit code: $exit_code)"
        return 1
    fi
}

# iTerm2 でセッションを起動
launch_iterm() {
    local prompt_file=$1
    
    log_info "Launching iTerm2 session..."
    
    osascript << EOF
tell application "iTerm"
    activate
    
    -- 新しいウィンドウを作成
    set newWindow to (create window with default profile)
    
    tell current session of newWindow
        -- ディレクトリを移動
        write text "cd '$PROJECT_PATH'"
        
        -- セッション情報を表示
        write text "echo 'Claude Automation System - セッション開始'"
        write text "echo 'プロジェクト: $PROJECT_PATH'"
        write text "echo 'タスク: $PROMPT_TEXT'"
        write text "echo ''"
        
        -- Claude Codeを起動
        write text "claude < '$prompt_file'"
        
        -- タブタイトルを設定
        set name to "Claude Auto - $SESSION_ID"
    end tell
end tell
EOF
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_info "iTerm2 session launched successfully"
        return 0
    else
        log_error "Failed to launch iTerm2 session (exit code: $exit_code)"
        return 1
    fi
}

# Warp でセッションを起動
launch_warp() {
    local prompt_file=$1
    
    log_info "Launching Warp session..."
    
    # Warpは新しいターミナルなので、基本的なAppleScript対応を試行
    osascript << EOF
tell application "Warp"
    activate
    
    -- 新しいタブを作成しようと試行
    delay 1
    
    -- キーボードショートカットで新しいタブを作成
    tell application "System Events"
        keystroke "t" using command down
        delay 0.5
        
        -- コマンドを入力
        keystroke "cd '$PROJECT_PATH'"
        keystroke return
        delay 0.5
        
        keystroke "echo 'Claude Automation System - セッション開始'"
        keystroke return
        
        keystroke "claude < '$prompt_file'"
        keystroke return
    end tell
end tell
EOF
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_info "Warp session launched successfully"
        return 0
    else
        log_warn "Warp launch may have issues (exit code: $exit_code)"
        log_info "Warpのサポートは実験的です。Terminal.appまたはiTerm2の使用を推奨します。"
        return 1
    fi
}

# ターミナルアプリケーションの起動
launch_terminal_session() {
    local prompt_file=$1
    
    case "$TERMINAL_TYPE" in
        "Terminal")
            launch_terminal_app "$prompt_file"
            ;;
        "iTerm")
            launch_iterm "$prompt_file"
            ;;
        "Warp")
            launch_warp "$prompt_file"
            ;;
        *)
            log_error "Unknown terminal type: $TERMINAL_TYPE"
            return 1
            ;;
    esac
}

# セッション情報の記録
record_session_info() {
    local prompt_file=$1
    local session_log="${CLAUDE_AUTO_HOME}/logs/terminal_sessions.json"
    
    # セッションログファイルの初期化
    if [[ ! -f "$session_log" ]]; then
        echo "[]" > "$session_log"
    fi
    
    # セッション情報を記録
    local session_info
    local started_at
    started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    session_info=$(jq -nc \
        --arg session_id "$SESSION_ID" \
        --arg project_path "$PROJECT_PATH" \
        --arg prompt_text "$PROMPT_TEXT" \
        --arg terminal_type "$TERMINAL_TYPE" \
        --arg prompt_file "$prompt_file" \
        --arg started_at "$started_at" \
        --arg status "launched" \
        '{
            session_id: $session_id,
            project_path: $project_path,
            prompt_text: $prompt_text,
            terminal_type: $terminal_type,
            prompt_file: $prompt_file,
            started_at: $started_at,
            status: $status
        }')
    
    # JSONファイルに追加
    local temp_file="${session_log}.tmp"
    jq --argjson new_session "$session_info" '. += [$new_session]' "$session_log" > "$temp_file" && mv "$temp_file" "$session_log"
    
    log_info "Session info recorded: $session_log"
}

# メイン処理
main() {
    log_info "Starting Terminal Launcher..."
    
    # 引数の検証
    validate_arguments "$@"
    
    # 既存のセッションをチェック
    check_existing_sessions
    
    # Claude Codeの可用性確認
    check_claude_availability
    
    # プロンプトファイルの作成
    local prompt_file
    prompt_file=$(create_prompt_file)
    
    # ターミナルセッションの起動
    if launch_terminal_session "$prompt_file"; then
        # セッション情報の記録
        record_session_info "$prompt_file"
        
        log_info "Terminal session launched successfully!"
        log_info "Session ID: $SESSION_ID"
        log_info "Prompt file: $prompt_file"
        
        # セッション監視のオプション情報
        cat << EOF

=== セッション起動完了 ===
セッションID: $SESSION_ID
プロジェクト: $PROJECT_PATH
ターミナル: $TERMINAL_TYPE

セッション監視:
  ログ確認: tail -f ${CLAUDE_AUTO_HOME}/logs/terminal_sessions.json
  プロンプト: cat $prompt_file

Claude Codeセッションが新しい${TERMINAL_TYPE}ウィンドウで起動されました。
EOF
        
        exit 0
    else
        log_error "Failed to launch terminal session"
        exit 1
    fi
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi