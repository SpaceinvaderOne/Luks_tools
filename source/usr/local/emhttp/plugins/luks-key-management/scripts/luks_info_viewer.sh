#!/bin/bash
#
# Description: LUKS Encryption Information Viewer
# This script provides detailed analysis of LUKS encrypted drives and slot configurations
# It's designed for read-only inspection and requires passphrase validation
#

# Exit on any error
set -e

# --- Configuration & Variables ---

# Default values for script options
DETAIL_LEVEL="simple"
DRY_RUN="yes"
PASSPHRASE=""

# Temporary working directory
TEMP_WORK_DIR="/tmp/luks_info_viewer_$$"

# --- Functions ---

#
# Get LUKS version for a device
#
get_luks_version() {
    local device="$1"
    cryptsetup luksDump "$device" | grep 'Version:' | awk '{print $2}'
}

#
# Find all LUKS encrypted devices in the system
#
get_luks_devices() {
    # Use the same proven method as the main script
    lsblk --noheadings --pairs --output NAME,TYPE | grep 'TYPE="crypt"' | awk -F'"' '{print "/dev/" $2}' | sort
}

#
# Validate that a passphrase can unlock a LUKS device
#
validate_passphrase() {
    local device="$1"
    local passphrase="$2"
    
    # Use cryptsetup luksOpen --test-passphrase to validate
    echo "$passphrase" | cryptsetup luksOpen --test-passphrase "$device" 2>/dev/null
}

#
# Get used slot numbers for a device
#
get_used_slots() {
    local device="$1"
    cryptsetup luksDump "$device" | grep -E "^[0-9]+:" | grep -v "DISABLED" | awk -F: '{print $1}' | sort -n
}

#
# Get slot usage warning level
#
get_slot_warning() {
    local used_count="$1"
    local total_slots=32
    
    if [[ $used_count -ge 29 ]]; then
        echo "🔴 CRITICAL: $used_count/$total_slots slots used (90%+ full)"
    elif [[ $used_count -ge 25 ]]; then
        echo "⚠️  WARNING: $used_count/$total_slots slots used (80%+ full)"
    else
        echo "✅ Healthy: $used_count/$total_slots slots used"
    fi
}

#
# Classify device type (Array, Pool, Standalone)
#
classify_device() {
    local device="$1"
    local device_name=$(basename "$device")
    
    # Check if it's an array device (mdX pattern)
    if [[ "$device_name" =~ ^md[0-9]+p?[0-9]*$ ]]; then
        echo "Array Device"
    # Check if it's likely a pool device (single disk with partition)
    elif [[ "$device_name" =~ ^sd[a-z]+[0-9]+$ ]]; then
        echo "Pool Device"
    else
        echo "Standalone Device"
    fi
}

#
# Get token information for LUKS2 devices
#
get_token_info() {
    local device="$1"
    local slot="$2"
    
    # Only works with LUKS2
    local luks_version=$(get_luks_version "$device")
    if [[ "$luks_version" != "2" ]]; then
        echo "N/A (LUKS1)"
        return
    fi
    
    # Try to get token information
    local token_info=$(cryptsetup luksDump "$device" | grep -A 10 "Tokens:" | grep -A 5 "keyslot.*$slot" 2>/dev/null || echo "")
    
    if [[ -n "$token_info" ]]; then
        # Look for our hardware-bound token pattern
        if echo "$token_info" | grep -q "hw-bound"; then
            local token_date=$(echo "$token_info" | grep -o "hw-bound-[0-9.-]*" | head -1)
            echo "⭐ Hardware-derived ($token_date)"
        else
            echo "Token present"
        fi
    else
        echo "Standard slot"
    fi
}

#
# Get detailed slot information for a device
#
get_detailed_slot_info() {
    local device="$1"
    local passphrase="$2"
    
    echo "    📋 Detailed Slot Analysis:"
    
    local used_slots=($(get_used_slots "$device"))
    
    for slot in "${used_slots[@]}"; do
        local token_info=$(get_token_info "$device" "$slot")
        
        if [[ "$slot" == "0" ]]; then
            echo "    ├─ Slot $slot: Original passphrase"
        else
            echo "    ├─ Slot $slot: $token_info"
        fi
    done
}

#
# Analyze a single device
#
analyze_device() {
    local device="$1"
    local passphrase="$2"
    local detail_level="$3"
    
    # Basic device info
    local luks_version=$(get_luks_version "$device")
    local device_type=$(classify_device "$device")
    local used_slots=($(get_used_slots "$device"))
    local slot_count=${#used_slots[@]}
    local slot_warning=$(get_slot_warning "$slot_count")
    
    echo "📱 Device: $device ($device_type)"
    echo "    🔐 LUKS Version: $luks_version"
    echo "    🔢 Slot Usage: $slot_warning"
    
    # Validate passphrase
    if validate_passphrase "$device" "$passphrase"; then
        echo "    🔑 Passphrase: ✅ Valid"
        
        if [[ "$detail_level" == "detailed" ]]; then
            get_detailed_slot_info "$device" "$passphrase"
        fi
    else
        echo "    🔑 Passphrase: ❌ Invalid for this device"
    fi
    
    echo ""
}

#
# Group devices by slot configuration pattern  
#
group_devices_by_pattern() {
    local devices=("$@")
    local passphrase="$PASSPHRASE"
    
    declare -A patterns
    declare -A pattern_devices
    
    # First pass: identify patterns
    for device in "${devices[@]}"; do
        if validate_passphrase "$device" "$passphrase"; then
            local used_slots=($(get_used_slots "$device"))
            local pattern=$(IFS=','; echo "${used_slots[*]}")
            local luks_version=$(get_luks_version "$device")
            local slot_count=${#used_slots[@]}
            
            local full_pattern="${luks_version}:${pattern}:${slot_count}"
            patterns["$full_pattern"]+="$device "
            pattern_devices["$full_pattern"]="$pattern"
        fi
    done
    
    # Second pass: display grouped results
    for pattern in "${!patterns[@]}"; do
        local devices_in_pattern=(${patterns[$pattern]})
        local slot_pattern="${pattern_devices[$pattern]}"
        
        IFS=':' read -r luks_version slots slot_count <<< "$pattern"
        
        # Classify the group
        local first_device="${devices_in_pattern[0]}"
        local group_type=$(classify_device "$first_device")
        
        if [[ ${#devices_in_pattern[@]} -gt 1 ]]; then
            echo "📂 ${group_type}s (${#devices_in_pattern[@]} devices):"
            echo "    📱 Devices: ${devices_in_pattern[*]}"
        else
            echo "📱 ${group_type} (1 device):"
            echo "    📱 Device: ${devices_in_pattern[*]}"
        fi
        
        echo "    🔐 LUKS Version: $luks_version"
        local slot_warning=$(get_slot_warning "$slot_count")
        echo "    🔢 Slot Usage: $slot_warning"
        
        if [[ "$DETAIL_LEVEL" == "detailed" ]]; then
            echo "    📋 Slot Configuration:"
            local slots_array=(${slots//,/ })
            for slot in "${slots_array[@]}"; do
                local token_info=$(get_token_info "$first_device" "$slot")
                
                if [[ "$slot" == "0" ]]; then
                    echo "    ├─ Slot $slot: Original passphrase"
                else
                    echo "    ├─ Slot $slot: $token_info"
                fi
            done
        fi
        
        echo ""
    done
}

#
# Main analysis function
#
analyze_encryption() {
    local passphrase="$1"
    local detail_level="$2"
    
    echo "=================================================="
    echo "---         LUKS Encryption Analysis          ---"
    echo "=================================================="
    echo ""
    echo "🔍 Analysis Mode: $(echo "$detail_level" | tr '[:lower:]' '[:upper:]')"
    echo "📅 Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Get all LUKS devices
    local devices=($(get_luks_devices))
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "ℹ️  No LUKS encrypted devices found on this system."
        return 0
    fi
    
    echo "🔎 Found ${#devices[@]} LUKS encrypted device(s)"
    echo ""
    
    if [[ "$detail_level" == "simple" ]]; then
        echo "--- Simple Device List ---"
        for device in "${devices[@]}"; do
            local device_type=$(classify_device "$device")
            if validate_passphrase "$device" "$passphrase"; then
                echo "✅ $device ($device_type) - Passphrase valid"
            else
                echo "❌ $device ($device_type) - Passphrase invalid"
            fi
        done
    else
        echo "--- Detailed Analysis with Smart Grouping ---"
        group_devices_by_pattern "${devices[@]}"
    fi
    
    echo ""
    echo "=================================================="
    echo "---            Analysis Complete               ---"
    echo "=================================================="
    
    return 0
}

#
# Parse command line arguments
#
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--detail-level)
                DETAIL_LEVEL="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN="yes"
                shift
                ;;
            -p|--passphrase)
                PASSPHRASE="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_usage
                exit 1
                ;;
        esac
    done
}

#
# Show usage information
#
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

LUKS Encryption Information Viewer

OPTIONS:
    -d, --detail-level LEVEL   Analysis detail level: simple or detailed (default: simple)
    --dry-run                  Dry run mode (default behavior)
    -p, --passphrase PASS      LUKS passphrase (can also be provided via LUKS_PASSPHRASE env var)
    -h, --help                 Show this help message

ENVIRONMENT VARIABLES:
    LUKS_PASSPHRASE           LUKS passphrase (alternative to -p option)

EXAMPLES:
    $0 -p "mypassphrase"                          # Simple device listing
    $0 -p "mypassphrase" -d detailed              # Detailed analysis with slot info
    LUKS_PASSPHRASE="pass" $0 -d detailed        # Using environment variable

EOF
}

#
# Cleanup function
#
cleanup() {
    if [[ -d "$TEMP_WORK_DIR" ]]; then
        rm -rf "$TEMP_WORK_DIR"
    fi
}

# Set up cleanup trap
trap cleanup EXIT

# --- Main Script Logic ---

# Parse command line arguments
parse_args "$@"

# Get passphrase from environment if not provided via command line
if [[ -z "$PASSPHRASE" && -n "$LUKS_PASSPHRASE" ]]; then
    PASSPHRASE="$LUKS_PASSPHRASE"
fi

# Validate that we have a passphrase
if [[ -z "$PASSPHRASE" ]]; then
    echo "Error: No passphrase provided. Use -p option or LUKS_PASSPHRASE environment variable." >&2
    exit 1
fi

# Create temporary directory if needed
mkdir -p "$TEMP_WORK_DIR"

# Run the analysis
analyze_encryption "$PASSPHRASE" "$DETAIL_LEVEL"

echo "Script finished."