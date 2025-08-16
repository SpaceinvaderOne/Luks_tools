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

# Hardware key detection functions for smart UX

# Check if hardware keys have been generated before
check_hardware_keys_exist() {
    # Check if we have evidence of previous key generation by looking for hardware-derived entries
    debug_log "Checking for existing hardware keys..."
    
    # Find LUKS devices to check
    local luks_devices=()
    mapfile -t luks_devices < <(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS" {print "/dev/"$1}' 2>/dev/null)
    
    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        debug_log "No LUKS devices found"
        echo "false"
        return 1
    fi
    
    # Check each device for hardware-derived tokens or metadata
    for device in "${luks_devices[@]}"; do
        debug_log "Checking device: $device"
        
        # Check for multiple patterns that indicate hardware-derived keys
        local dump_output
        dump_output=$(cryptsetup luksDump "$device" 2>/dev/null)
        
        if [[ -n "$dump_output" ]]; then
            # Look for different possible patterns
            if echo "$dump_output" | grep -qi "unraid-derived\|hardware-derived\|Hardware-derived"; then
                debug_log "Found hardware-derived token on $device"
                echo "true"
                return 0
            fi
            
            # Also check if luks_management.sh finds derived slots
            local luks_script="/usr/local/emhttp/plugins/luks-key-management/scripts/luks_management.sh"
            if [[ -f "$luks_script" ]]; then
                # Use the working detection logic from the main script
                if echo "$dump_output" | grep -q '"type".*"unraid-derived"'; then
                    debug_log "Found unraid-derived JSON token on $device"
                    echo "true"
                    return 0
                fi
            fi
        fi
    done
    
    debug_log "No hardware-derived tokens found"
    echo "false"
    return 1
}

# Test if current hardware keys can unlock LUKS devices
test_hardware_keys_work() {
    debug_log "Testing if current hardware keys work..."
    
    # First check if keys exist at all
    if [[ "$(check_hardware_keys_exist)" == "false" ]]; then
        debug_log "No hardware keys exist to test"
        echo "false"
        return 1
    fi
    
    # Use the main LUKS script to test - it has working logic
    local luks_script="/usr/local/emhttp/plugins/luks-key-management/scripts/luks_management.sh"
    if [[ ! -f "$luks_script" ]]; then
        debug_log "LUKS management script not found"
        echo "false"
        return 1
    fi
    
    # Generate current hardware key using fetch_key
    local fetch_key_script="$PERSISTENT_DIR/fetch_key"
    if [[ ! -f "$fetch_key_script" ]]; then
        debug_log "fetch_key script not found"
        echo "false"
        return 1
    fi
    
    # Get current hardware-derived key
    local current_key
    current_key=$("$fetch_key_script" 2>/dev/null)
    if [[ -z "$current_key" ]]; then
        debug_log "Failed to generate current hardware key"
        echo "false"
        return 1
    fi
    
    # Find LUKS devices to test
    local luks_devices=()
    mapfile -t luks_devices < <(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS" {print "/dev/"$1}' 2>/dev/null)
    
    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        debug_log "No LUKS devices found"
        echo "false"
        return 1
    fi
    
    # Test if current key works on any LUKS device
    for device in "${luks_devices[@]}"; do
        debug_log "Testing hardware key on device: $device"
        
        # Test the key (this just validates, doesn't actually unlock)
        if echo "$current_key" | cryptsetup luksOpen --test-passphrase "$device" 2>/dev/null; then
            debug_log "Hardware key works on $device"
            echo "true"
            return 0
        fi
    done
    
    debug_log "Hardware key doesn't work on any device"
    echo "false"
    return 1
}

# Get current hardware fingerprint for display
get_hardware_fingerprint() {
    debug_log "Getting hardware fingerprint..."
    
    # Get motherboard serial
    local motherboard_id
    motherboard_id=$(dmidecode -s baseboard-serial-number 2>/dev/null | head -1 | tr -d '[:space:]')
    
    # Get gateway MAC
    local gateway_mac
    gateway_mac=$(ip route show default | head -1 | awk '{print $3}' | xargs -I {} arp -n {} 2>/dev/null | awk '{print $3}' | head -1)
    
    if [[ -n "$motherboard_id" ]] && [[ -n "$gateway_mac" ]]; then
        echo "MB:${motherboard_id} / GW:${gateway_mac}"
    else
        debug_log "Failed to get hardware components: MB='$motherboard_id' GW='$gateway_mac'"
        echo "unknown"
    fi
}

# Get list of LUKS devices that can be unlocked
get_unlockable_devices() {
    debug_log "Getting list of unlockable LUKS devices..."
    
    # Find all LUKS devices
    local luks_devices=()
    mapfile -t luks_devices < <(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS" {print "/dev/"$1}' 2>/dev/null)
    
    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        debug_log "No LUKS devices found"
        echo "none"
        return 1
    fi
    
    # Count devices with unraid-derived tokens
    local unlockable_count=0
    local device_list=""
    
    for device in "${luks_devices[@]}"; do
        if cryptsetup luksDump "$device" 2>/dev/null | grep -q "unraid-derived"; then
            unlockable_count=$((unlockable_count + 1))
            if [[ -n "$device_list" ]]; then
                device_list="$device_list, "
            fi
            device_list="$device_list$(basename "$device")"
        fi
    done
    
    if [[ $unlockable_count -gt 0 ]]; then
        echo "$unlockable_count device(s): $device_list"
    else
        echo "none"
    fi
}

# Determine overall system state for smart UX
get_system_state() {
    local keys_exist
    local keys_work
    
    keys_exist=$(check_hardware_keys_exist)
    keys_work=$(test_hardware_keys_work)
    
    if [[ "$keys_exist" == "false" ]]; then
        echo "setup_required"
    elif [[ "$keys_work" == "true" ]]; then
        echo "ready"
    else
        echo "refresh_needed"
    fi
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

# Enable auto-unlock by saving config (files created automatically at boot)
enable_auto_unlock() {
    echo "Enabling LUKS auto-unlock..."
    
    verbose_log "Starting enable_auto_unlock process"
    
    # Verify prerequisites exist
    verify_prerequisites
    
    # Save config as enabled
    save_config "true"
    verbose_log "Config saved: AUTO_UNLOCK_ENABLED=true"
    
    # Create event files immediately for current session
    verbose_log "Creating event files for immediate effect..."
    
    # Create event directories if they don't exist
    mkdir -p "$EVENT_STARTING_DIR"
    mkdir -p "$EVENT_STARTED_DIR"
    
    # Copy files to event directories
    if install -D "$FETCH_KEY_SOURCE" "$FETCH_KEY_EVENT" 2>/dev/null; then
        chmod +x "$FETCH_KEY_EVENT"
        echo "   → Created fetch_key event handler"
        verbose_log "Created fetch_key event file"
    else
        verbose_log "Warning: Could not create fetch_key event file immediately"
    fi
    
    if install -D "$DELETE_KEY_SOURCE" "$DELETE_KEY_EVENT" 2>/dev/null; then
        chmod +x "$DELETE_KEY_EVENT"
        echo "   → Created delete_key event handler"
        verbose_log "Created delete_key event file"
    else
        verbose_log "Warning: Could not create delete_key event file immediately"
    fi
    
    echo "   → Auto-unlock enabled successfully"
    echo "   → Event files will be recreated automatically on every boot"
    echo "   → Hardware keys will be applied at next boot"
    verbose_log "Enable operation completed successfully"
}

# Disable auto-unlock by saving config and removing current files
disable_auto_unlock() {
    echo "Disabling LUKS auto-unlock..."
    
    # Save config as disabled
    save_config "false"
    verbose_log "Config saved: AUTO_UNLOCK_ENABLED=false"
    
    local changes_made=false
    
    # Remove current session files
    if [[ -f "$FETCH_KEY_EVENT" ]]; then
        rm "$FETCH_KEY_EVENT"
        echo "   → Removed fetch_key event handler"
        verbose_log "Removed file: $FETCH_KEY_EVENT"
        changes_made=true
    fi
    
    if [[ -f "$DELETE_KEY_EVENT" ]]; then
        rm "$DELETE_KEY_EVENT"
        echo "   → Removed delete_key event handler"
        verbose_log "Removed file: $DELETE_KEY_EVENT"
        changes_made=true
    fi
    
    if [[ "$changes_made" == "true" ]]; then
        echo "   → Auto-unlock disabled successfully"
    else
        echo "   → Auto-unlock was already disabled"
    fi
    
    echo "   → Event files will not be recreated on next boot"
    verbose_log "Disable operation completed successfully"
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
        "system_state")
            # Get overall system state for smart UX
            get_system_state
            ;;
        "hardware_fingerprint")
            # Get hardware fingerprint for display
            get_hardware_fingerprint
            ;;
        "unlockable_devices")
            # Get list of unlockable LUKS devices
            get_unlockable_devices
            ;;
        "check_keys_exist")
            # Check if hardware keys exist
            check_hardware_keys_exist
            ;;
        "test_keys_work")
            # Test if hardware keys work
            test_hardware_keys_work
            ;;
        *)
            echo "Usage: $0 {enable|disable|status|get_status|system_state|hardware_fingerprint|unlockable_devices|check_keys_exist|test_keys_work}"
            echo ""
            echo "Commands:"
            echo "  enable              - Enable LUKS auto-unlock"
            echo "  disable             - Disable LUKS auto-unlock"
            echo "  status              - Show detailed auto-unlock status"
            echo "  get_status          - Get simple status (enabled/disabled)"
            echo "  system_state        - Get system state (setup_required/ready/refresh_needed)"
            echo "  hardware_fingerprint - Get current hardware fingerprint"
            echo "  unlockable_devices  - Get list of unlockable LUKS devices"
            echo "  check_keys_exist    - Check if hardware keys have been generated"
            echo "  test_keys_work      - Test if hardware keys work with current system"
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"