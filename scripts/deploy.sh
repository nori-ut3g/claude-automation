#!/usr/bin/env bash

# deploy.sh - Claude Automation Systemを本番環境にデプロイ
# 
# 使用方法:
#   ./scripts/deploy.sh [options]
#   
# オプション:
#   -t, --target <host>     デプロイ先ホスト（デフォルト: raspberry-pi.local）
#   -u, --user <user>       SSH ユーザー（デフォルト: pi）
#   -p, --path <path>       インストールパス（デフォルト: /opt/claude-automation）
#   -s, --service           systemdサービスとして設定
#   -h, --help              ヘルプを表示

set -euo pipefail

# 基本パスの設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_AUTO_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

# デフォルト設定
TARGET_HOST="raspberry-pi.local"
SSH_USER="pi"
INSTALL_PATH="/opt/claude-automation"
SETUP_SERVICE=false

# カラーコード
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

# ログ関数
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"
}

# 使用方法の表示
show_usage() {
    cat <<EOF
Usage: $0 [options]

Options:
    -t, --target <host>     Deploy target host (default: raspberry-pi.local)
    -u, --user <user>       SSH user (default: pi)
    -p, --path <path>       Installation path (default: /opt/claude-automation)
    -s, --service           Setup as systemd service
    -h, --help              Show this help message

Environment variables:
    GITHUB_TOKEN            Required for deployment
    SLACK_WEBHOOK_URL       Optional for Slack integration
    JIRA_BASE_URL          Optional for Jira integration
    JIRA_USERNAME          Optional for Jira integration
    JIRA_API_TOKEN         Optional for Jira integration

Example:
    $0 -t raspberry-pi.local -u pi -s

EOF
}

# 引数の解析
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--target)
                TARGET_HOST="$2"
                shift 2
                ;;
            -u|--user)
                SSH_USER="$2"
                shift 2
                ;;
            -p|--path)
                INSTALL_PATH="$2"
                shift 2
                ;;
            -s|--service)
                SETUP_SERVICE=true
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

# SSH接続の確認
check_ssh_connection() {
    log_info "Checking SSH connection to ${SSH_USER}@${TARGET_HOST}..."
    
    if ssh -o ConnectTimeout=5 "${SSH_USER}@${TARGET_HOST}" "echo 'SSH connection successful'" &>/dev/null; then
        log_success "SSH connection established"
        return 0
    else
        log_error "Failed to connect to ${SSH_USER}@${TARGET_HOST}"
        log_error "Please ensure:"
        log_error "  - The target host is reachable"
        log_error "  - SSH is enabled on the target"
        log_error "  - SSH key authentication is configured"
        return 1
    fi
}

# 環境変数の確認
check_environment() {
    log_info "Checking environment variables..."
    
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        log_error "GITHUB_TOKEN is not set"
        return 1
    fi
    
    log_success "Required environment variables are set"
    
    # オプション環境変数の確認
    [[ -z "${SLACK_WEBHOOK_URL:-}" ]] && log_warn "SLACK_WEBHOOK_URL not set (Slack integration disabled)"
    [[ -z "${JIRA_BASE_URL:-}" ]] && log_warn "JIRA_BASE_URL not set (Jira integration disabled)"
    
    return 0
}

# リモートシステムの準備
prepare_remote_system() {
    log_info "Preparing remote system..."
    
    # 必要なパッケージのインストール
    ssh "${SSH_USER}@${TARGET_HOST}" bash <<'EOF'
        # パッケージリストの更新
        sudo apt-get update
        
        # 必要なパッケージのインストール
        packages="git curl jq"
        
        for pkg in $packages; do
            if ! command -v $pkg &>/dev/null; then
                echo "Installing $pkg..."
                sudo apt-get install -y $pkg
            fi
        done
        
        # yqのインストール（snapが利用可能な場合）
        if command -v snap &>/dev/null; then
            if ! command -v yq &>/dev/null; then
                echo "Installing yq..."
                sudo snap install yq
            fi
        else
            # snapが無い場合は直接バイナリをダウンロード
            if ! command -v yq &>/dev/null; then
                echo "Installing yq from GitHub..."
                sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm
                sudo chmod +x /usr/local/bin/yq
            fi
        fi
EOF
    
    log_success "Remote system prepared"
}

# ファイルの転送
transfer_files() {
    log_info "Transferring files to ${TARGET_HOST}..."
    
    # 一時的なアーカイブを作成
    local temp_archive="/tmp/claude-automation-$(date +%s).tar.gz"
    
    # 不要なファイルを除外してアーカイブ作成
    tar -czf "$temp_archive" \
        -C "$CLAUDE_AUTO_HOME" \
        --exclude=".git" \
        --exclude="logs/*" \
        --exclude="workspace/*" \
        --exclude="*.pid" \
        --exclude="*.state" \
        --exclude="execution_history.json" \
        .
    
    # リモートにディレクトリを作成
    ssh "${SSH_USER}@${TARGET_HOST}" "sudo mkdir -p $INSTALL_PATH && sudo chown $SSH_USER:$SSH_USER $INSTALL_PATH"
    
    # ファイルを転送して展開
    scp "$temp_archive" "${SSH_USER}@${TARGET_HOST}:/tmp/"
    ssh "${SSH_USER}@${TARGET_HOST}" "tar -xzf /tmp/$(basename $temp_archive) -C $INSTALL_PATH"
    
    # クリーンアップ
    rm -f "$temp_archive"
    ssh "${SSH_USER}@${TARGET_HOST}" "rm -f /tmp/$(basename $temp_archive)"
    
    log_success "Files transferred successfully"
}

# 環境設定ファイルの作成
create_env_file() {
    log_info "Creating environment configuration..."
    
    local env_content="#!/usr/bin/env bash
# Claude Automation System Environment Configuration

export CLAUDE_AUTO_HOME=\"$INSTALL_PATH\"
export GITHUB_TOKEN=\"${GITHUB_TOKEN}\"
"
    
    # オプション環境変数の追加
    [[ -n "${SLACK_WEBHOOK_URL:-}" ]] && env_content+="export SLACK_WEBHOOK_URL=\"${SLACK_WEBHOOK_URL}\"\n"
    [[ -n "${JIRA_BASE_URL:-}" ]] && env_content+="export JIRA_BASE_URL=\"${JIRA_BASE_URL}\"\n"
    [[ -n "${JIRA_USERNAME:-}" ]] && env_content+="export JIRA_USERNAME=\"${JIRA_USERNAME}\"\n"
    [[ -n "${JIRA_API_TOKEN:-}" ]] && env_content+="export JIRA_API_TOKEN=\"${JIRA_API_TOKEN}\"\n"
    
    # リモートに環境設定ファイルを作成
    ssh "${SSH_USER}@${TARGET_HOST}" "cat > $INSTALL_PATH/.env" <<< "$env_content"
    ssh "${SSH_USER}@${TARGET_HOST}" "chmod 600 $INSTALL_PATH/.env"
    
    log_success "Environment configuration created"
}

# systemdサービスのセットアップ
setup_systemd_service() {
    if [[ "$SETUP_SERVICE" != "true" ]]; then
        return 0
    fi
    
    log_info "Setting up systemd service..."
    
    # サービスファイルの内容
    local service_content="[Unit]
Description=Claude Automation System
After=network.target

[Service]
Type=simple
User=$SSH_USER
WorkingDirectory=$INSTALL_PATH
EnvironmentFile=$INSTALL_PATH/.env
ExecStart=$INSTALL_PATH/scripts/start.sh
ExecStop=$INSTALL_PATH/scripts/stop.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"
    
    # サービスファイルを作成
    ssh "${SSH_USER}@${TARGET_HOST}" "sudo tee /etc/systemd/system/claude-automation.service" <<< "$service_content" > /dev/null
    
    # systemdをリロードしてサービスを有効化
    ssh "${SSH_USER}@${TARGET_HOST}" bash <<EOF
        sudo systemctl daemon-reload
        sudo systemctl enable claude-automation.service
        echo "Starting Claude Automation service..."
        sudo systemctl start claude-automation.service
        sleep 2
        sudo systemctl status claude-automation.service --no-pager
EOF
    
    log_success "systemd service configured and started"
}

# ログローテーションの設定
setup_log_rotation() {
    log_info "Setting up log rotation..."
    
    local logrotate_config="/etc/logrotate.d/claude-automation
$INSTALL_PATH/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 644 $SSH_USER $SSH_USER
    sharedscripts
    postrotate
        systemctl reload claude-automation.service > /dev/null 2>&1 || true
    endscript
}
"
    
    ssh "${SSH_USER}@${TARGET_HOST}" "sudo tee /etc/logrotate.d/claude-automation" <<< "$logrotate_config" > /dev/null
    
    log_success "Log rotation configured"
}

# デプロイ後の確認
verify_deployment() {
    log_info "Verifying deployment..."
    
    # ヘルスチェックの実行
    if ssh "${SSH_USER}@${TARGET_HOST}" "$INSTALL_PATH/scripts/health-check.sh" &>/dev/null; then
        log_success "Health check passed"
    else
        log_warn "Health check failed - system may need manual configuration"
    fi
    
    # サービス状態の確認
    if [[ "$SETUP_SERVICE" == "true" ]]; then
        if ssh "${SSH_USER}@${TARGET_HOST}" "systemctl is-active claude-automation.service" &>/dev/null; then
            log_success "Service is running"
        else
            log_error "Service is not running"
            return 1
        fi
    fi
    
    return 0
}

# デプロイメント情報の表示
show_deployment_info() {
    echo ""
    echo "============================================"
    echo -e "${COLOR_GREEN}Deployment completed successfully!${COLOR_RESET}"
    echo "============================================"
    echo ""
    echo "Deployment Information:"
    echo "  Host: ${SSH_USER}@${TARGET_HOST}"
    echo "  Path: $INSTALL_PATH"
    echo ""
    
    if [[ "$SETUP_SERVICE" == "true" ]]; then
        echo "Service Management:"
        echo "  Start:   sudo systemctl start claude-automation"
        echo "  Stop:    sudo systemctl stop claude-automation"
        echo "  Status:  sudo systemctl status claude-automation"
        echo "  Logs:    sudo journalctl -u claude-automation -f"
    else
        echo "Manual Operation:"
        echo "  Start:   $INSTALL_PATH/scripts/start.sh"
        echo "  Stop:    $INSTALL_PATH/scripts/stop.sh"
        echo "  Status:  $INSTALL_PATH/scripts/health-check.sh"
    fi
    
    echo ""
    echo "Configuration Files:"
    echo "  Repositories: $INSTALL_PATH/config/repositories.yaml"
    echo "  Integrations: $INSTALL_PATH/config/integrations.yaml"
    echo ""
    echo "============================================"
}

# メイン処理
main() {
    log_info "Claude Automation System Deployment Script"
    log_info "========================================="
    
    # 引数の解析
    parse_arguments "$@"
    
    # 環境変数の確認
    if ! check_environment; then
        exit 1
    fi
    
    # SSH接続の確認
    if ! check_ssh_connection; then
        exit 1
    fi
    
    # デプロイメントの実行
    log_info "Starting deployment to ${TARGET_HOST}..."
    
    prepare_remote_system
    transfer_files
    create_env_file
    setup_log_rotation
    setup_systemd_service
    
    # デプロイメントの確認
    if verify_deployment; then
        show_deployment_info
    else
        log_error "Deployment verification failed"
        exit 1
    fi
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi