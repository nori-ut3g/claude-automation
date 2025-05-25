#!/usr/bin/env bash

# install.sh - Claude Automation Systemの依存関係をインストール
# 
# 使用方法:
#   ./scripts/install.sh

set -euo pipefail

# カラーコード
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

# 基本パスの設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_AUTO_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

# OS判定
OS_TYPE=""
if [[ "$(uname)" == "Darwin" ]]; then
    OS_TYPE="macos"
elif [[ "$(uname)" == "Linux" ]]; then
    OS_TYPE="linux"
else
    echo -e "${COLOR_RED}Error: Unsupported operating system$(uname)${COLOR_RESET}"
    exit 1
fi

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

# ヘッダー表示
show_header() {
    cat <<'EOF'
   _____ _                 _        _         _                        _   _             
  / ____| |               | |      | |       | |                      | | (_)            
 | |    | | __ _ _   _  __| | ___  | |  _ __ | |_ ___  _ __ ___   __ _| |_ _  ___  _ __  
 | |    | |/ _` | | | |/ _` |/ _ \ | | | '_ \| __/ _ \| '_ ` _ \ / _` | __| |/ _ \| '_ \ 
 | |____| | (_| | |_| | (_| |  __/ | | | | | | || (_) | | | | | | (_| | |_| | (_) | | | |
  \_____|_|\__,_|\__,_|\__,_|\___| |_| |_| |_|\__\___/|_| |_| |_|\__,_|\__|_|\___/|_| |_|
                                                                                          
                                    Installation Script v2.0
EOF
    echo ""
}

# コマンドの存在チェック
check_command() {
    local cmd=$1
    if command -v "$cmd" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Homebrewのインストール（macOS）
install_homebrew() {
    if [[ "$OS_TYPE" != "macos" ]]; then
        return 0
    fi
    
    if ! check_command "brew"; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Homebrewのパスを設定
        if [[ -f "/opt/homebrew/bin/brew" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        
        log_success "Homebrew installed"
    else
        log_info "Homebrew is already installed"
    fi
}

# 依存関係のインストール
install_dependencies() {
    log_info "Installing dependencies..."
    
    local packages=()
    
    # 必須パッケージのチェック
    if ! check_command "git"; then
        packages+=("git")
    fi
    
    if ! check_command "curl"; then
        packages+=("curl")
    fi
    
    if ! check_command "jq"; then
        packages+=("jq")
    fi
    
    if ! check_command "yq"; then
        packages+=("yq")
    fi
    
    # オプションパッケージ
    if ! check_command "gh"; then
        log_warn "GitHub CLI (gh) is not installed. Installing for better GitHub integration..."
        packages+=("gh")
    fi
    
    # パッケージのインストール
    if [[ ${#packages[@]} -gt 0 ]]; then
        log_info "Installing packages: ${packages[*]}"
        
        if [[ "$OS_TYPE" == "macos" ]]; then
            brew install "${packages[@]}"
        elif [[ "$OS_TYPE" == "linux" ]]; then
            # Linux用のインストールコマンド
            if check_command "apt-get"; then
                sudo apt-get update
                sudo apt-get install -y "${packages[@]}"
            elif check_command "yum"; then
                sudo yum install -y "${packages[@]}"
            else
                log_error "Unsupported package manager. Please install manually: ${packages[*]}"
                exit 1
            fi
        fi
        
        log_success "Dependencies installed"
    else
        log_info "All dependencies are already installed"
    fi
}

# 設定ファイルの確認
check_config_files() {
    log_info "Checking configuration files..."
    
    local config_dir="${CLAUDE_AUTO_HOME}/config"
    local missing_files=()
    
    # 必須設定ファイル
    local required_files=(
        "repositories.yaml"
        "integrations.yaml"
        "claude-prompts.yaml"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "${config_dir}/${file}" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_error "Missing configuration files: ${missing_files[*]}"
        log_info "Please check the config/ directory"
        return 1
    else
        log_success "All configuration files found"
    fi
    
    return 0
}

# 実行権限の設定
set_permissions() {
    log_info "Setting execution permissions..."
    
    # スクリプトに実行権限を付与
    chmod +x "${CLAUDE_AUTO_HOME}/scripts/"*.sh
    chmod +x "${CLAUDE_AUTO_HOME}/src/core/"*.sh
    chmod +x "${CLAUDE_AUTO_HOME}/src/utils/"*.sh
    find "${CLAUDE_AUTO_HOME}/src/integrations/" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    
    log_success "Permissions set"
}

# 環境変数のチェック
check_environment() {
    log_info "Checking environment variables..."
    
    local has_errors=false
    
    # 必須環境変数
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        log_error "GITHUB_TOKEN is not set"
        log_info "Please set it with: export GITHUB_TOKEN='your-github-token'"
        has_errors=true
    else
        log_success "GITHUB_TOKEN is set"
    fi
    
    # オプション環境変数
    if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
        log_warn "SLACK_WEBHOOK_URL is not set (Slack integration will be disabled)"
    else
        log_success "SLACK_WEBHOOK_URL is set"
    fi
    
    if [[ -z "${JIRA_BASE_URL:-}" ]]; then
        log_warn "JIRA_BASE_URL is not set (Jira integration will be disabled)"
    else
        log_success "JIRA_BASE_URL is set"
        
        if [[ -z "${JIRA_USERNAME:-}" ]]; then
            log_error "JIRA_USERNAME is not set (required for Jira integration)"
            has_errors=true
        fi
        
        if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
            log_error "JIRA_API_TOKEN is not set (required for Jira integration)"
            has_errors=true
        fi
    fi
    
    if [[ "$has_errors" == "true" ]]; then
        return 1
    fi
    
    return 0
}

# ディレクトリの作成
create_directories() {
    log_info "Creating required directories..."
    
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
    
    # 初期ファイルの作成
    if [[ ! -f "${CLAUDE_AUTO_HOME}/execution_history.json" ]]; then
        echo "[]" > "${CLAUDE_AUTO_HOME}/execution_history.json"
    fi
    
    log_success "Directories created"
}

# Git設定
setup_git_config() {
    log_info "Setting up Git configuration..."
    
    # グローバルGit設定（未設定の場合のみ）
    if [[ -z "$(git config --global user.name)" ]]; then
        git config --global user.name "Claude Automation System"
        log_info "Set Git user.name to 'Claude Automation System'"
    fi
    
    if [[ -z "$(git config --global user.email)" ]]; then
        git config --global user.email "claude-automation@system.local"
        log_info "Set Git user.email to 'claude-automation@system.local'"
    fi
    
    log_success "Git configuration complete"
}

# systemdサービスファイルの生成（Linux用）
create_systemd_service() {
    if [[ "$OS_TYPE" != "linux" ]]; then
        return 0
    fi
    
    log_info "Creating systemd service file..."
    
    local service_file="/etc/systemd/system/claude-automation.service"
    
    cat <<EOF | sudo tee "$service_file" > /dev/null
[Unit]
Description=Claude Automation System
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$CLAUDE_AUTO_HOME
Environment="CLAUDE_AUTO_HOME=$CLAUDE_AUTO_HOME"
Environment="GITHUB_TOKEN=$GITHUB_TOKEN"
ExecStart=$CLAUDE_AUTO_HOME/scripts/start.sh
ExecStop=$CLAUDE_AUTO_HOME/scripts/stop.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    log_success "systemd service created"
    log_info "To enable auto-start: sudo systemctl enable claude-automation"
}

# launchdサービスファイルの生成（macOS用）
create_launchd_service() {
    if [[ "$OS_TYPE" != "macos" ]]; then
        return 0
    fi
    
    log_info "Creating launchd service file..."
    
    local plist_file="$HOME/Library/LaunchAgents/com.claude.automation.plist"
    
    cat <<EOF > "$plist_file"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.automation</string>
    <key>ProgramArguments</key>
    <array>
        <string>$CLAUDE_AUTO_HOME/scripts/start.sh</string>
        <string>--daemon</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$CLAUDE_AUTO_HOME</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CLAUDE_AUTO_HOME</key>
        <string>$CLAUDE_AUTO_HOME</string>
        <key>GITHUB_TOKEN</key>
        <string>$GITHUB_TOKEN</string>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$CLAUDE_AUTO_HOME/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$CLAUDE_AUTO_HOME/logs/launchd.err.log</string>
</dict>
</plist>
EOF
    
    log_success "launchd service created"
    log_info "To enable auto-start: launchctl load -w $plist_file"
}

# インストール完了メッセージ
show_completion_message() {
    echo ""
    echo "============================================"
    echo -e "${COLOR_GREEN}Installation completed successfully!${COLOR_RESET}"
    echo "============================================"
    echo ""
    echo "Next steps:"
    echo ""
    
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        echo "1. Set your GitHub token:"
        echo "   export GITHUB_TOKEN='your-github-token'"
        echo ""
    fi
    
    echo "2. Configure your repositories:"
    echo "   Edit config/repositories.yaml"
    echo ""
    
    echo "3. Start the system:"
    echo "   ./scripts/start.sh"
    echo ""
    
    echo "4. Check system health:"
    echo "   ./scripts/health-check.sh"
    echo ""
    
    echo "For more information, see README.md"
    echo "============================================"
}

# メイン処理
main() {
    show_header
    
    # macOSの場合はHomebrewをインストール
    if [[ "$OS_TYPE" == "macos" ]]; then
        install_homebrew
    fi
    
    # 依存関係のインストール
    install_dependencies
    
    # 設定ファイルの確認
    if ! check_config_files; then
        log_error "Installation incomplete due to missing configuration files"
        exit 1
    fi
    
    # 実行権限の設定
    set_permissions
    
    # ディレクトリの作成
    create_directories
    
    # Git設定
    setup_git_config
    
    # 環境変数のチェック（警告のみ）
    check_environment || true
    
    # サービスファイルの作成
    if [[ "$OS_TYPE" == "linux" ]]; then
        create_systemd_service
    elif [[ "$OS_TYPE" == "macos" ]]; then
        create_launchd_service
    fi
    
    # 完了メッセージ
    show_completion_message
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi