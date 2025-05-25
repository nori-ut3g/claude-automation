#!/usr/bin/env bash

# stop.sh - Claude Automation Systemを停止する
# 
# 使用方法:
#   ./scripts/stop.sh [options]
#   
# オプション:
#   -f, --force     強制終了
#   -h, --help      ヘルプを表示

set -euo pipefail

# 基本パスの設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_AUTO_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export CLAUDE_AUTO_HOME

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"

# デフォルト設定
FORCE_STOP=false

# 使用方法の表示
show_usage() {
    cat <<EOF
Usage: $0 [options]

Options:
    -f, --force     Force stop (kill -9)
    -h, --help      Show this help message

Example:
    $0              # Graceful shutdown
    $0 --force      # Force stop

EOF
}

# 引数の解析
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                FORCE_STOP=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# PIDファイルからプロセスIDを取得
get_monitor_pid() {
    local pid_file="${CLAUDE_AUTO_HOME}/monitor.pid"
    
    if [[ ! -f "$pid_file" ]]; then
        return 1
    fi
    
    cat "$pid_file"
}

# プロセスの停止
stop_process() {
    local pid=$1
    local signal=${2:-TERM}
    
    if kill -"$signal" "$pid" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 子プロセスの取得
get_child_processes() {
    local parent_pid=$1
    
    # macOS と Linux で異なるpsコマンドを使用
    if [[ "$(uname)" == "Darwin" ]]; then
        ps -o pid,ppid | awk -v ppid="$parent_pid" '$2 == ppid {print $1}'
    else
        ps --ppid "$parent_pid" -o pid --no-headers 2>/dev/null || true
    fi
}

# プロセスツリーの停止
stop_process_tree() {
    local pid=$1
    local signal=${2:-TERM}
    
    # 子プロセスを先に停止
    local child_pids
    child_pids=$(get_child_processes "$pid")
    
    if [[ -n "$child_pids" ]]; then
        log_debug "Stopping child processes: $child_pids"
        for child_pid in $child_pids; do
            stop_process_tree "$child_pid" "$signal"
        done
    fi
    
    # 親プロセスを停止
    if ps -p "$pid" > /dev/null 2>&1; then
        log_debug "Stopping process: $pid"
        stop_process "$pid" "$signal"
    fi
}

# グレースフルシャットダウン
graceful_shutdown() {
    local pid=$1
    local timeout=30  # 30秒のタイムアウト
    
    log_info "Sending SIGTERM to process $pid..."
    
    # プロセスツリー全体にSIGTERMを送信
    stop_process_tree "$pid" "TERM"
    
    # プロセスの終了を待つ
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if ! ps -p "$pid" > /dev/null 2>&1; then
            log_info "Process stopped gracefully"
            return 0
        fi
        
        sleep 1
        ((elapsed++))
        
        # 進捗表示
        if [[ $((elapsed % 5)) -eq 0 ]]; then
            log_info "Waiting for process to stop... (${elapsed}s/${timeout}s)"
        fi
    done
    
    log_warn "Process did not stop within timeout"
    return 1
}

# 強制終了
force_stop() {
    local pid=$1
    
    log_warn "Force stopping process $pid..."
    
    # プロセスツリー全体にSIGKILLを送信
    stop_process_tree "$pid" "KILL"
    
    sleep 1
    
    if ps -p "$pid" > /dev/null 2>&1; then
        log_error "Failed to force stop process"
        return 1
    else
        log_info "Process force stopped"
        return 0
    fi
}

# クリーンアップ
cleanup() {
    log_info "Cleaning up..."
    
    # PIDファイルの削除
    rm -f "${CLAUDE_AUTO_HOME}/monitor.pid"
    
    # ロックファイルの削除
    local lock_dir="${CLAUDE_AUTO_HOME}/locks"
    if [[ -d "$lock_dir" ]]; then
        log_debug "Removing lock files..."
        find "$lock_dir" -type d -name "*.lock" -exec rm -rf {} + 2>/dev/null || true
    fi
    
    # 一時ファイルの削除
    local temp_files=(
        "${CLAUDE_AUTO_HOME}/monitor.state"
    )
    
    for file in "${temp_files[@]}"; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
        fi
    done
    
    log_info "Cleanup completed"
}

# 停止状態の確認
verify_stopped() {
    local pid=$1
    
    # プロセスが停止していることを確認
    if ps -p "$pid" > /dev/null 2>&1; then
        return 1
    fi
    
    # 子プロセスも停止していることを確認
    local child_pids
    child_pids=$(get_child_processes "$pid")
    
    if [[ -n "$child_pids" ]]; then
        for child_pid in $child_pids; do
            if ps -p "$child_pid" > /dev/null 2>&1; then
                return 1
            fi
        done
    fi
    
    return 0
}

# メイン処理
main() {
    # 引数の解析
    parse_arguments "$@"
    
    log_info "Stopping Claude Automation System..."
    
    # PIDの取得
    local pid
    if ! pid=$(get_monitor_pid); then
        log_warn "Claude Automation System is not running"
        log_warn "PID file not found: ${CLAUDE_AUTO_HOME}/monitor.pid"
        
        # クリーンアップは実行
        cleanup
        exit 0
    fi
    
    # プロセスの存在確認
    if ! ps -p "$pid" > /dev/null 2>&1; then
        log_warn "Process $pid is not running"
        log_warn "Removing stale PID file"
        cleanup
        exit 0
    fi
    
    log_info "Found Claude Automation System process (PID: $pid)"
    
    # 停止処理
    if [[ "$FORCE_STOP" == "true" ]]; then
        # 強制終了
        if force_stop "$pid"; then
            log_info "Claude Automation System force stopped"
        else
            log_error "Failed to force stop Claude Automation System"
            exit 1
        fi
    else
        # グレースフルシャットダウン
        if graceful_shutdown "$pid"; then
            log_info "Claude Automation System stopped gracefully"
        else
            log_warn "Graceful shutdown failed, attempting force stop..."
            if force_stop "$pid"; then
                log_info "Claude Automation System force stopped"
            else
                log_error "Failed to stop Claude Automation System"
                exit 1
            fi
        fi
    fi
    
    # 停止確認
    if verify_stopped "$pid"; then
        log_info "All processes stopped successfully"
    else
        log_error "Some processes may still be running"
    fi
    
    # クリーンアップ
    cleanup
    
    log_info "Claude Automation System stopped"
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi