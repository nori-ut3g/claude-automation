#!/usr/bin/env bash

# simple-health-check.sh - シンプルなヘルスチェック（テスト用）

set -euo pipefail

CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

echo "Claude Automation System - Simple Health Check"
echo "============================================="
echo ""

# PIDファイルチェック
if [[ -f "$CLAUDE_AUTO_HOME/monitor.pid" ]]; then
    pid=$(cat "$CLAUDE_AUTO_HOME/monitor.pid")
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "✅ Process is running (PID: $pid)"
    else
        echo "⚠️  Stale PID file found"
    fi
else
    echo "❌ Process is not running"
fi

# gh CLI認証チェック
if gh auth status >/dev/null 2>&1; then
    echo "✅ gh CLI is authenticated"
else
    echo "❌ gh CLI is not authenticated"
fi

# 設定ファイルチェック
if [[ -f "$CLAUDE_AUTO_HOME/config/repositories.yaml" ]]; then
    echo "✅ Configuration files exist"
else
    echo "❌ Configuration files missing"
fi

echo ""
echo "Use './scripts/start.sh' to start the system"