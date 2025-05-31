#!/usr/bin/env bash

# cleanup-locks.sh - ロック管理とクリーンアップユーティリティ
# 
# 使用方法:
#   ./scripts/cleanup-locks.sh [options]
#   
# オプション:
#   -a, --age SECONDS    指定した秒数より古いロックを削除 (デフォルト: 900秒 = 15分)
#   -f, --force          強制的にすべてのロックを削除
#   -l, --list           現在のロック状況を表示
#   -h, --help           このヘルプを表示

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"

# 定数
readonly EXECUTION_LOCK_DIR="${CLAUDE_AUTO_HOME}/locks"

# デフォルト設定
MAX_AGE=900  # 15分
FORCE_CLEAN=false
LIST_ONLY=false

# ヘルプ表示
show_help() {
    cat << EOF
Lock Management and Cleanup Utility

Usage: $0 [options]

Options:
    -a, --age SECONDS    Clean locks older than SECONDS (default: 900 = 15 minutes)
    -f, --force          Force remove all locks regardless of age or status
    -l, --list           List current lock status without cleaning
    -h, --help           Show this help message

Examples:
    $0                   # Clean locks older than 15 minutes
    $0 -a 300           # Clean locks older than 5 minutes
    $0 -l               # List current locks
    $0 -f               # Force clean all locks

EOF
}

# 引数解析
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--age)
                MAX_AGE="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_CLEAN=true
                shift
                ;;
            -l|--list)
                LIST_ONLY=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# ロック状況の表示
list_locks() {
    local current_time
    current_time=$(date +%s)
    local total_locks=0
    local active_locks=0
    local stale_locks=0
    
    log_info "Current lock status:"
    
    if [[ ! -d "$EXECUTION_LOCK_DIR" ]]; then
        log_info "No lock directory found"
        return 0
    fi
    
    echo "┌─────────────────────────────────────────────────────────────────────────────┐"
    echo "│ Lock Name                    │ PID    │ Host      │ Age (s) │ Status      │"
    echo "├─────────────────────────────────────────────────────────────────────────────┤"
    
    find "$EXECUTION_LOCK_DIR" -name "*.lock" -type d 2>/dev/null | sort | while IFS= read -r lock_file; do
        local lock_name
        lock_name=$(basename "$lock_file" .lock)
        ((total_locks++))
        
        # ロック情報を読み取り
        local lock_pid=""
        local lock_time=""
        local lock_host=""
        
        if [[ -f "${lock_file}/pid" ]]; then
            lock_pid=$(cat "${lock_file}/pid" 2>/dev/null || echo "N/A")
        fi
        if [[ -f "${lock_file}/timestamp" ]]; then
            lock_time=$(cat "${lock_file}/timestamp" 2>/dev/null || echo "")
        fi
        if [[ -f "${lock_file}/host" ]]; then
            lock_host=$(cat "${lock_file}/host" 2>/dev/null || echo "unknown")
        fi
        
        # 年齢計算
        local age="N/A"
        if [[ -n "$lock_time" ]]; then
            age=$((current_time - lock_time))
        fi
        
        # ステータス判定
        local status="Unknown"
        if [[ -n "$lock_pid" ]]; then
            if [[ "$lock_host" == "$(hostname)" ]]; then
                if ps -p "$lock_pid" > /dev/null 2>&1; then
                    status="Active"
                    ((active_locks++))
                else
                    status="Stale (Dead)"
                    ((stale_locks++))
                fi
            else
                status="Remote"
            fi
        else
            status="Incomplete"
            ((stale_locks++))
        fi
        
        # フォーマット済み表示
        printf "│ %-28s │ %-6s │ %-9s │ %-7s │ %-11s │\n" \
            "${lock_name:0:28}" \
            "${lock_pid:0:6}" \
            "${lock_host:0:9}" \
            "$age" \
            "$status"
    done
    
    echo "└─────────────────────────────────────────────────────────────────────────────┘"
    echo
    echo "Summary:"
    echo "  Total locks: $total_locks"
    echo "  Active locks: $active_locks" 
    echo "  Stale locks: $stale_locks"
}

# 強制クリーンアップ
force_cleanup() {
    local cleaned_count=0
    
    log_warn "Force cleaning ALL locks..."
    
    if [[ ! -d "$EXECUTION_LOCK_DIR" ]]; then
        log_info "No lock directory found"
        return 0
    fi
    
    find "$EXECUTION_LOCK_DIR" -name "*.lock" -type d 2>/dev/null | while IFS= read -r lock_file; do
        local lock_name
        lock_name=$(basename "$lock_file" .lock)
        
        if rm -rf "$lock_file" 2>/dev/null; then
            log_info "Force removed lock: $lock_name"
            ((cleaned_count++))
        else
            log_error "Failed to remove lock: $lock_name"
        fi
    done
    
    log_info "Force cleanup completed: $cleaned_count locks removed"
}

# 通常のクリーンアップ
normal_cleanup() {
    local max_age=$1
    local current_time
    current_time=$(date +%s)
    local cleaned_count=0
    
    log_info "Cleaning up stale locks older than ${max_age} seconds"
    
    if [[ ! -d "$EXECUTION_LOCK_DIR" ]]; then
        log_info "No lock directory found"
        return 0
    fi
    
    find "$EXECUTION_LOCK_DIR" -name "*.lock" -type d 2>/dev/null | while IFS= read -r lock_file; do
        local lock_name
        lock_name=$(basename "$lock_file" .lock)
        local should_remove=false
        local reason=""
        
        # ロック情報を読み取り
        local lock_pid=""
        local lock_time=""
        local lock_host=""
        
        if [[ -f "${lock_file}/pid" ]]; then
            lock_pid=$(cat "${lock_file}/pid" 2>/dev/null || echo "")
        fi
        if [[ -f "${lock_file}/timestamp" ]]; then
            lock_time=$(cat "${lock_file}/timestamp" 2>/dev/null || echo "")
        fi
        if [[ -f "${lock_file}/host" ]]; then
            lock_host=$(cat "${lock_file}/host" 2>/dev/null || echo "")
        fi
        
        # クリーンアップ条件の判定
        if [[ -z "$lock_pid" ]] || [[ -z "$lock_time" ]]; then
            should_remove=true
            reason="incomplete lock information"
        elif [[ "$lock_host" == "$(hostname)" ]] && ! ps -p "$lock_pid" > /dev/null 2>&1; then
            should_remove=true
            reason="process $lock_pid no longer exists"
        elif [[ $((current_time - lock_time)) -gt $max_age ]]; then
            should_remove=true
            reason="lock expired (age: $((current_time - lock_time))s > ${max_age}s)"
        fi
        
        # 古いロックを削除
        if [[ "$should_remove" == "true" ]]; then
            if rm -rf "$lock_file" 2>/dev/null; then
                log_info "Cleaned up stale lock: $lock_name ($reason)"
                ((cleaned_count++))
            else
                log_error "Failed to clean up lock: $lock_name"
            fi
        else
            log_debug "Keeping active lock: $lock_name (PID: $lock_pid, age: $((current_time - lock_time))s)"
        fi
    done
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleanup completed: $cleaned_count stale locks removed"
    else
        log_info "No stale locks found"
    fi
}

# メイン処理
main() {
    parse_arguments "$@"
    
    # ロックディレクトリの作成
    mkdir -p "$EXECUTION_LOCK_DIR"
    
    if [[ "$LIST_ONLY" == "true" ]]; then
        list_locks
    elif [[ "$FORCE_CLEAN" == "true" ]]; then
        force_cleanup
    else
        normal_cleanup "$MAX_AGE"
    fi
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi