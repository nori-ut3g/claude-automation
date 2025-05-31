#!/usr/bin/env bash

# start.sh - Claude Automation Systemを起動する
# 
# 使用方法:
#   ./scripts/start.sh [options]
#   
# オプション:
#   -d, --daemon    バックグラウンドで実行
#   -v, --verbose   詳細ログを出力
#   -h, --help      ヘルプを表示

set -euo pipefail

# 基本パスの設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_AUTO_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export CLAUDE_AUTO_HOME

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"

# デフォルト設定
DAEMON_MODE=false
VERBOSE_MODE=false

# 使用方法の表示
show_usage() {
    cat <<EOF
Usage: $0 [options]

Options:
    -d, --daemon    Run in background (daemon mode)
    -v, --verbose   Enable verbose logging
    -h, --help      Show this help message

Environment variables:
    CLAUDE_AUTO_HOME    Base directory (default: auto-detected)
    LOG_LEVEL          Log level (DEBUG, INFO, WARN, ERROR)
    GITHUB_TOKEN       GitHub personal access token (required)

Example:
    $0                  # Start in foreground
    $0 --daemon         # Start in background
    $0 -d -v            # Start in background with verbose logging

EOF
}

# 引数の解析
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--daemon)
                DAEMON_MODE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE_MODE=true
                export LOG_LEVEL="DEBUG"
                export LOG_LEVEL_STRING="DEBUG"
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

# 環境チェック
check_environment() {
    log_info "Checking environment..."
    
    # gh CLI認証のチェック
    if ! gh auth status >/dev/null 2>&1; then
        log_error "gh CLI is not authenticated"
        log_error "Please run: gh auth login"
        return 1
    fi
    
    # 依存コマンドのチェック
    local required_commands=("git" "gh" "jq" "yq")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        log_error "Please install them using:"
        log_error "  brew install ${missing_commands[*]}"
        return 1
    fi
    
    # 設定ファイルの検証
    if ! validate_config; then
        log_error "Configuration validation failed"
        return 1
    fi
    
    # PIDファイルのチェック
    local pid_file="${CLAUDE_AUTO_HOME}/monitor.pid"
    if [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid=$(cat "$pid_file")
        
        if ps -p "$old_pid" > /dev/null 2>&1; then
            log_error "Claude Automation System is already running (PID: $old_pid)"
            log_error "Use './scripts/stop.sh' to stop it first"
            return 1
        else
            log_warn "Removing stale PID file"
            rm -f "$pid_file"
        fi
    fi
    
    log_info "Environment check passed"
    return 0
}

# ディレクトリの準備
prepare_directories() {
    log_info "Preparing directories..."
    
    # 必要なディレクトリを作成
    local dirs=(
        "${CLAUDE_AUTO_HOME}/logs"
        "${CLAUDE_AUTO_HOME}/logs/claude"
        "${CLAUDE_AUTO_HOME}/workspace"
        "${CLAUDE_AUTO_HOME}/locks"
        "${CLAUDE_AUTO_HOME}/pending_events"
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
    done
    
    # 実行履歴ファイルの初期化
    local history_file="${CLAUDE_AUTO_HOME}/execution_history.json"
    if [[ ! -f "$history_file" ]]; then
        echo "[]" > "$history_file"
    fi
    
    log_info "Directories prepared"
}

# サービスの起動
start_service() {
    local monitor_script="${CLAUDE_AUTO_HOME}/src/core/monitor.sh"
    
    if [[ ! -x "$monitor_script" ]]; then
        log_error "Monitor script not found or not executable: $monitor_script"
        return 1
    fi
    
    # スクリプトに実行権限を付与
    chmod +x "${CLAUDE_AUTO_HOME}/src/core/"*.sh
    chmod +x "${CLAUDE_AUTO_HOME}/src/utils/"*.sh
    chmod +x "${CLAUDE_AUTO_HOME}/scripts/"*.sh
    
    if [[ "$DAEMON_MODE" == "true" ]]; then
        log_info "Starting Claude Automation System in daemon mode..."
        
        # ログファイル
        local log_file="${CLAUDE_AUTO_HOME}/logs/daemon.log"
        
        # バックグラウンドで起動
        nohup "$monitor_script" >> "$log_file" 2>&1 &
        local pid=$!
        
        # PIDファイルの作成
        echo "$pid" > "${CLAUDE_AUTO_HOME}/monitor.pid"
        
        # 起動確認
        sleep 2
        if ps -p "$pid" > /dev/null 2>&1; then
            log_info "Claude Automation System started successfully (PID: $pid)"
            log_info "Log file: $log_file"
            log_info "Use './scripts/stop.sh' to stop the service"
            return 0
        else
            log_error "Failed to start Claude Automation System"
            rm -f "${CLAUDE_AUTO_HOME}/monitor.pid"
            return 1
        fi
    else
        log_info "Starting Claude Automation System in foreground..."
        log_info "Press Ctrl+C to stop"
        
        # フォアグラウンドで実行
        exec "$monitor_script"
    fi
}

# 起動後の情報表示
show_startup_info() {
    log_info "============================================"
    log_info "Claude Automation System is running"
    log_info "============================================"
    log_info "Configuration:"
    log_info "  Home directory: $CLAUDE_AUTO_HOME"
    log_info "  Log level: ${LOG_LEVEL_STRING:-INFO}"
    log_info "  Config directory: ${CONFIG_DIR}"
    
    # 監視中のリポジトリを表示
    local enabled_repos
    enabled_repos=$(get_enabled_repositories)
    
    if [[ -n "$enabled_repos" ]]; then
        log_info "Monitoring repositories:"
        while IFS= read -r repo; do
            log_info "  - $repo"
        done <<< "$enabled_repos"
    else
        log_warn "No repositories configured for monitoring"
    fi
    
    log_info "============================================"
}

# メイン処理
main() {
    # 引数の解析
    parse_arguments "$@"
    
    # ロゴ表示
    cat <<'EOF'
   _____ _                 _        _         _                        _   _             
  / ____| |               | |      | |       | |                      | | (_)            
 | |    | | __ _ _   _  __| | ___  | |  _ __ | |_ ___  _ __ ___   __ _| |_ _  ___  _ __  
 | |    | |/ _` | | | |/ _` |/ _ \ | | | '_ \| __/ _ \| '_ ` _ \ / _` | __| |/ _ \| '_ \ 
 | |____| | (_| | |_| | (_| |  __/ | | | | | | || (_) | | | | | | (_| | |_| | (_) | | | |
  \_____|_|\__,_|\__,_|\__,_|\___| |_| |_| |_|\__\___/|_| |_| |_|\__,_|\__|_|\___/|_| |_|
                                                                                          
EOF
    
    log_info "Starting Claude Automation System v2.0..."
    
    # 環境チェック
    if ! check_environment; then
        exit 1
    fi
    
    # ディレクトリの準備
    prepare_directories
    
    # 起動情報の表示
    if [[ "$DAEMON_MODE" == "true" ]]; then
        show_startup_info
    fi
    
    # サービスの起動
    if ! start_service; then
        exit 1
    fi
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi