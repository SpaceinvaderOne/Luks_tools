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
    
    verify_prerequisites
    
    # Remove any existing files first
    if [[ -f "$FETCH_KEY_EVENT" ]]; then
        rm "$FETCH_KEY_EVENT"
        debug_log "Removed existing fetch_key file"
    fi
    
    if [[ -f "$DELETE_KEY_EVENT" ]]; then
        rm "$DELETE_KEY_EVENT"
        debug_log "Removed existing delete_key file"
    fi
    
    # Copy files to event directories (same as old working plugin)
    install -D "$FETCH_KEY_SOURCE" "$FETCH_KEY_EVENT"
    if [[ $? -eq 0 ]]; then
        echo "   → Created fetch_key event handler"
        debug_log "Copied file: $FETCH_KEY_SOURCE -> $FETCH_KEY_EVENT"
    else
        error_exit "Failed to copy fetch_key to event directory"
    fi
    
    install -D "$DELETE_KEY_SOURCE" "$DELETE_KEY_EVENT"
    if [[ $? -eq 0 ]]; then
        echo "   → Created delete_key event handler"
        debug_log "Copied file: $DELETE_KEY_SOURCE -> $DELETE_KEY_EVENT"
    else
        error_exit "Failed to copy delete_key to event directory"
    fi
    
    # Ensure copied files are executable
    chmod +x "$FETCH_KEY_EVENT" "$DELETE_KEY_EVENT"
    debug_log "Set executable permissions on event files"
    
    # Update config
    save_config "true"
    
    echo "   → Auto-unlock enabled successfully"
    echo "   → Hardware keys will be applied at next boot"
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