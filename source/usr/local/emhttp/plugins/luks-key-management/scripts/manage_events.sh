#!/bin/bash
#
# Description: Manages LUKS auto-unlock event scripts by enabling/disabling symlinks
#
# This script handles the enable/disable of auto-unlock functionality by creating
# or removing symlinks in the Unraid event directories.

# --- Configuration ---
PERSISTENT_DIR="/boot/config/plugins/luks-key-management"
EVENT_STARTING_DIR="/usr/local/emhttp/webGui/event/starting"
EVENT_STARTED_DIR="/usr/local/emhttp/webGui/event/started"
CONFIG_FILE="$PERSISTENT_DIR/config"

# Source scripts
FETCH_KEY_SOURCE="$PERSISTENT_DIR/fetch_key"
DELETE_KEY_SOURCE="$PERSISTENT_DIR/delete_key"

# Event script targets
FETCH_KEY_EVENT="$EVENT_STARTING_DIR/fetch_key"
DELETE_KEY_EVENT="$EVENT_STARTED_DIR/delete_key"

# --- Functions ---

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

debug_log() {
    echo "DEBUG: $1" >&2
}

verbose_log() {
    echo "VERBOSE: $1"
}

# Load plugin configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        # Create default config if missing
        echo "AUTO_UNLOCK_ENABLED=false" > "$CONFIG_FILE"
        AUTO_UNLOCK_ENABLED="false"
        debug_log "Created default config file"
    fi
    
    debug_log "Current auto-unlock status: $AUTO_UNLOCK_ENABLED"
}

# Save plugin configuration
save_config() {
    local enabled="$1"
    echo "AUTO_UNLOCK_ENABLED=$enabled" > "$CONFIG_FILE"
    debug_log "Saved config: AUTO_UNLOCK_ENABLED=$enabled"
}

# Verify required directories and files exist
verify_prerequisites() {
    # Check event directories
    if [[ ! -d "$EVENT_STARTING_DIR" ]]; then
        mkdir -p "$EVENT_STARTING_DIR"
        debug_log "Created event starting directory"
    fi
    
    if [[ ! -d "$EVENT_STARTED_DIR" ]]; then
        mkdir -p "$EVENT_STARTED_DIR"
        debug_log "Created event started directory"
    fi
    
    # Check source scripts
    if [[ ! -f "$FETCH_KEY_SOURCE" ]]; then
        error_exit "fetch_key source script not found at $FETCH_KEY_SOURCE"
    fi
    
    if [[ ! -f "$DELETE_KEY_SOURCE" ]]; then
        error_exit "delete_key source script not found at $DELETE_KEY_SOURCE"
    fi
    
    # Ensure source scripts are executable
    chmod +x "$FETCH_KEY_SOURCE" "$DELETE_KEY_SOURCE"
    debug_log "Verified source scripts are executable"
}

# Check current auto-unlock status by examining actual files
get_current_status() {
    if [[ -f "$FETCH_KEY_EVENT" ]] && [[ -f "$DELETE_KEY_EVENT" ]]; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

# Enable auto-unlock by copying files to event directories
enable_auto_unlock() {
    echo "Enabling LUKS auto-unlock..."
    
    # Enhanced debugging and verification
    verbose_log "Starting enable_auto_unlock process"
    verbose_log "Source directory: $PERSISTENT_DIR"
    verbose_log "Target starting dir: $EVENT_STARTING_DIR"
    verbose_log "Target started dir: $EVENT_STARTED_DIR"
    
    # Check if source directory exists
    if [[ ! -d "$PERSISTENT_DIR" ]]; then
        error_exit "Source directory does not exist: $PERSISTENT_DIR"
    fi
    verbose_log "Source directory exists: $PERSISTENT_DIR"
    
    # Create event directories if they don't exist
    verbose_log "Creating event directories if needed..."
    mkdir -p "$EVENT_STARTING_DIR"
    mkdir -p "$EVENT_STARTED_DIR"
    
    # Verify directories were created
    if [[ ! -d "$EVENT_STARTING_DIR" ]]; then
        error_exit "Failed to create starting event directory: $EVENT_STARTING_DIR"
    fi
    if [[ ! -d "$EVENT_STARTED_DIR" ]]; then
        error_exit "Failed to create started event directory: $EVENT_STARTED_DIR"
    fi
    verbose_log "Event directories verified to exist"
    
    # Test write permissions
    verbose_log "Testing write permissions..."
    if ! touch "$EVENT_STARTING_DIR/.test" 2>/dev/null; then
        error_exit "No write permission to starting event directory: $EVENT_STARTING_DIR"
    fi
    rm -f "$EVENT_STARTING_DIR/.test"
    
    if ! touch "$EVENT_STARTED_DIR/.test" 2>/dev/null; then
        error_exit "No write permission to started event directory: $EVENT_STARTED_DIR"
    fi
    rm -f "$EVENT_STARTED_DIR/.test"
    verbose_log "Write permissions verified"
    
    verify_prerequisites
    
    # Check source files exist and are readable
    verbose_log "Verifying source files..."
    if [[ ! -f "$FETCH_KEY_SOURCE" ]]; then
        error_exit "Source file does not exist: $FETCH_KEY_SOURCE"
    fi
    if [[ ! -r "$FETCH_KEY_SOURCE" ]]; then
        error_exit "Source file is not readable: $FETCH_KEY_SOURCE"
    fi
    if [[ ! -f "$DELETE_KEY_SOURCE" ]]; then
        error_exit "Source file does not exist: $DELETE_KEY_SOURCE"
    fi
    if [[ ! -r "$DELETE_KEY_SOURCE" ]]; then
        error_exit "Source file is not readable: $DELETE_KEY_SOURCE"
    fi
    verbose_log "Source files verified: both exist and are readable"
    
    # Remove any existing files first
    if [[ -f "$FETCH_KEY_EVENT" ]]; then
        rm "$FETCH_KEY_EVENT"
        verbose_log "Removed existing fetch_key file"
    fi
    
    if [[ -f "$DELETE_KEY_EVENT" ]]; then
        rm "$DELETE_KEY_EVENT"
        verbose_log "Removed existing delete_key file"
    fi
    
    # Copy files to event directories with enhanced error handling
    verbose_log "Attempting to copy fetch_key using install -D..."
    install_output=$(install -D "$FETCH_KEY_SOURCE" "$FETCH_KEY_EVENT" 2>&1)
    install_result=$?
    
    if [[ $install_result -eq 0 ]]; then
        verbose_log "install -D succeeded for fetch_key"
    else
        verbose_log "install -D failed for fetch_key. Output: $install_output"
        verbose_log "Attempting fallback copy method..."
        
        if cp "$FETCH_KEY_SOURCE" "$FETCH_KEY_EVENT" 2>&1; then
            verbose_log "Fallback copy succeeded for fetch_key"
        else
            error_exit "Both install -D and cp failed for fetch_key. Last error: $install_output"
        fi
    fi
    
    # Verify fetch_key was created
    if [[ ! -f "$FETCH_KEY_EVENT" ]]; then
        error_exit "fetch_key file was not created at: $FETCH_KEY_EVENT"
    fi
    echo "   → Created fetch_key event handler"
    verbose_log "Verified fetch_key file exists at: $FETCH_KEY_EVENT"
    
    verbose_log "Attempting to copy delete_key using install -D..."
    install_output=$(install -D "$DELETE_KEY_SOURCE" "$DELETE_KEY_EVENT" 2>&1)
    install_result=$?
    
    if [[ $install_result -eq 0 ]]; then
        verbose_log "install -D succeeded for delete_key"
    else
        verbose_log "install -D failed for delete_key. Output: $install_output"
        verbose_log "Attempting fallback copy method..."
        
        if cp "$DELETE_KEY_SOURCE" "$DELETE_KEY_EVENT" 2>&1; then
            verbose_log "Fallback copy succeeded for delete_key"
        else
            error_exit "Both install -D and cp failed for delete_key. Last error: $install_output"
        fi
    fi
    
    # Verify delete_key was created
    if [[ ! -f "$DELETE_KEY_EVENT" ]]; then
        error_exit "delete_key file was not created at: $DELETE_KEY_EVENT"
    fi
    echo "   → Created delete_key event handler"
    verbose_log "Verified delete_key file exists at: $DELETE_KEY_EVENT"
    
    # Ensure copied files are executable
    verbose_log "Setting executable permissions..."
    chmod +x "$FETCH_KEY_EVENT" "$DELETE_KEY_EVENT"
    
    # Verify permissions were set
    if [[ ! -x "$FETCH_KEY_EVENT" ]]; then
        error_exit "Failed to set executable permission on: $FETCH_KEY_EVENT"
    fi
    if [[ ! -x "$DELETE_KEY_EVENT" ]]; then
        error_exit "Failed to set executable permission on: $DELETE_KEY_EVENT"
    fi
    verbose_log "Executable permissions verified"
    
    # Update config
    save_config "true"
    verbose_log "Config saved: AUTO_UNLOCK_ENABLED=true"
    
    # Final verification
    verbose_log "Performing final verification..."
    local final_status=$(get_current_status)
    if [[ "$final_status" != "enabled" ]]; then
        error_exit "Final verification failed. Status: $final_status"
    fi
    
    echo "   → Auto-unlock enabled successfully"
    echo "   → Hardware keys will be applied at next boot"
    verbose_log "Enable operation completed successfully"
}

# Disable auto-unlock by removing files
disable_auto_unlock() {
    echo "Disabling LUKS auto-unlock..."
    
    local changes_made=false
    
    # Remove files
    if [[ -f "$FETCH_KEY_EVENT" ]]; then
        rm "$FETCH_KEY_EVENT"
        echo "   → Removed fetch_key event handler"
        debug_log "Removed file: $FETCH_KEY_EVENT"
        changes_made=true
    fi
    
    if [[ -f "$DELETE_KEY_EVENT" ]]; then
        rm "$DELETE_KEY_EVENT"
        echo "   → Removed delete_key event handler"
        debug_log "Removed file: $DELETE_KEY_EVENT"
        changes_made=true
    fi
    
    # Update config
    save_config "false"
    
    if [[ "$changes_made" == "true" ]]; then
        echo "   → Auto-unlock disabled successfully"
    else
        echo "   → Auto-unlock was already disabled"
    fi
}

# Get detailed status information
get_status() {
    echo "LUKS Auto-Unlock Status:"
    echo ""
    
    # Load current config
    load_config
    
    echo "Config file setting: $AUTO_UNLOCK_ENABLED"
    
    # Check actual symlink status
    local actual_status=$(get_current_status)
    echo "Event scripts status: $actual_status"
    
    # Check individual files
    if [[ -f "$FETCH_KEY_EVENT" ]]; then
        echo "fetch_key event: enabled (file present)"
    else
        echo "fetch_key event: disabled"
    fi
    
    if [[ -f "$DELETE_KEY_EVENT" ]]; then
        echo "delete_key event: enabled (file present)"
    else
        echo "delete_key event: disabled"
    fi
    
    # Check for inconsistencies
    if [[ "$AUTO_UNLOCK_ENABLED" != "$actual_status" ]]; then
        echo ""
        echo "WARNING: Config setting and actual status don't match!"
        echo "This may indicate a configuration issue."
    fi
}

# Main execution
main() {
    local operation="$1"
    
    case "$operation" in
        "enable")
            enable_auto_unlock
            ;;
        "disable")
            disable_auto_unlock
            ;;
        "status")
            get_status
            ;;
        "get_status")
            # Simple status for programmatic use
            get_current_status
            ;;
        *)
            echo "Usage: $0 {enable|disable|status|get_status}"
            echo ""
            echo "Commands:"
            echo "  enable     - Enable LUKS auto-unlock (create event symlinks)"
            echo "  disable    - Disable LUKS auto-unlock (remove event symlinks)"
            echo "  status     - Show detailed auto-unlock status"
            echo "  get_status - Get simple status (enabled/disabled)"
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"