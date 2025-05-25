# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the Claude DevOps Automation System - a GitHub Issue/PR monitoring and Claude automatic execution system for advanced development automation.

## Common Development Tasks

### Building and Testing
```bash
# Install dependencies (when implemented)
./scripts/install.sh

# Start the monitoring system
./scripts/start.sh

# Stop the monitoring system
./scripts/stop.sh

# Run health check
./scripts/health-check.sh

# Run tests
./tests/run-tests.sh
```

### Linting and Code Quality
```bash
# Run shellcheck on all bash scripts
shellcheck src/**/*.sh scripts/*.sh

# Validate YAML configuration files
yamllint config/*.yaml
```

## High-Level Architecture

### System Components

1. **Core Monitoring System** (`src/core/`)
   - `monitor.sh`: Main monitoring process that polls GitHub APIs
   - `event-processor.sh`: Processes GitHub events and triggers actions
   - `claude-executor.sh`: Manages Claude Code execution

2. **Integration Layer** (`src/integrations/`)
   - `slack-client.sh`: Handles Slack notifications and interactions
   - `jira-client.sh`: Manages Jira ticket creation and synchronization
   - `github-client.sh`: Extended GitHub API operations

3. **Configuration System** (`config/`)
   - `repositories.yaml`: Defines monitored repositories and their settings
   - `integrations.yaml`: External service credentials and settings
   - `claude-prompts.yaml`: Claude prompt templates

### Key Workflows

1. **GitHub Event Detection Flow**:
   - Monitor process polls GitHub API every 60 seconds
   - Detects issues/PRs with specific labels (e.g., "claude-auto")
   - Triggers event processor for matching events

2. **Claude Execution Flow**:
   - Event processor analyzes issue/PR content
   - Determines appropriate Git workflow (gitflow vs github-flow)
   - Executes Claude Code with context
   - Creates PR with implementation

3. **External Service Integration**:
   - Slack notifications for start/complete/error states
   - Jira ticket creation and status synchronization
   - Bidirectional comment syncing

### Branch Strategy Logic

The system supports multiple Git workflows:
- **Git-flow**: feature/bugfix/hotfix/release branches
- **GitHub Flow**: simple main branch-based workflow

Branch naming is automated based on issue labels:
- "hotfix", "critical", "urgent" → `hotfix/claude-auto-issue-{number}`
- "bug", "fix" → `bugfix/claude-auto-issue-{number}`
- "feature", "enhancement" → `feature/claude-auto-issue-{number}`

## Development Guidelines

### Environment Variables Required
```bash
GITHUB_TOKEN        # GitHub API access
SLACK_WEBHOOK_URL   # Slack notifications
JIRA_BASE_URL       # Jira instance URL
JIRA_USERNAME       # Jira authentication
JIRA_API_TOKEN      # Jira API token
```

### Directory Structure Guidelines
- Keep scripts modular and focused on single responsibilities
- Use `src/utils/` for shared functionality
- Store all configuration in `config/` directory
- Maintain logs in `logs/` with proper rotation
- Use `workspace/` for temporary clone operations

### Testing Approach
- Unit tests for individual script functions
- Integration tests for API interactions
- End-to-end tests with mock GitHub events
- Use test fixtures in `tests/fixtures/`