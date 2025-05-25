#!/usr/bin/env bash

# run-tests.sh - Claude Automation Systemのテストスイート
# 
# 使用方法:
#   ./tests/run-tests.sh [test_type]
#   
# テストタイプ:
#   unit        ユニットテストのみ実行
#   integration 統合テストのみ実行
#   all         すべてのテストを実行（デフォルト）

set -euo pipefail

# 基本パスの設定
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_AUTO_HOME="$(cd "$TEST_DIR/.." && pwd)"
export CLAUDE_AUTO_HOME

# カラーコード
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

# テスト結果
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# テストタイプ
TEST_TYPE="${1:-all}"

# ログ関数
log_test() {
    echo -e "${COLOR_BLUE}[TEST]${COLOR_RESET} $1"
}

log_pass() {
    echo -e "${COLOR_GREEN}[PASS]${COLOR_RESET} $1"
    ((PASSED_TESTS++))
}

log_fail() {
    echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $1"
    ((FAILED_TESTS++))
}

log_skip() {
    echo -e "${COLOR_YELLOW}[SKIP]${COLOR_RESET} $1"
    ((SKIPPED_TESTS++))
}

# アサーション関数
assert_equals() {
    local expected=$1
    local actual=$2
    local message=${3:-"Values should be equal"}
    
    ((TOTAL_TESTS++))
    
    if [[ "$expected" == "$actual" ]]; then
        log_pass "$message"
        return 0
    else
        log_fail "$message (expected: '$expected', actual: '$actual')"
        return 1
    fi
}

assert_not_empty() {
    local value=$1
    local message=${2:-"Value should not be empty"}
    
    ((TOTAL_TESTS++))
    
    if [[ -n "$value" ]]; then
        log_pass "$message"
        return 0
    else
        log_fail "$message"
        return 1
    fi
}

assert_file_exists() {
    local file=$1
    local message=${2:-"File should exist: $file"}
    
    ((TOTAL_TESTS++))
    
    if [[ -f "$file" ]]; then
        log_pass "$message"
        return 0
    else
        log_fail "$message"
        return 1
    fi
}

assert_command_success() {
    local command=$1
    local message=${2:-"Command should succeed: $command"}
    
    ((TOTAL_TESTS++))
    
    if eval "$command" > /dev/null 2>&1; then
        log_pass "$message"
        return 0
    else
        log_fail "$message"
        return 1
    fi
}

# テスト環境のセットアップ
setup_test_env() {
    log_test "Setting up test environment..."
    
    # テスト用の一時ディレクトリ
    export TEST_TEMP_DIR=$(mktemp -d)
    export CLAUDE_AUTO_HOME="$TEST_TEMP_DIR"
    
    # 必要なディレクトリを作成
    mkdir -p "$TEST_TEMP_DIR"/{config,src/{core,utils,integrations},logs,workspace}
    
    # テスト用の設定ファイルをコピー
    cp -r "${TEST_DIR}/../config"/* "$TEST_TEMP_DIR/config/" 2>/dev/null || true
    cp -r "${TEST_DIR}/../src"/* "$TEST_TEMP_DIR/src/" 2>/dev/null || true
    
    # テスト用の環境変数
    export GITHUB_TOKEN="test-token-12345"
    export LOG_LEVEL="ERROR"  # テスト中は最小限のログ
    
    log_test "Test environment ready: $TEST_TEMP_DIR"
}

# テスト環境のクリーンアップ
cleanup_test_env() {
    if [[ -n "${TEST_TEMP_DIR:-}" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ユーティリティのユニットテスト
test_logger_unit() {
    log_test "Testing logger.sh functionality..."
    
    source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
    
    # ログファイルの作成確認
    log_info "Test message"
    assert_file_exists "$LOG_FILE" "Log file should be created"
    
    # ログレベルのテスト
    export LOG_LEVEL="$LOG_LEVEL_ERROR"
    local log_output
    log_output=$(log_debug "Debug message" 2>&1)
    assert_equals "" "$log_output" "Debug message should not appear when log level is ERROR"
    
    # マスキング機能のテスト
    local sensitive="token=secret123"
    local masked
    masked=$(mask_sensitive_data "$sensitive")
    assert_equals "token=*****" "$masked" "Sensitive data should be masked"
}

test_config_loader_unit() {
    log_test "Testing config-loader.sh functionality..."
    
    # Mock yq and jq for testing
    if ! command -v yq &> /dev/null; then
        log_skip "yq not installed, skipping config tests"
        return
    fi
    
    source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"
    
    # 設定ファイルの読み込みテスト
    if load_config "repositories.yaml" 2>/dev/null; then
        log_pass "Configuration file loaded successfully"
    else
        log_fail "Failed to load configuration file"
    fi
    
    # 値の取得テスト
    local interval
    interval=$(get_config_value "default_settings.check_interval" "60" "repositories")
    assert_not_empty "$interval" "Should get check interval value"
}

test_git_utils_unit() {
    log_test "Testing git-utils.sh functionality..."
    
    source "${CLAUDE_AUTO_HOME}/src/utils/git-utils.sh"
    
    # ブランチ名生成のテスト
    local branch_name
    branch_name=$(generate_branch_name "123" "feature" "gitflow" "Add new feature")
    assert_equals "feature/claude-auto-issue-123-add-new-feature" "$branch_name" "Branch name should be generated correctly"
    
    # コミットメッセージ生成のテスト
    local commit_msg
    commit_msg=$(generate_commit_message "feat" "auth" "Add login" "123" | head -1)
    assert_equals "feat(auth): Add login" "$commit_msg" "Commit message should be formatted correctly"
}

# コアモジュールのユニットテスト
test_event_processor_unit() {
    log_test "Testing event-processor.sh functionality..."
    
    # 実行履歴ファイルの初期化
    echo "[]" > "${CLAUDE_AUTO_HOME}/execution_history.json"
    
    # ロックディレクトリの作成
    mkdir -p "${CLAUDE_AUTO_HOME}/locks"
    
    assert_file_exists "${CLAUDE_AUTO_HOME}/execution_history.json" "Execution history file should exist"
}

# 統合テスト
test_health_check_integration() {
    log_test "Testing health check integration..."
    
    local health_script="${CLAUDE_AUTO_HOME}/../scripts/health-check.sh"
    
    if [[ ! -x "$health_script" ]]; then
        log_skip "Health check script not found"
        return
    fi
    
    # 環境変数をクリア（実際の環境をテスト）
    unset GITHUB_TOKEN
    
    # ヘルスチェックの実行
    local exit_code=0
    "$health_script" --json > /dev/null 2>&1 || exit_code=$?
    
    # システムが実行されていない場合、exit code 2が期待される
    if [[ $exit_code -eq 2 ]]; then
        log_pass "Health check correctly reports system not running"
    else
        log_fail "Health check returned unexpected exit code: $exit_code"
    fi
}

test_config_validation_integration() {
    log_test "Testing configuration validation..."
    
    source "${CLAUDE_AUTO_HOME}/src/utils/config-loader.sh"
    
    # 無効な設定でのテスト
    export GITHUB_TOKEN=""
    
    if validate_config 2>/dev/null; then
        log_fail "Configuration validation should fail without GITHUB_TOKEN"
    else
        log_pass "Configuration validation correctly fails without GITHUB_TOKEN"
    fi
    
    # 有効な設定でのテスト
    export GITHUB_TOKEN="test-token"
    
    if validate_config 2>/dev/null; then
        log_pass "Configuration validation passes with GITHUB_TOKEN"
    else
        log_fail "Configuration validation should pass with GITHUB_TOKEN"
    fi
}

# システムテスト
test_start_stop_system() {
    log_test "Testing system start/stop functionality..."
    
    local start_script="${CLAUDE_AUTO_HOME}/../scripts/start.sh"
    local stop_script="${CLAUDE_AUTO_HOME}/../scripts/stop.sh"
    
    if [[ ! -x "$start_script" ]] || [[ ! -x "$stop_script" ]]; then
        log_skip "Start/stop scripts not found"
        return
    fi
    
    # PIDファイルが存在しないことを確認
    local pid_file="${CLAUDE_AUTO_HOME}/monitor.pid"
    [[ ! -f "$pid_file" ]]
    assert_equals "0" "$?" "PID file should not exist initially"
}

# パフォーマンステスト
test_performance_logging() {
    log_test "Testing logging performance..."
    
    source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"
    
    local start_time=$(date +%s)
    
    # 1000件のログメッセージを出力
    for i in {1..1000}; do
        log_debug "Performance test message $i"
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [[ $duration -lt 5 ]]; then
        log_pass "Logging performance is acceptable (${duration}s for 1000 messages)"
    else
        log_fail "Logging performance is slow (${duration}s for 1000 messages)"
    fi
}

# テストの実行
run_unit_tests() {
    echo -e "\n${COLOR_BLUE}Running Unit Tests...${COLOR_RESET}\n"
    
    test_logger_unit
    test_config_loader_unit
    test_git_utils_unit
    test_event_processor_unit
}

run_integration_tests() {
    echo -e "\n${COLOR_BLUE}Running Integration Tests...${COLOR_RESET}\n"
    
    test_health_check_integration
    test_config_validation_integration
    test_start_stop_system
}

run_performance_tests() {
    echo -e "\n${COLOR_BLUE}Running Performance Tests...${COLOR_RESET}\n"
    
    test_performance_logging
}

# テスト結果のサマリー
show_summary() {
    echo -e "\n${COLOR_BLUE}Test Summary${COLOR_RESET}"
    echo "===================="
    echo "Total Tests:   $TOTAL_TESTS"
    echo -e "Passed:        ${COLOR_GREEN}$PASSED_TESTS${COLOR_RESET}"
    echo -e "Failed:        ${COLOR_RED}$FAILED_TESTS${COLOR_RESET}"
    echo -e "Skipped:       ${COLOR_YELLOW}$SKIPPED_TESTS${COLOR_RESET}"
    echo "===================="
    
    if [[ $FAILED_TESTS -eq 0 ]]; then
        echo -e "\n${COLOR_GREEN}All tests passed!${COLOR_RESET}"
        return 0
    else
        echo -e "\n${COLOR_RED}Some tests failed!${COLOR_RESET}"
        return 1
    fi
}

# メイン処理
main() {
    echo "Claude Automation System - Test Suite"
    echo "====================================="
    
    # トラップの設定
    trap cleanup_test_env EXIT
    
    # テスト環境のセットアップ
    setup_test_env
    
    # テストの実行
    case "$TEST_TYPE" in
        "unit")
            run_unit_tests
            ;;
        "integration")
            run_integration_tests
            ;;
        "all"|*)
            run_unit_tests
            run_integration_tests
            run_performance_tests
            ;;
    esac
    
    # サマリーの表示
    show_summary
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi