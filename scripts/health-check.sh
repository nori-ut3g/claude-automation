#!/usr/bin/env bash

# health-check.sh - Claude Automation Systemの状態を確認する
# 
# 使用方法:
#   ./scripts/health-check.sh [options]
#   
# オプション:
#   -v, --verbose   詳細情報を表示
#   -j, --json      JSON形式で出力
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
VERBOSE_MODE=false
JSON_OUTPUT=false

# ヘルスチェック結果
declare -A HEALTH_STATUS
HEALTH_STATUS[overall]="healthy"
HEALTH_STATUS[process]="unknown"
HEALTH_STATUS[config]="unknown"
HEALTH_STATUS[dependencies]="unknown"
HEALTH_STATUS[github_api]="unknown"
HEALTH_STATUS[disk_space]="unknown"
HEALTH_STATUS[logs]="unknown"

# 使用方法の表示
show_usage() {
    cat <<EOF
Usage: $0 [options]

Options:
    -v, --verbose   Show detailed information
    -j, --json      Output in JSON format
    -h, --help      Show this help message

Exit codes:
    0   System is healthy
    1   System has issues
    2   System is not running

Example:
    $0              # Basic health check
    $0 --verbose    # Detailed health check
    $0 --json       # JSON output for monitoring tools

EOF
}

# 引数の解析
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE_MODE=true
                shift
                ;;
            -j|--json)
                JSON_OUTPUT=true
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

# プロセスのチェック
check_process() {
    local pid_file="${CLAUDE_AUTO_HOME}/monitor.pid"
    
    if [[ ! -f "$pid_file" ]]; then
        HEALTH_STATUS[process]="not_running"
        return 1
    fi
    
    local pid
    pid=$(cat "$pid_file")
    
    if ps -p "$pid" > /dev/null 2>&1; then
        HEALTH_STATUS[process]="running"
        HEALTH_STATUS[process_pid]="$pid"
        
        # CPU使用率とメモリ使用量を取得
        if [[ "$VERBOSE_MODE" == "true" ]]; then
            if [[ "$(uname)" == "Darwin" ]]; then
                # macOS
                local stats
                stats=$(ps -p "$pid" -o %cpu,%mem,etime | tail -1)
                HEALTH_STATUS[process_cpu]=$(echo "$stats" | awk '{print $1}')
                HEALTH_STATUS[process_memory]=$(echo "$stats" | awk '{print $2}')
                HEALTH_STATUS[process_uptime]=$(echo "$stats" | awk '{print $3}')
            else
                # Linux
                local stats
                stats=$(ps -p "$pid" -o %cpu,%mem,etime --no-headers)
                HEALTH_STATUS[process_cpu]=$(echo "$stats" | awk '{print $1}')
                HEALTH_STATUS[process_memory]=$(echo "$stats" | awk '{print $2}')
                HEALTH_STATUS[process_uptime]=$(echo "$stats" | awk '{print $3}')
            fi
        fi
        
        return 0
    else
        HEALTH_STATUS[process]="stale_pid"
        return 1
    fi
}

# 設定のチェック
check_config() {
    # 設定ファイルの存在確認
    local config_files=(
        "repositories.yaml"
        "integrations.yaml"
        "claude-prompts.yaml"
    )
    
    local missing_files=()
    for file in "${config_files[@]}"; do
        if [[ ! -f "${CONFIG_DIR}/${file}" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        HEALTH_STATUS[config]="missing_files"
        HEALTH_STATUS[config_missing]="${missing_files[*]}"
        return 1
    fi
    
    # 設定の検証
    if validate_config > /dev/null 2>&1; then
        HEALTH_STATUS[config]="valid"
        
        # 監視中のリポジトリ数を取得
        if [[ "$VERBOSE_MODE" == "true" ]]; then
            local repo_count
            repo_count=$(get_enabled_repositories | wc -l)
            HEALTH_STATUS[config_repos]="$repo_count"
        fi
        
        return 0
    else
        HEALTH_STATUS[config]="invalid"
        return 1
    fi
}

# 依存関係のチェック
check_dependencies() {
    local required_commands=("git" "curl" "jq" "yq")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        HEALTH_STATUS[dependencies]="missing"
        HEALTH_STATUS[dependencies_missing]="${missing_commands[*]}"
        return 1
    else
        HEALTH_STATUS[dependencies]="installed"
        return 0
    fi
}

# GitHub API接続のチェック
check_github_api() {
    # GitHub トークンの確認
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        HEALTH_STATUS[github_api]="no_token"
        return 1
    fi
    
    # API接続テスト
    local response
    local http_code
    
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/user")
    
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]]; then
        HEALTH_STATUS[github_api]="connected"
        
        # レート制限情報を取得
        if [[ "$VERBOSE_MODE" == "true" ]]; then
            local rate_response
            rate_response=$(curl -s \
                -H "Authorization: token ${GITHUB_TOKEN}" \
                -H "Accept: application/vnd.github.v3+json" \
                "https://api.github.com/rate_limit")
            
            local rate_remaining
            local rate_limit
            rate_remaining=$(echo "$rate_response" | jq -r '.rate.remaining')
            rate_limit=$(echo "$rate_response" | jq -r '.rate.limit')
            
            HEALTH_STATUS[github_rate_remaining]="$rate_remaining"
            HEALTH_STATUS[github_rate_limit]="$rate_limit"
        fi
        
        return 0
    elif [[ "$http_code" == "401" ]]; then
        HEALTH_STATUS[github_api]="invalid_token"
        return 1
    else
        HEALTH_STATUS[github_api]="connection_error"
        HEALTH_STATUS[github_api_error]="HTTP $http_code"
        return 1
    fi
}

# ディスク容量のチェック
check_disk_space() {
    local workspace_dir="${CLAUDE_AUTO_HOME}/workspace"
    local log_dir="${CLAUDE_AUTO_HOME}/logs"
    
    # ディスク使用率を取得
    local disk_usage
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        disk_usage=$(df -h "$CLAUDE_AUTO_HOME" | tail -1 | awk '{print $5}' | sed 's/%//')
    else
        # Linux
        disk_usage=$(df -h "$CLAUDE_AUTO_HOME" | tail -1 | awk '{print $5}' | sed 's/%//')
    fi
    
    HEALTH_STATUS[disk_usage]="$disk_usage"
    
    # ワークスペースのサイズを取得
    if [[ -d "$workspace_dir" ]]; then
        local workspace_size
        workspace_size=$(du -sh "$workspace_dir" 2>/dev/null | cut -f1)
        HEALTH_STATUS[workspace_size]="$workspace_size"
    fi
    
    # ログディレクトリのサイズを取得
    if [[ -d "$log_dir" ]]; then
        local log_size
        log_size=$(du -sh "$log_dir" 2>/dev/null | cut -f1)
        HEALTH_STATUS[log_size]="$log_size"
    fi
    
    # ディスク使用率が90%以上の場合は警告
    if [[ $disk_usage -ge 90 ]]; then
        HEALTH_STATUS[disk_space]="critical"
        return 1
    elif [[ $disk_usage -ge 80 ]]; then
        HEALTH_STATUS[disk_space]="warning"
        return 0
    else
        HEALTH_STATUS[disk_space]="healthy"
        return 0
    fi
}

# ログのチェック
check_logs() {
    local log_file="${CLAUDE_AUTO_HOME}/logs/claude-automation.log"
    
    if [[ ! -f "$log_file" ]]; then
        HEALTH_STATUS[logs]="no_logs"
        return 0
    fi
    
    # 最近のエラーを確認
    local recent_errors
    recent_errors=$(tail -n 1000 "$log_file" 2>/dev/null | grep -c "\[ERROR\]" || echo "0")
    
    HEALTH_STATUS[logs_recent_errors]="$recent_errors"
    
    if [[ $recent_errors -gt 50 ]]; then
        HEALTH_STATUS[logs]="high_error_rate"
        return 1
    elif [[ $recent_errors -gt 10 ]]; then
        HEALTH_STATUS[logs]="moderate_errors"
        return 0
    else
        HEALTH_STATUS[logs]="healthy"
        return 0
    fi
}

# 全体的な健康状態の判定
determine_overall_health() {
    local has_critical=false
    local has_warning=false
    
    # クリティカルな問題のチェック
    if [[ "${HEALTH_STATUS[process]}" != "running" ]]; then
        has_critical=true
    fi
    
    if [[ "${HEALTH_STATUS[config]}" == "invalid" ]] || [[ "${HEALTH_STATUS[config]}" == "missing_files" ]]; then
        has_critical=true
    fi
    
    if [[ "${HEALTH_STATUS[dependencies]}" == "missing" ]]; then
        has_critical=true
    fi
    
    if [[ "${HEALTH_STATUS[github_api]}" != "connected" ]]; then
        has_critical=true
    fi
    
    if [[ "${HEALTH_STATUS[disk_space]}" == "critical" ]]; then
        has_critical=true
    fi
    
    # 警告レベルの問題のチェック
    if [[ "${HEALTH_STATUS[disk_space]}" == "warning" ]]; then
        has_warning=true
    fi
    
    if [[ "${HEALTH_STATUS[logs]}" == "high_error_rate" ]]; then
        has_warning=true
    fi
    
    # 全体的な状態の決定
    if [[ "$has_critical" == "true" ]]; then
        HEALTH_STATUS[overall]="unhealthy"
    elif [[ "$has_warning" == "true" ]]; then
        HEALTH_STATUS[overall]="degraded"
    else
        HEALTH_STATUS[overall]="healthy"
    fi
}

# 結果の表示（通常形式）
show_results_normal() {
    echo "Claude Automation System Health Check"
    echo "====================================="
    echo ""
    
    # プロセス状態
    echo -n "Process Status: "
    case "${HEALTH_STATUS[process]}" in
        "running")
            echo "✅ Running (PID: ${HEALTH_STATUS[process_pid]})"
            if [[ "$VERBOSE_MODE" == "true" ]]; then
                echo "  CPU: ${HEALTH_STATUS[process_cpu]}%"
                echo "  Memory: ${HEALTH_STATUS[process_memory]}%"
                echo "  Uptime: ${HEALTH_STATUS[process_uptime]}"
            fi
            ;;
        "not_running")
            echo "❌ Not running"
            ;;
        "stale_pid")
            echo "⚠️  Stale PID file"
            ;;
    esac
    echo ""
    
    # 設定状態
    echo -n "Configuration: "
    case "${HEALTH_STATUS[config]}" in
        "valid")
            echo "✅ Valid"
            if [[ "$VERBOSE_MODE" == "true" ]] && [[ -n "${HEALTH_STATUS[config_repos]:-}" ]]; then
                echo "  Monitored repositories: ${HEALTH_STATUS[config_repos]}"
            fi
            ;;
        "invalid")
            echo "❌ Invalid"
            ;;
        "missing_files")
            echo "❌ Missing files: ${HEALTH_STATUS[config_missing]}"
            ;;
    esac
    echo ""
    
    # 依存関係
    echo -n "Dependencies: "
    case "${HEALTH_STATUS[dependencies]}" in
        "installed")
            echo "✅ All installed"
            ;;
        "missing")
            echo "❌ Missing: ${HEALTH_STATUS[dependencies_missing]}"
            ;;
    esac
    echo ""
    
    # GitHub API
    echo -n "GitHub API: "
    case "${HEALTH_STATUS[github_api]}" in
        "connected")
            echo "✅ Connected"
            if [[ "$VERBOSE_MODE" == "true" ]] && [[ -n "${HEALTH_STATUS[github_rate_remaining]:-}" ]]; then
                echo "  API Rate: ${HEALTH_STATUS[github_rate_remaining]}/${HEALTH_STATUS[github_rate_limit]}"
            fi
            ;;
        "no_token")
            echo "❌ No token configured"
            ;;
        "invalid_token")
            echo "❌ Invalid token"
            ;;
        "connection_error")
            echo "❌ Connection error: ${HEALTH_STATUS[github_api_error]}"
            ;;
    esac
    echo ""
    
    # ディスク容量
    echo -n "Disk Space: "
    case "${HEALTH_STATUS[disk_space]}" in
        "healthy")
            echo "✅ Healthy (${HEALTH_STATUS[disk_usage]}% used)"
            ;;
        "warning")
            echo "⚠️  Warning (${HEALTH_STATUS[disk_usage]}% used)"
            ;;
        "critical")
            echo "❌ Critical (${HEALTH_STATUS[disk_usage]}% used)"
            ;;
    esac
    
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        [[ -n "${HEALTH_STATUS[workspace_size]:-}" ]] && echo "  Workspace: ${HEALTH_STATUS[workspace_size]}"
        [[ -n "${HEALTH_STATUS[log_size]:-}" ]] && echo "  Logs: ${HEALTH_STATUS[log_size]}"
    fi
    echo ""
    
    # ログ状態
    echo -n "Log Status: "
    case "${HEALTH_STATUS[logs]}" in
        "healthy")
            echo "✅ Healthy"
            ;;
        "moderate_errors")
            echo "⚠️  Moderate errors (${HEALTH_STATUS[logs_recent_errors]} recent errors)"
            ;;
        "high_error_rate")
            echo "❌ High error rate (${HEALTH_STATUS[logs_recent_errors]} recent errors)"
            ;;
        "no_logs")
            echo "ℹ️  No logs found"
            ;;
    esac
    echo ""
    
    # 全体的な状態
    echo "====================================="
    echo -n "Overall Status: "
    case "${HEALTH_STATUS[overall]}" in
        "healthy")
            echo "✅ HEALTHY"
            ;;
        "degraded")
            echo "⚠️  DEGRADED"
            ;;
        "unhealthy")
            echo "❌ UNHEALTHY"
            ;;
    esac
    echo "====================================="
}

# 結果の表示（JSON形式）
show_results_json() {
    local json_output="{"
    local first=true
    
    for key in "${!HEALTH_STATUS[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            json_output+=","
        fi
        json_output+="\"$key\":\"${HEALTH_STATUS[$key]}\""
    done
    
    json_output+="}"
    
    echo "$json_output" | jq .
}

# メイン処理
main() {
    # 引数の解析
    parse_arguments "$@"
    
    # JSON出力モードの場合はログを無効化
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        exec 2>/dev/null
    fi
    
    # ヘルスチェックの実行
    check_process
    check_config
    check_dependencies
    check_github_api
    check_disk_space
    check_logs
    
    # 全体的な健康状態の判定
    determine_overall_health
    
    # 結果の表示
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        show_results_json
    else
        show_results_normal
    fi
    
    # 終了コードの決定
    case "${HEALTH_STATUS[overall]}" in
        "healthy")
            exit 0
            ;;
        "degraded")
            exit 1
            ;;
        "unhealthy")
            if [[ "${HEALTH_STATUS[process]}" != "running" ]]; then
                exit 2
            else
                exit 1
            fi
            ;;
    esac
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi