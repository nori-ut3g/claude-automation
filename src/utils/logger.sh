#!/usr/bin/env bash

# logger.sh - ログ出力機能を提供するユーティリティ
# 
# 使用方法:
#   source src/utils/logger.sh
#   log_info "情報メッセージ"
#   log_error "エラーメッセージ"

set -euo pipefail

# カラーコード定義
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

# ログレベル定義
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

# デフォルト設定
LOG_DIR="${LOG_DIR:-${CLAUDE_AUTO_HOME}/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/claude-automation.log}"
LOG_LEVEL="${LOG_LEVEL:-$LOG_LEVEL_INFO}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-10485760}" # 10MB
LOG_MAX_FILES="${LOG_MAX_FILES:-10}"

# コンポーネント名（呼び出し元スクリプト名から取得）
COMPONENT="${COMPONENT:-$(basename "${BASH_SOURCE[1]}" .sh)}"

# ログディレクトリの作成
mkdir -p "$LOG_DIR"

# ログレベルを文字列に変換
get_log_level_string() {
    local level=$1
    case $level in
        $LOG_LEVEL_DEBUG) echo "DEBUG" ;;
        $LOG_LEVEL_INFO)  echo "INFO" ;;
        $LOG_LEVEL_WARN)  echo "WARN" ;;
        $LOG_LEVEL_ERROR) echo "ERROR" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# ログレベルを数値に変換
get_log_level_value() {
    local level_str=$1
    case $level_str in
        "DEBUG") echo $LOG_LEVEL_DEBUG ;;
        "INFO")  echo $LOG_LEVEL_INFO ;;
        "WARN")  echo $LOG_LEVEL_WARN ;;
        "ERROR") echo $LOG_LEVEL_ERROR ;;
        *) echo $LOG_LEVEL_INFO ;;
    esac
}

# 機密情報のマスキング
mask_sensitive_data() {
    local message=$1
    
    # トークンやパスワードなどをマスク
    echo "$message" | sed -E \
        -e 's/(token["\s:=]+)[^\s"]*/\1*****/gi' \
        -e 's/(password["\s:=]+)[^\s"]*/\1*****/gi' \
        -e 's/(api_key["\s:=]+)[^\s"]*/\1*****/gi' \
        -e 's/(secret["\s:=]+)[^\s"]*/\1*****/gi' \
        -e 's/ghp_[a-zA-Z0-9]{36}/ghp_*****/g' \
        -e 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/****@****/g'
}

# ログローテーション
rotate_logs() {
    local current_size
    current_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    
    if [[ $current_size -gt $LOG_MAX_SIZE ]]; then
        # 古いログファイルを削除
        find "$LOG_DIR" -name "claude-automation.log.*" | sort -r | tail -n +$LOG_MAX_FILES | xargs rm -f 2>/dev/null || true
        
        # 既存のログファイルをローテート
        for i in $(seq $((LOG_MAX_FILES - 1)) -1 1); do
            if [[ -f "$LOG_FILE.$i" ]]; then
                mv "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))"
            fi
        done
        
        # 現在のログファイルをローテート
        mv "$LOG_FILE" "$LOG_FILE.1"
        
        # 新しいログファイルを作成
        touch "$LOG_FILE"
    fi
}

# 基本ログ出力関数
log_message() {
    local level=$1
    local message=$2
    local color=${3:-$COLOR_RESET}
    
    # 現在のログレベルを環境変数から取得（動的変更対応）
    local current_log_level
    current_log_level=$(get_log_level_value "${LOG_LEVEL_STRING:-INFO}")
    
    # ログレベルチェック
    if [[ $level -lt $current_log_level ]]; then
        return
    fi
    
    # タイムスタンプ
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # ログレベル文字列
    local level_str
    level_str=$(get_log_level_string $level)
    
    # 機密情報のマスキング
    local masked_message
    masked_message=$(mask_sensitive_data "$message")
    
    # フォーマット済みメッセージ
    local formatted_message="[$timestamp] [$level_str] [$COMPONENT] $masked_message"
    
    # コンソール出力（カラー付き）
    if [[ -t 1 ]]; then
        echo -e "${color}${formatted_message}${COLOR_RESET}"
    else
        echo "$formatted_message"
    fi
    
    # ファイル出力
    echo "$formatted_message" >> "$LOG_FILE"
    
    # ログローテーション
    rotate_logs
}

# パブリック関数
log_debug() {
    log_message $LOG_LEVEL_DEBUG "$1" "$COLOR_BLUE"
}

log_info() {
    log_message $LOG_LEVEL_INFO "$1" "$COLOR_GREEN"
}

log_warn() {
    log_message $LOG_LEVEL_WARN "$1" "$COLOR_YELLOW"
}

log_error() {
    log_message $LOG_LEVEL_ERROR "$1" "$COLOR_RED"
}

# 構造化ログ出力
log_json() {
    local level=$1
    local event=$2
    shift 2
    
    local json="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    json+="\"level\":\"$(get_log_level_string $level)\","
    json+="\"component\":\"$COMPONENT\","
    json+="\"event\":\"$event\""
    
    # 追加のキーバリューペア
    while [[ $# -gt 0 ]]; do
        json+=",\"$1\":\"$2\""
        shift 2
    done
    
    json+="}"
    
    log_message $level "$json"
}

# エラートラップ設定
setup_error_trap() {
    trap 'log_error "Error occurred in $BASH_SOURCE at line $LINENO"' ERR
}

# ログ設定の表示
show_log_config() {
    log_info "Log configuration:"
    log_info "  LOG_DIR: $LOG_DIR"
    log_info "  LOG_FILE: $LOG_FILE"
    log_info "  LOG_LEVEL: $(get_log_level_string $(get_log_level_value "${LOG_LEVEL_STRING:-INFO}"))"
    log_info "  LOG_MAX_SIZE: $LOG_MAX_SIZE"
    log_info "  LOG_MAX_FILES: $LOG_MAX_FILES"
    log_info "  COMPONENT: $COMPONENT"
}

# プログレスバー表示
log_progress() {
    local current=$1
    local total=$2
    local message=${3:-"Progress"}
    
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    printf "\r%s: [" "$message"
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] %d%%" "$percent"
    
    if [[ $current -eq $total ]]; then
        echo
    fi
}

# 実行時間計測
log_execution_time() {
    local start_time=$1
    local end_time=$2
    local operation=$3
    
    local duration=$((end_time - start_time))
    log_info "Operation '$operation' completed in $duration seconds"
}

# 初期化
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 直接実行された場合のテスト
    show_log_config
    log_debug "This is a debug message"
    log_info "This is an info message"
    log_warn "This is a warning message"
    log_error "This is an error message"
    log_json $LOG_LEVEL_INFO "test_event" "key1" "value1" "key2" "value2"
fi