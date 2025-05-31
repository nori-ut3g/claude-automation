#!/usr/bin/env bash

# deploy-to-raspberry-pi.sh - Claude Automation SystemをRaspberry Piにデプロイ
# 
# 使用方法:
#   ./scripts/deploy-to-raspberry-pi.sh <raspberry_pi_ip> [username]
#
# 例:
#   ./scripts/deploy-to-raspberry-pi.sh 192.168.1.100 pi
#   ./scripts/deploy-to-raspberry-pi.sh claude-pi.local

set -euo pipefail

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 設定
RASPBERRY_PI_IP="${1:-}"
RASPBERRY_PI_USER="${2:-pi}"
DEPLOYMENT_DIR="/opt/claude-automation"
SERVICE_NAME="claude-automation"

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ログ関数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 使用方法の表示
show_usage() {
    cat << EOF
使用方法: $0 <raspberry_pi_ip> [username]

引数:
  raspberry_pi_ip  - Raspberry PiのIPアドレスまたはホスト名
  username         - SSH接続用のユーザー名 (デフォルト: pi)

例:
  $0 192.168.1.100
  $0 192.168.1.100 ubuntu
  $0 claude-pi.local pi

必要条件:
  - Raspberry PiでSSH接続が有効化されていること
  - 指定ユーザーでsudo権限があること
  - インターネット接続が利用可能であること
EOF
}

# 引数の検証
validate_arguments() {
    # ヘルプオプションの確認
    if [[ "$RASPBERRY_PI_IP" == "--help" ]] || [[ "$RASPBERRY_PI_IP" == "-h" ]]; then
        show_usage
        exit 0
    fi
    
    if [[ -z "$RASPBERRY_PI_IP" ]]; then
        log_error "Raspberry PiのIPアドレスまたはホスト名を指定してください"
        show_usage
        exit 1
    fi
    
    log_info "デプロイ設定:"
    log_info "  対象: $RASPBERRY_PI_USER@$RASPBERRY_PI_IP"
    log_info "  デプロイ先: $DEPLOYMENT_DIR"
    log_info "  サービス名: $SERVICE_NAME"
}

# SSH接続テスト
test_ssh_connection() {
    log_info "SSH接続をテスト中..."
    
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "echo 'SSH接続成功'" 2>/dev/null; then
        log_error "SSH接続に失敗しました"
        log_error "以下を確認してください:"
        log_error "  1. Raspberry PiのIPアドレス/ホスト名が正しいか"
        log_error "  2. SSHが有効化されているか"
        log_error "  3. SSH鍵またはパスワード認証が設定されているか"
        exit 1
    fi
    
    log_success "SSH接続確認完了"
}

# Raspberry Piの情報を取得
get_raspberry_pi_info() {
    log_info "Raspberry Pi情報を取得中..."
    
    local os_info
    os_info=$(ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "cat /etc/os-release | grep PRETTY_NAME" 2>/dev/null || echo "不明")
    
    local hardware_info
    hardware_info=$(ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "cat /proc/cpuinfo | grep 'Model' | head -1" 2>/dev/null || echo "不明")
    
    local memory_info
    memory_info=$(ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "free -h | grep Mem | awk '{print \$2}'" 2>/dev/null || echo "不明")
    
    log_info "対象システム情報:"
    log_info "  OS: ${os_info#*=}"
    log_info "  ハードウェア: ${hardware_info#*:}"
    log_info "  メモリ: $memory_info"
}

# 必要なディレクトリを作成
create_directories() {
    log_info "必要なディレクトリを作成中..."
    
    ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "
        sudo mkdir -p $DEPLOYMENT_DIR
        sudo mkdir -p $DEPLOYMENT_DIR/logs
        sudo mkdir -p $DEPLOYMENT_DIR/workspace
        sudo mkdir -p $DEPLOYMENT_DIR/config
        sudo mkdir -p /var/log/claude-automation
        sudo chown -R $RASPBERRY_PI_USER:$RASPBERRY_PI_USER $DEPLOYMENT_DIR
        sudo chown -R $RASPBERRY_PI_USER:$RASPBERRY_PI_USER /var/log/claude-automation
    "
    
    log_success "ディレクトリ作成完了"
}

# プロジェクトファイルを転送
transfer_files() {
    log_info "プロジェクトファイルを転送中..."
    
    # 除外するファイル・ディレクトリのリスト
    local exclude_file=$(mktemp)
    cat > "$exclude_file" << 'EOF'
.git/
workspace/
logs/*.log
*.tmp
.DS_Store
*.swp
*.swo
*~
node_modules/
.env.local
.env.production
EOF
    
    # rsyncでファイルを転送
    rsync -avz --progress \
        --exclude-from="$exclude_file" \
        --delete \
        "$PROJECT_ROOT/" \
        "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP:$DEPLOYMENT_DIR/"
    
    rm -f "$exclude_file"
    log_success "ファイル転送完了"
}

# Raspberry Pi用の依存関係をインストール
install_dependencies() {
    log_info "Raspberry Pi用の依存関係をインストール中..."
    
    ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "
        cd $DEPLOYMENT_DIR
        
        # システムパッケージの更新
        sudo apt-get update
        
        # 必要なパッケージのインストール
        sudo apt-get install -y \
            git \
            curl \
            jq \
            build-essential \
            python3 \
            python3-pip \
            nodejs \
            npm
        
        # yqのインストール（ARM64対応）
        if ! command -v yq &> /dev/null; then
            sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64
            sudo chmod +x /usr/local/bin/yq
        fi
        
        # GitHub CLI (gh)のインストール
        if ! command -v gh &> /dev/null; then
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
            sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
            echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
            sudo apt update
            sudo apt install -y gh
        fi
        
        # スクリプトを実行可能にする
        chmod +x scripts/*.sh
        chmod +x src/core/*.sh
        chmod +x src/integrations/*.sh
        chmod +x src/utils/*.sh
    "
    
    log_success "依存関係のインストール完了"
}

# Claude Code CLIのインストール確認
check_claude_cli() {
    log_info "Claude Code CLIの確認中..."
    
    if ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "command -v claude &> /dev/null"; then
        log_success "Claude Code CLIが既にインストールされています"
    else
        log_warn "Claude Code CLIがインストールされていません"
        log_info "Claude Code CLIの手動インストールが必要です:"
        log_info "  1. Raspberry Piにログイン: ssh $RASPBERRY_PI_USER@$RASPBERRY_PI_IP"
        log_info "  2. Claude Code CLIをインストール: https://claude.ai/code"
        log_info "  3. 認証: claude auth login"
    fi
}

# systemdサービスファイルを作成
create_systemd_service() {
    log_info "systemdサービスを作成中..."
    
    ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "
        # サービスファイルを作成
        sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null << 'EOF'
[Unit]
Description=Claude Automation System
After=network.target
Wants=network-online.target

[Service]
Type=forking
User=$RASPBERRY_PI_USER
Group=$RASPBERRY_PI_USER
WorkingDirectory=$DEPLOYMENT_DIR
ExecStart=$DEPLOYMENT_DIR/scripts/start.sh --daemon
ExecStop=$DEPLOYMENT_DIR/scripts/stop.sh
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-automation

# 環境変数ファイル（必要に応じて作成）
EnvironmentFile=-$DEPLOYMENT_DIR/.env

# セキュリティ設定
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$DEPLOYMENT_DIR /var/log/claude-automation

[Install]
WantedBy=multi-user.target
EOF
        
        # systemdを再読み込み
        sudo systemctl daemon-reload
        
        # サービスを有効化
        sudo systemctl enable $SERVICE_NAME
    "
    
    log_success "systemdサービス作成完了"
}

# 設定ファイルのテンプレートを作成
create_config_templates() {
    log_info "設定ファイルテンプレートを作成中..."
    
    ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "
        cd $DEPLOYMENT_DIR
        
        # 環境変数テンプレートを作成
        if [[ ! -f .env ]]; then
            cat > .env << 'EOF'
# Claude Automation System - Raspberry Pi設定

# GitHub設定
GITHUB_TOKEN=your_github_token_here
GITHUB_USERNAME=your_github_username

# Claude設定（Claude Code CLIで自動設定される場合は不要）
# ANTHROPIC_API_KEY=your_anthropic_api_key

# Slack設定（オプション）
# SLACK_WEBHOOK_URL=your_slack_webhook_url

# Jira設定（オプション）
# JIRA_BASE_URL=your_jira_instance_url
# JIRA_USERNAME=your_jira_username
# JIRA_API_TOKEN=your_jira_api_token

# ログ設定
LOG_LEVEL=info
LOG_FILE=/var/log/claude-automation/claude-automation.log

# システム設定
CLAUDE_AUTO_HOME=$DEPLOYMENT_DIR
TZ=Asia/Tokyo
EOF
        fi
        
        # 設定ファイルの権限を制限
        chmod 600 .env
    "
    
    log_success "設定ファイルテンプレート作成完了"
}

# ログローテーション設定
setup_log_rotation() {
    log_info "ログローテーション設定を作成中..."
    
    ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "
        sudo tee /etc/logrotate.d/claude-automation > /dev/null << 'EOF'
/var/log/claude-automation/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 $RASPBERRY_PI_USER $RASPBERRY_PI_USER
    postrotate
        systemctl reload $SERVICE_NAME > /dev/null 2>&1 || true
    endscript
}
EOF
    "
    
    log_success "ログローテーション設定完了"
}

# ファイアウォール設定（オプション）
configure_firewall() {
    log_info "ファイアウォール設定を確認中..."
    
    if ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "command -v ufw &> /dev/null"; then
        ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "
            # SSHアクセスを確実に許可
            sudo ufw allow ssh
            
            # HTTPSアウトバウンド（GitHub API用）を許可
            sudo ufw allow out 443
            
            # DNS解決を許可
            sudo ufw allow out 53
        "
        log_info "ファイアウォール設定確認完了"
    else
        log_info "ufwが見つかりません。ファイアウォール設定をスキップします"
    fi
}

# デプロイ後の設定確認
verify_deployment() {
    log_info "デプロイメント確認中..."
    
    # ファイルの存在確認
    ssh "$RASPBERRY_PI_USER@$RASPBERRY_PI_IP" "
        if [[ -f $DEPLOYMENT_DIR/scripts/start.sh ]]; then
            echo '✅ スタートスクリプト: OK'
        else
            echo '❌ スタートスクリプト: NG'
            exit 1
        fi
        
        if [[ -f $DEPLOYMENT_DIR/config/repositories.yaml ]]; then
            echo '✅ 設定ファイル: OK'
        else
            echo '❌ 設定ファイル: NG'
            exit 1
        fi
        
        if systemctl is-enabled $SERVICE_NAME &>/dev/null; then
            echo '✅ systemdサービス: OK'
        else
            echo '❌ systemdサービス: NG'
            exit 1
        fi
    "
    
    log_success "デプロイメント確認完了"
}

# デプロイ後の手順を表示
show_post_deployment_steps() {
    log_success "🎉 Raspberry Piへのデプロイが完了しました！"
    echo ""
    log_info "📋 次の手順を実行してください:"
    echo ""
    echo "1. Raspberry Piにログイン:"
    echo "   ssh $RASPBERRY_PI_USER@$RASPBERRY_PI_IP"
    echo ""
    echo "2. 設定ファイルを編集:"
    echo "   cd $DEPLOYMENT_DIR"
    echo "   nano .env"
    echo "   nano config/repositories.yaml"
    echo ""
    echo "3. Claude Code CLIの認証（まだの場合）:"
    echo "   claude auth login"
    echo ""
    echo "4. GitHub CLIの認証："
    echo "   gh auth login"
    echo ""
    echo "5. サービスを開始:"
    echo "   sudo systemctl start $SERVICE_NAME"
    echo "   sudo systemctl status $SERVICE_NAME"
    echo ""
    echo "6. ログを確認:"
    echo "   tail -f /var/log/claude-automation/claude-automation.log"
    echo ""
    log_info "🔧 管理コマンド:"
    echo "   sudo systemctl start $SERVICE_NAME     # サービス開始"
    echo "   sudo systemctl stop $SERVICE_NAME      # サービス停止"
    echo "   sudo systemctl restart $SERVICE_NAME   # サービス再起動"
    echo "   sudo systemctl status $SERVICE_NAME    # サービス状態確認"
    echo "   sudo journalctl -u $SERVICE_NAME -f    # サービスログ表示"
    echo ""
    log_info "📊 ヘルスチェック:"
    echo "   $DEPLOYMENT_DIR/scripts/health-check.sh"
}

# メイン実行
main() {
    echo "🔧 Claude Automation System - Raspberry Pi デプロイツール"
    echo "=================================================================="
    echo ""
    
    # 引数の検証
    validate_arguments
    echo ""
    
    # SSH接続テスト
    test_ssh_connection
    echo ""
    
    # Raspberry Pi情報取得
    get_raspberry_pi_info
    echo ""
    
    # 確認プロンプト
    read -p "デプロイを続行しますか？ (y/N): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "デプロイをキャンセルしました"
        exit 0
    fi
    echo ""
    
    # デプロイ実行
    create_directories
    echo ""
    
    transfer_files
    echo ""
    
    install_dependencies
    echo ""
    
    check_claude_cli
    echo ""
    
    create_systemd_service
    echo ""
    
    create_config_templates
    echo ""
    
    setup_log_rotation
    echo ""
    
    configure_firewall
    echo ""
    
    verify_deployment
    echo ""
    
    # 完了メッセージ
    show_post_deployment_steps
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi