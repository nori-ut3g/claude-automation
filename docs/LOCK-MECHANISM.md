# Lock Mechanism Documentation

## Overview

The Claude Automation System implements a robust file-based locking mechanism to prevent race conditions and ensure data consistency when processing GitHub issues and PRs. This document describes the improved lock mechanism that addresses all known concurrency issues.

## Key Improvements

### 1. Race Condition Prevention

**Problem Solved**: Multiple processes trying to acquire the same lock simultaneously.

**Solution**: 
- Atomic lock acquisition using `mkdir` (which is atomic on most filesystems)
- Comprehensive lock state validation before cleanup
- Reduced retry intervals for faster responsiveness
- Proper sequencing of stale lock detection and cleanup

### 2. JSON Writing Conflicts

**Problem Solved**: Multiple processes writing to `execution_history.json` causing corruption.

**Solution**:
- Unique temporary file names using PID and nanosecond timestamps
- Multiple retry attempts (up to 3) for file operations
- Atomic file replacement using `mv`
- JSON validation before and after updates
- Separate lock for execution history updates

### 3. Multiple Monitor Coordination

**Problem Solved**: Multiple monitor instances processing the same issue.

**Solution**:
- Global processing limit enforcement
- Per-resource locking (issue/PR specific)
- Lock cleanup before processing attempts
- Host-aware lock management for distributed setups

### 4. Lock Timeout and Cleanup

**Problem Solved**: Locks not being released properly on process death.

**Solution**:
- Extended timeout values (10 minutes for main locks, 1 minute for history locks)
- Comprehensive stale lock detection:
  - Process existence checking (same host only)
  - Age-based expiration (15 minutes default)
  - Incomplete lock information detection
- Automatic cleanup before lock acquisition attempts

### 5. Process Death Scenarios

**Problem Solved**: Orphaned locks when processes are killed unexpectedly.

**Solution**:
- Signal trap handlers for clean lock release
- PID-based stale lock detection
- Timestamp-based expiration
- Comprehensive lock information storage (PID, timestamp, host, resource)

## Lock Types

### 1. Resource Locks
- **Purpose**: Prevent multiple processes from working on the same issue/PR
- **Format**: `{repo_name}_issue_{number}.lock` or `{repo_name}_pr_{number}.lock`
- **Timeout**: 10 minutes
- **Location**: `$CLAUDE_AUTO_HOME/locks/`

### 2. Execution History Lock
- **Purpose**: Serialize access to `execution_history.json`
- **Format**: `execution_history.lock`
- **Timeout**: 1 minute
- **Location**: `$CLAUDE_AUTO_HOME/locks/`

## Lock File Structure

Each lock is a directory containing:
```
{lock_name}.lock/
├── pid         # Process ID of lock owner
├── timestamp   # Unix timestamp when lock was acquired
├── host        # Hostname of the machine that acquired the lock
└── resource    # Resource identifier (for debugging)
```

## API Reference

### Core Functions

#### `acquire_lock(lock_name)`
Acquires a named lock with comprehensive stale lock detection.

**Parameters**:
- `lock_name`: Unique identifier for the lock

**Returns**: 
- `0` on success
- `1` on failure (timeout or error)

**Features**:
- Atomic acquisition using `mkdir`
- Automatic stale lock cleanup
- Process existence validation
- Age-based expiration
- Detailed logging

#### `release_lock(lock_name)`
Releases a previously acquired lock with ownership validation.

**Parameters**:
- `lock_name`: Name of the lock to release

**Features**:
- Ownership verification
- Safe cleanup even if ownership is unclear
- Detailed logging

#### `update_execution_history(issue_number, repo_name, status, details)`
Thread-safe update of execution history with file locking.

**Parameters**:
- `issue_number`: GitHub issue number
- `repo_name`: Repository name
- `status`: Current status (in_progress, completed, failed)
- `details`: Additional details

**Features**:
- Separate lock for serialization
- Atomic file updates
- JSON validation
- Multiple retry attempts
- Corruption recovery

### Utility Functions

#### `cleanup_stale_locks(max_age)`
Removes stale locks based on age and process status.

**Parameters**:
- `max_age`: Maximum age in seconds (default: 900 = 15 minutes)

#### `check_global_processing_limit(max_concurrent)`
Enforces global limit on concurrent processing.

**Parameters**:
- `max_concurrent`: Maximum concurrent processes (default: 3)

#### `setup_lock_cleanup_trap(lock_name)`
Sets up signal handlers for automatic lock cleanup on process termination.

**Parameters**:
- `lock_name`: Lock to clean up on exit

## Usage Examples

### Basic Lock Usage
```bash
# Acquire lock
if acquire_lock "my_resource"; then
    # Setup cleanup on exit
    setup_lock_cleanup_trap "my_resource"
    
    # Do protected work
    echo "Working on resource..."
    
    # Release lock (also done automatically on exit)
    release_lock "my_resource"
else
    echo "Failed to acquire lock"
    exit 1
fi
```

### Processing with Global Limits
```bash
# Check global processing limits
if ! check_global_processing_limit 3; then
    echo "Too many concurrent processes"
    exit 1
fi

# Clean up stale locks
cleanup_stale_locks

# Proceed with normal processing
acquire_lock "my_resource"
# ... do work ...
release_lock "my_resource"
```

### Safe History Updates
```bash
# Update execution history
update_execution_history 123 "user/repo" "in_progress" "Started processing"

# Later...
update_execution_history 123 "user/repo" "completed" "Successfully processed"
```

## Management Tools

### Lock Cleanup Script
```bash
# Clean locks older than 15 minutes (default)
./scripts/cleanup-locks.sh

# Clean locks older than 5 minutes
./scripts/cleanup-locks.sh --age 300

# Force clean all locks
./scripts/cleanup-locks.sh --force

# List current lock status
./scripts/cleanup-locks.sh --list
```

### Test Suite
```bash
# Run comprehensive lock mechanism tests
./tests/test-lock-mechanism.sh
```

## Configuration

### Environment Variables
- `CLAUDE_AUTO_HOME`: Base directory for the system
- `EXECUTION_LOCK_DIR`: Directory for lock files (default: `$CLAUDE_AUTO_HOME/locks`)
- `EXECUTION_HISTORY_FILE`: Path to execution history file

### Timeouts
- Resource lock timeout: 600 seconds (10 minutes)
- History lock timeout: 60 seconds (1 minute)
- Stale lock age threshold: 900 seconds (15 minutes)
- Maximum concurrent processes: 3 (configurable)

## Best Practices

### 1. Always Use Cleanup Traps
```bash
acquire_lock "resource"
setup_lock_cleanup_trap "resource"
# Work is now protected against unexpected termination
```

### 2. Check Global Limits Early
```bash
if ! check_global_processing_limit; then
    log_warn "Global processing limit reached"
    exit 1
fi
```

### 3. Clean Up Before Processing
```bash
cleanup_stale_locks
acquire_lock "resource"
```

### 4. Use Specific Lock Names
```bash
# Good: specific and unique
lock_name="${repo_name//\//_}_issue_${issue_number}"

# Bad: too generic
lock_name="processing"
```

### 5. Handle Lock Failures Gracefully
```bash
if ! acquire_lock "$lock_name"; then
    log_error "Could not acquire lock, possibly already being processed"
    exit 1
fi
```

## Troubleshooting

### Common Issues

#### 1. "Failed to acquire lock" errors
- **Cause**: Another process is already working on the resource
- **Solution**: Wait or check if the other process is still active

#### 2. JSON parsing errors
- **Cause**: Corrupted execution history file
- **Solution**: The system will automatically recover by resetting to an empty array

#### 3. Lock directory permission errors
- **Cause**: Insufficient permissions to create/modify lock files
- **Solution**: Ensure proper permissions on `$CLAUDE_AUTO_HOME/locks/`

#### 4. Stale locks not being cleaned
- **Cause**: Process running on different host or permission issues
- **Solution**: Use `./scripts/cleanup-locks.sh --force` or check permissions

### Debugging

#### Check Lock Status
```bash
# List all current locks
./scripts/cleanup-locks.sh --list

# Check specific lock
ls -la $CLAUDE_AUTO_HOME/locks/my_resource.lock/
```

#### Manual Lock Cleanup
```bash
# Remove specific lock
rm -rf $CLAUDE_AUTO_HOME/locks/problematic_lock.lock

# Remove all locks (dangerous!)
./scripts/cleanup-locks.sh --force
```

#### Enable Debug Logging
```bash
export LOG_LEVEL_STRING="DEBUG"
# Run your process - will show detailed lock operations
```

## Migration from Old System

The new lock mechanism is backward compatible but provides these improvements:

1. **Atomic Operations**: No more race conditions during lock acquisition
2. **Better Cleanup**: Automatic detection and removal of stale locks
3. **Rich Metadata**: Lock files now contain comprehensive information
4. **Signal Handling**: Proper cleanup on process termination
5. **Global Coordination**: System-wide processing limits

Existing code using `acquire_lock()` and `release_lock()` will work without changes, but gains all the new robustness features automatically.