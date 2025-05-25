#!/usr/bin/env bash

# config-loader.sh - YAML設定ファイルを読み込むユーティリティ
# 
# 使用方法:
#   source src/utils/config-loader.sh
#   load_config "config/repositories.yaml"
#   get_config_value "repositories.0.name"

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CONFIG_DIR="${CONFIG_DIR:-${CLAUDE_AUTO_HOME}/config}"

# 依存チェック
check_dependencies() {
    local deps=("yq" "jq")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: Missing dependencies: ${missing[*]}" >&2
        echo "Please install them using:" >&2
        echo "  brew install yq jq" >&2
        return 1
    fi
}

# 環境変数の展開
expand_env_vars() {
    local content=$1
    
    # ${VAR_NAME} 形式の環境変数を展開
    echo "$content" | envsubst
}

# YAMLファイルの読み込み
load_yaml() {
    local file=$1
    local expanded_content
    
    if [[ ! -f "$file" ]]; then
        echo "Error: Configuration file not found: $file" >&2
        return 1
    fi
    
    # 環境変数を展開してからyqで処理
    expanded_content=$(expand_env_vars "$(cat "$file")")
    echo "$expanded_content" | yq eval -o=json -
}

# 設定ファイルのキャッシュ
declare -A CONFIG_CACHE

# 設定ファイルの読み込み（キャッシュ付き）
load_config() {
    local config_file=$1
    local cache_key
    
    # 絶対パスに変換
    if [[ ! "$config_file" = /* ]]; then
        config_file="${CONFIG_DIR}/${config_file}"
    fi
    
    cache_key=$(basename "$config_file" .yaml)
    
    # キャッシュチェック
    if [[ -n "${CONFIG_CACHE[$cache_key]:-}" ]]; then
        return 0
    fi
    
    # 設定を読み込んでキャッシュ
    CONFIG_CACHE[$cache_key]=$(load_yaml "$config_file")
    
    if [[ -z "${CONFIG_CACHE[$cache_key]}" ]]; then
        echo "Error: Failed to load configuration from $config_file" >&2
        return 1
    fi
}

# 設定値の取得
get_config_value() {
    local path=$1
    local default_value=${2:-}
    local config_name=${3:-repositories}
    
    # 設定がロードされているか確認
    if [[ -z "${CONFIG_CACHE[$config_name]:-}" ]]; then
        load_config "${config_name}.yaml" || return 1
    fi
    
    # jqでパスを評価
    local value
    value=$(echo "${CONFIG_CACHE[$config_name]}" | jq -r ".$path // empty" 2>/dev/null)
    
    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "$default_value"
    else
        echo "$value"
    fi
}

# 配列の取得
get_config_array() {
    local path=$1
    local config_name=${2:-repositories}
    
    # 設定がロードされているか確認
    if [[ -z "${CONFIG_CACHE[$config_name]:-}" ]]; then
        load_config "${config_name}.yaml" || return 1
    fi
    
    # jqで配列を取得
    echo "${CONFIG_CACHE[$config_name]}" | jq -r ".$path[]?" 2>/dev/null
}

# 配列の長さを取得
get_config_array_length() {
    local path=$1
    local config_name=${2:-repositories}
    
    # 設定がロードされているか確認
    if [[ -z "${CONFIG_CACHE[$config_name]:-}" ]]; then
        load_config "${config_name}.yaml" || return 1
    fi
    
    # jqで配列の長さを取得
    echo "${CONFIG_CACHE[$config_name]}" | jq ".$path | length" 2>/dev/null || echo 0
}

# オブジェクトの取得
get_config_object() {
    local path=$1
    local config_name=${2:-repositories}
    
    # 設定がロードされているか確認
    if [[ -z "${CONFIG_CACHE[$config_name]:-}" ]]; then
        load_config "${config_name}.yaml" || return 1
    fi
    
    # jqでオブジェクトを取得
    echo "${CONFIG_CACHE[$config_name]}" | jq ".$path" 2>/dev/null
}

# 設定値の存在チェック
config_exists() {
    local path=$1
    local config_name=${2:-repositories}
    
    # 設定がロードされているか確認
    if [[ -z "${CONFIG_CACHE[$config_name]:-}" ]]; then
        load_config "${config_name}.yaml" || return 1
    fi
    
    # jqでパスの存在を確認
    echo "${CONFIG_CACHE[$config_name]}" | jq -e ".$path" &>/dev/null
}

# 有効なリポジトリの取得
get_enabled_repositories() {
    local repos_count
    repos_count=$(get_config_array_length "repositories" "repositories")
    
    for ((i=0; i<repos_count; i++)); do
        local enabled
        enabled=$(get_config_value "repositories[$i].enabled" "true" "repositories")
        
        if [[ "$enabled" == "true" ]]; then
            get_config_value "repositories[$i].name" "" "repositories"
        fi
    done
}

# リポジトリ設定の取得
get_repository_config() {
    local repo_name=$1
    local repos_count
    repos_count=$(get_config_array_length "repositories" "repositories")
    
    for ((i=0; i<repos_count; i++)); do
        local name
        name=$(get_config_value "repositories[$i].name" "" "repositories")
        
        if [[ "$name" == "$repo_name" ]]; then
            get_config_object "repositories[$i]" "repositories"
            return 0
        fi
    done
    
    return 1
}

# Organization設定の取得
get_organization_config() {
    local org_name=$1
    local orgs_count
    orgs_count=$(get_config_array_length "organizations" "repositories")
    
    for ((i=0; i<orgs_count; i++)); do
        local name
        name=$(get_config_value "organizations[$i].name" "" "repositories")
        
        if [[ "$name" == "$org_name" ]]; then
            get_config_object "organizations[$i]" "repositories"
            return 0
        fi
    done
    
    return 1
}

# Slack設定の取得
get_slack_config() {
    load_config "integrations.yaml" || return 1
    get_config_object "slack" "integrations"
}

# Jira設定の取得
get_jira_config() {
    load_config "integrations.yaml" || return 1
    get_config_object "jira" "integrations"
}

# GitHub設定の取得
get_github_config() {
    load_config "integrations.yaml" || return 1
    get_config_object "github" "integrations"
}

# プロンプトテンプレートの取得
get_prompt_template() {
    local template_path=$1
    load_config "claude-prompts.yaml" || return 1
    get_config_value "$template_path" "" "claude-prompts"
}

# 設定のリロード
reload_config() {
    # キャッシュをクリア
    CONFIG_CACHE=()
    
    # 主要な設定ファイルを再読み込み
    load_config "repositories.yaml"
    load_config "integrations.yaml"
    load_config "claude-prompts.yaml"
}

# 設定の検証
validate_config() {
    local errors=()
    
    # 必須ファイルの存在チェック
    local required_files=("repositories.yaml" "integrations.yaml" "claude-prompts.yaml")
    for file in "${required_files[@]}"; do
        if [[ ! -f "${CONFIG_DIR}/${file}" ]]; then
            errors+=("Missing required config file: $file")
        fi
    done
    
    # 必須環境変数のチェック
    local required_env_vars=("GITHUB_TOKEN")
    for var in "${required_env_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            errors+=("Missing required environment variable: $var")
        fi
    done
    
    # エラーがあれば表示
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "Configuration validation failed:" >&2
        for error in "${errors[@]}"; do
            echo "  - $error" >&2
        done
        return 1
    fi
    
    return 0
}

# 初期化
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 直接実行された場合のテスト
    check_dependencies || exit 1
    
    echo "Testing config loader..."
    
    # テスト用の設定読み込み
    if load_config "repositories.yaml"; then
        echo "Loaded repositories.yaml successfully"
        
        # 値の取得テスト
        echo "Default check interval: $(get_config_value "default_settings.check_interval")"
        echo "Enabled repositories:"
        get_enabled_repositories
    fi
fi