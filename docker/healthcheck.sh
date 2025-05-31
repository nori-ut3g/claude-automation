#!/usr/bin/env bash

# Docker ヘルスチェック用スクリプト

set -euo pipefail

CLAUDE_AUTO_HOME="${CLAUDE_AUTO_HOME:-/opt/claude-automation}"

# プロセスが実行中かチェック
if [[ -f "$CLAUDE_AUTO_HOME/monitor.pid" ]]; then
    pid=$(cat "$CLAUDE_AUTO_HOME/monitor.pid")
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "✅ Claude Automation Monitor is running (PID: $pid)"
        exit 0
    else
        echo "❌ Claude Automation Monitor is not running (stale PID file)"
        exit 1
    fi
else
    echo "❌ Claude Automation Monitor PID file not found"
    exit 1
fi