#!/usr/bin/env bash

# deploy-docker.sh - Claude Automation SystemをDockerでデプロイ
# 
# 使用方法:
#   ./scripts/deploy-docker.sh [options]
#
# オプション:
#   --build-only     イメージのビルドのみ実行
#   --no-build       既存イメージを使用（ビルドしない）
#   --monitoring     監視サービス（Prometheus、Grafana）も起動
#   --clean          既存のコンテナとボリュームを削除してから起動

set -euo pipefail

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 設定
BUILD_ONLY=false
NO_BUILD=false
MONITORING=false
CLEAN=false

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
使用方法: $0 [options]

オプション:
  --build-only     イメージのビルドのみ実行
  --no-build       既存イメージを使用（ビルドしない）
  --monitoring     監視サービス（Prometheus、Grafana）も起動
  --clean          既存のコンテナとボリュームを削除してから起動
  --help           このヘルプを表示

例:
  $0                       # 通常のデプロイ
  $0 --build-only          # イメージビルドのみ
  $0 --monitoring          # 監視サービス付きでデプロイ
  $0 --clean --monitoring  # クリーンアップ後、監視付きでデプロイ

必要条件:
  - Docker Engine 20.10以上
  - Docker Compose V2
  - 少なくとも2GB の空きメモリ
EOF
}

# 引数の解析
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --build-only)
                BUILD_ONLY=true
                shift
                ;;
            --no-build)
                NO_BUILD=true
                shift
                ;;
            --monitoring)
                MONITORING=true
                shift
                ;;
            --clean)
                CLEAN=true
                shift
                ;;
            --help)
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

# Dockerの確認
check_docker() {
    log_info "Docker環境を確認中..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Dockerがインストールされていません"
        log_error "Docker Engineをインストールしてください: https://docs.docker.com/engine/install/"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker Daemonが起動していません"
        log_error "Docker Engineを起動してください"
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Composeがインストールされていません"
        log_error "Docker Compose V2をインストールしてください"
        exit 1
    fi
    
    # Dockerのバージョンを確認
    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}')
    log_info "Docker Engine: $docker_version"
    
    # 利用可能メモリを確認
    local available_memory
    if [[ "$(uname)" == "Darwin" ]]; then
        available_memory=$(docker system info --format '{{.MemTotal}}' 2>/dev/null || echo "不明")
    else
        available_memory=$(free -h | grep Mem | awk '{print $7}' || echo "不明")
    fi
    log_info "利用可能メモリ: $available_memory"
    
    log_success "Docker環境確認完了"
}

# プロジェクトの検証
validate_project() {
    log_info "プロジェクトファイルを検証中..."
    
    cd "$PROJECT_ROOT"
    
    # 必須ファイルの確認
    local required_files=(
        "Dockerfile"
        "docker-compose.yml"
        "scripts/start.sh"
        "config/repositories.yaml"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "必須ファイルが見つかりません: $file"
            exit 1
        fi
    done
    
    # .envファイルの確認
    if [[ ! -f ".env" ]]; then
        log_warn ".envファイルが見つかりません。テンプレートを作成します..."
        create_env_template
    fi
    
    log_success "プロジェクト検証完了"
}

# .envテンプレートの作成
create_env_template() {
    cat > .env << 'EOF'
# Claude Automation System - Docker環境設定

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

# システム設定
TZ=Asia/Tokyo
EOF
    
    log_info ".envテンプレートを作成しました"
    log_warn "デプロイ前に .env ファイルを編集して適切な値を設定してください"
}

# クリーンアップ
cleanup_containers() {
    if [[ "$CLEAN" == "true" ]]; then
        log_info "既存のコンテナとボリュームをクリーンアップ中..."
        
        # コンテナの停止と削除
        if docker-compose ps -q claude-automation &>/dev/null; then
            docker-compose down --volumes --remove-orphans
        fi
        
        # イメージの削除（オプション）
        if docker images -q claude-automation_claude-automation &>/dev/null; then
            read -p "Dockerイメージも削除しますか？ (y/N): " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                docker rmi claude-automation_claude-automation
            fi
        fi
        
        log_success "クリーンアップ完了"
    fi
}

# Dockerイメージのビルド
build_image() {
    if [[ "$NO_BUILD" != "true" ]]; then
        log_info "Dockerイメージをビルド中..."
        
        # ARM64対応のビルド
        if docker buildx version &>/dev/null; then
            log_info "Docker Buildxを使用してARM64イメージをビルド中..."
            docker buildx build --platform linux/arm64 -t claude-automation:latest .
        else
            log_info "標準のDockerビルドを使用中..."
            docker build -t claude-automation:latest .
        fi
        
        log_success "Dockerイメージのビルド完了"
        
        # イメージサイズを表示
        local image_size
        image_size=$(docker images claude-automation:latest --format "{{.Size}}")
        log_info "イメージサイズ: $image_size"
    else
        log_info "既存イメージを使用します（ビルドスキップ）"
    fi
}

# サービスの起動
start_services() {
    if [[ "$BUILD_ONLY" != "true" ]]; then
        log_info "Dockerサービスを起動中..."
        
        # Compose profiles の設定
        local compose_profiles=()
        if [[ "$MONITORING" == "true" ]]; then
            compose_profiles+=("--profile" "monitoring")
            log_info "監視サービス（Prometheus、Grafana）も起動します"
        fi
        
        # サービスの起動
        docker-compose "${compose_profiles[@]}" up -d
        
        log_success "Dockerサービス起動完了"
        
        # サービス状態の確認
        sleep 5
        show_service_status
    else
        log_info "ビルドのみが要求されました（サービス起動スキップ）"
    fi
}

# サービス状態の表示
show_service_status() {
    log_info "サービス状態:"
    docker-compose ps
    
    echo ""
    log_info "ヘルスチェック状態:"
    
    # claude-automationコンテナのヘルスチェック
    local health_status
    health_status=$(docker inspect --format='{{.State.Health.Status}}' claude-automation 2>/dev/null || echo "unknown")
    
    case "$health_status" in
        "healthy")
            log_success "Claude Automation: 正常"
            ;;
        "unhealthy")
            log_error "Claude Automation: 異常"
            ;;
        "starting")
            log_warn "Claude Automation: 起動中"
            ;;
        *)
            log_warn "Claude Automation: 状態不明"
            ;;
    esac
}

# デプロイ後の手順を表示
show_post_deployment_steps() {
    log_success "🎉 Dockerデプロイが完了しました！"
    echo ""
    log_info "📋 次の手順:"
    echo ""
    echo "1. 設定ファイルの確認・編集:"
    echo "   nano .env"
    echo "   nano config/repositories.yaml"
    echo ""
    echo "2. コンテナ内でClaude Code CLIの認証（必要に応じて）:"
    echo "   docker-compose exec claude-automation claude auth login"
    echo ""
    echo "3. GitHub CLIの認証："
    echo "   docker-compose exec claude-automation gh auth login"
    echo ""
    echo "4. ログの確認:"
    echo "   docker-compose logs -f claude-automation"
    echo ""
    echo "5. ヘルスチェック:"
    echo "   docker-compose exec claude-automation /opt/claude-automation/scripts/health-check.sh"
    echo ""
    
    if [[ "$MONITORING" == "true" ]]; then
        echo "📊 監視ダッシュボード:"
        echo "   Prometheus: http://localhost:9090"
        echo "   Grafana:    http://localhost:3000 (admin/admin)"
        echo ""
    fi
    
    log_info "🔧 管理コマンド:"
    echo "   docker-compose up -d          # サービス開始"
    echo "   docker-compose down           # サービス停止"
    echo "   docker-compose restart        # サービス再起動"
    echo "   docker-compose ps             # サービス状態確認"
    echo "   docker-compose logs -f        # ログ表示"
    echo "   docker-compose exec claude-automation bash  # コンテナ内シェル"
}

# メイン実行
main() {
    echo "🐳 Claude Automation System - Docker デプロイツール"
    echo "====================================================="
    echo ""
    
    # 引数の解析
    parse_arguments "$@"
    
    # Docker環境の確認
    check_docker
    echo ""
    
    # プロジェクトの検証
    validate_project
    echo ""
    
    # クリーンアップ
    cleanup_containers
    echo ""
    
    # イメージのビルド
    build_image
    echo ""
    
    # サービスの起動
    start_services
    echo ""
    
    # 完了メッセージ
    if [[ "$BUILD_ONLY" != "true" ]]; then
        show_post_deployment_steps
    fi
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi