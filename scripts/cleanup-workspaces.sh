#!/usr/bin/env bash

# cleanup-workspaces.sh - アクティブでないワークスペースをクリーンアップ
# 
# 使用方法:
#   ./scripts/cleanup-workspaces.sh [--force] [--dry-run] [--older-than HOURS]

set -euo pipefail

# 基本パスの設定
CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ユーティリティのインポート
source "${CLAUDE_AUTO_HOME}/src/utils/logger.sh"

# デフォルト設定
DRY_RUN=false
FORCE=false
OLDER_THAN_HOURS=24  # 24時間より古いワークスペースをクリーンアップ

# 引数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --older-than)
            OLDER_THAN_HOURS="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--force] [--dry-run] [--older-than HOURS]"
            echo ""
            echo "Options:"
            echo "  --dry-run       Show what would be cleaned up without actually doing it"
            echo "  --force         Force cleanup without confirmation"
            echo "  --older-than N  Clean up workspaces older than N hours (default: 24)"
            echo "  --help, -h      Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ワークスペースのクリーンアップ
cleanup_workspaces() {
    local workspace_base="${CLAUDE_AUTO_HOME}/workspace"
    local active_workspaces="${CLAUDE_AUTO_HOME}/logs/active_workspaces.json"
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - OLDER_THAN_HOURS * 3600))
    
    log_info "Starting workspace cleanup..."
    log_info "Cutoff time: $(date -d "@$cutoff_time" 2>/dev/null || date -r "$cutoff_time")"
    
    if [[ ! -d "$workspace_base" ]]; then
        log_info "Workspace directory does not exist: $workspace_base"
        return 0
    fi
    
    # アクティブワークスペース情報を読み込み
    local active_paths=()
    if [[ -f "$active_workspaces" ]]; then
        while IFS= read -r workspace_path; do
            if [[ -n "$workspace_path" ]]; then
                active_paths+=("$workspace_path")
            fi
        done < <(jq -r '.[].workspace_path // empty' "$active_workspaces" 2>/dev/null || true)
    fi
    
    log_info "Found ${#active_paths[@]} active workspaces"
    
    # ワークスペースディレクトリをスキャン
    local cleaned_count=0
    local total_size=0
    
    while IFS= read -r -d '' workspace_dir; do
        local dir_name=$(basename "$workspace_dir")
        local dir_time
        
        # ディレクトリの作成時間を取得
        if [[ "$dir_name" =~ ^[0-9]{8}_[0-9]{6}_ ]]; then
            # 新形式のタイムスタンプから時間を抽出
            local timestamp_part=${dir_name%_*}
            dir_time=$(date -d "${timestamp_part:0:8} ${timestamp_part:9:2}:${timestamp_part:11:2}:${timestamp_part:13:2}" +%s 2>/dev/null || stat -c %Y "$workspace_dir" 2>/dev/null || stat -f %m "$workspace_dir")
        else
            # ファイルシステムの作成時間を使用
            dir_time=$(stat -c %Y "$workspace_dir" 2>/dev/null || stat -f %m "$workspace_dir")
        fi
        
        # カットオフ時間より新しい場合はスキップ
        if [[ $dir_time -gt $cutoff_time ]]; then
            continue
        fi
        
        # アクティブワークスペースかチェック
        local is_active=false
        for active_path in "${active_paths[@]}"; do
            if [[ "$workspace_dir" == "$active_path" ]]; then
                is_active=true
                break
            fi
        done
        
        if [[ "$is_active" == "true" ]]; then
            log_info "Skipping active workspace: $workspace_dir"
            continue
        fi
        
        # ディレクトリサイズを計算
        local dir_size=$(du -sb "$workspace_dir" 2>/dev/null | cut -f1 || echo "0")
        total_size=$((total_size + dir_size))
        
        local dir_age_hours=$(( (current_time - dir_time) / 3600 ))
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would clean up: $workspace_dir (age: ${dir_age_hours}h, size: $(numfmt --to=iec $dir_size))"
        else
            log_info "Cleaning up workspace: $workspace_dir (age: ${dir_age_hours}h, size: $(numfmt --to=iec $dir_size))"
            
            if rm -rf "$workspace_dir"; then
                ((cleaned_count++))
            else
                log_error "Failed to remove: $workspace_dir"
            fi
        fi
        
    done < <(find "$workspace_base" -mindepth 1 -maxdepth 1 -type d -print0)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would clean up $cleaned_count workspaces, freeing $(numfmt --to=iec $total_size)"
    else
        log_info "Cleaned up $cleaned_count workspaces, freed $(numfmt --to=iec $total_size)"
    fi
}

# アクティブワークスペース情報のクリーンアップ
cleanup_active_workspaces_info() {
    local active_workspaces="${CLAUDE_AUTO_HOME}/logs/active_workspaces.json"
    
    if [[ ! -f "$active_workspaces" ]]; then
        return 0
    fi
    
    log_info "Cleaning up stale active workspace entries..."
    
    # 存在しないワークスペースのエントリを削除
    local temp_file="${active_workspaces}.tmp"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        local stale_count
        stale_count=$(jq '[.[] | select(.workspace_path | test(".*") and (. as $path | $path | test(".") and ($path | . as $p | $p)))] | length' "$active_workspaces" 2>/dev/null || echo "0")
        log_info "[DRY RUN] Would remove $stale_count stale active workspace entries"
    else
        jq '[.[] | select(.workspace_path as $path | $path | . as $p | ($p | test(".")) and ($p | . as $workspace | $workspace | test(".") and ($workspace | . as $w | ($w | . as $dir | ($dir | test("^/") and ($dir | . as $check_dir | $check_dir))))))]' "$active_workspaces" > "$temp_file" 2>/dev/null || echo "[]" > "$temp_file"
        
        # より安全な方法: 実際に存在するディレクトリのみ保持
        echo "[]" > "$temp_file"
        while IFS= read -r entry; do
            local workspace_path
            workspace_path=$(echo "$entry" | jq -r '.workspace_path')
            
            if [[ -d "$workspace_path" ]]; then
                jq ". += [$entry]" "$temp_file" > "${temp_file}.new" && mv "${temp_file}.new" "$temp_file"
            fi
        done < <(jq -c '.[]' "$active_workspaces" 2>/dev/null || echo "")
        
        mv "$temp_file" "$active_workspaces"
        log_info "Cleaned up stale active workspace entries"
    fi
}

# メイン処理
main() {
    log_info "Workspace cleanup starting..."
    log_info "Options: DRY_RUN=$DRY_RUN, FORCE=$FORCE, OLDER_THAN_HOURS=$OLDER_THAN_HOURS"
    
    # 確認プロンプト
    if [[ "$FORCE" == "false" ]] && [[ "$DRY_RUN" == "false" ]]; then
        echo "This will clean up workspaces older than $OLDER_THAN_HOURS hours."
        read -p "Continue? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cleanup cancelled"
            exit 0
        fi
    fi
    
    # ワークスペースのクリーンアップ
    cleanup_workspaces
    
    # アクティブワークスペース情報のクリーンアップ
    cleanup_active_workspaces_info
    
    log_info "Workspace cleanup completed"
}

# スクリプトが直接実行された場合
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi