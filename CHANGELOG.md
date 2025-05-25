# Changelog

All notable changes to Claude Automation System will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2025-05-25

### Added

#### Phase 1: Core Foundation
- Complete monitoring system for GitHub repositories
- Event processing system for Issues and Pull Requests  
- Claude execution management with PR creation
- Comprehensive logging with rotation
- YAML-based configuration system
- Git utilities supporting Git-flow and GitHub Flow
- Start/stop/health-check scripts

#### Phase 2: Slack Integration
- Slack webhook notifications
- Interactive buttons for actions
- Channel routing based on notification type
- Mention users configuration
- Rich message formatting

#### Phase 3: Jira Integration  
- GitHub to Jira issue synchronization
- Bidirectional status mapping
- Work time logging
- Comment synchronization
- Custom field configuration

#### Phase 4: Quality Improvements
- Comprehensive test suite (unit, integration, performance)
- Extended GitHub API client
- PR creation and management
- Workflow triggers
- Check status monitoring

#### Phase 5: Production Deployment
- Remote deployment script for Raspberry Pi
- systemd service configuration
- Log rotation setup
- Comprehensive operations guide
- Security best practices documentation

### Changed
- Upgraded from v1.0 single-repo monitoring to multi-repo system
- Enhanced error handling and recovery
- Improved configuration flexibility

### Security
- Automatic masking of sensitive data in logs
- Secure credential management via environment variables
- Minimum permission principle enforcement

## [1.0.0] - 2024-12-01

### Added
- Initial release with basic GitHub monitoring
- Simple Claude execution
- Basic PR creation functionality