#!/bin/bash
#
# Description: Encrypt drives with a hardware-tied key and manage LUKS headers.
# This script generates a dynamic key based on hardware identifiers (motherboard
# serial and default gateway MAC address) and adds it as a valid key to all
# LUKS-encrypted devices. It also provides functionality to back up LUKS headers.

# Exit on any error
set -e
# Uncomment for debugging
# set -x

# --- Configuration & Variables ---

# Default values for script options
DRY_RUN="no"
BACKUP_HEADERS="yes"  # Always backup headers for safety
DOWNLOAD_MODE="no"
PASSPHRASE=""

# Hardware information for key generation and metadata
MOTHERBOARD_ID=""
GATEWAY_MAC=""
DERIVED_KEY=""
KEY_GENERATION_TIME=""

# Locations
# Using a single temp directory for all transient files (keyfile, header backups)
TEMP_WORK_DIR="/tmp/luks_mgt_temp_$$" # $$ makes it unique per script run
KEYFILE="$TEMP_WORK_DIR/hardware_tied.key"
HEADER_BACKUP_DIR="$TEMP_WORK_DIR/header_backups"
# Final backup location - changes based on download mode
ZIPPED_HEADER_BACKUP_LOCATION="/boot/config/luksheaders"
DOWNLOAD_TEMP_DIR="/tmp/luksheaders"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# --- Functions ---

#
# Get LUKS version for a device
#
get_luks_version() {
    local device="$1"
    cryptsetup luksDump "$device" | grep 'Version:' | awk '{print $2}'
}

#
# Check if device supports tokens (LUKS2 only)
#
supports_tokens() {
    local device="$1"
    local version
    version=$(get_luks_version "$device")
    [[ "$version" == "2" ]]
}

#
# Parse JSON to extract unraid-derived token slots using awk for better JSON handling
#
extract_derived_slots() {
    local json_file="$1"
    
    # Use awk to properly parse the JSON structure
    awk '
    BEGIN { in_unraid_token = 0; collecting_slots = 0 }
    
    # Found unraid-derived token
    /"type"[[:space:]]*:[[:space:]]*"unraid-derived"/ {
        in_unraid_token = 1
        next
    }
    
    # If we are in an unraid-derived token
    in_unraid_token == 1 {
        # Look for keyslots line
        if (/"keyslots"[[:space:]]*:[[:space:]]*\[/) {
            # Extract slots from current line if they are all on one line
            if (/\]/) {
                # Single line format: "keyslots": ["3", "5"],
                gsub(/.*"keyslots"[^[]*\[/, "")
                gsub(/\].*/, "")
                gsub(/"/, "")
                gsub(/[[:space:]]/, "")
                split($0, slots, ",")
                for (i in slots) {
                    if (slots[i] ~ /^[0-9]+$/) print slots[i]
                }
            } else {
                collecting_slots = 1
            }
            next
        }
        
        # If collecting multi-line slots
        if (collecting_slots == 1) {
            if (/\]/) {
                collecting_slots = 0
            } else if (/"[0-9]+"/) {
                gsub(/"/, "")
                gsub(/[^0-9]/, "")
                if ($0 ~ /^[0-9]+$/) print $0
            }
            next
        }
        
        # End of token (closing brace with optional comma)
        if (/^[[:space:]]*}[[:space:]]*,?[[:space:]]*$/) {
            in_unraid_token = 0
            next
        }
    }
    ' "$json_file"
}

#
# Clean up old derived slots from LUKS device
#
cleanup_old_derived_slots() {
    local device="$1"
    local temp_token_file="/tmp/luks_tokens_$$.json"
    local cleaned_slots=0
    
    echo "  - Cleaning old derived slots..."
    
    # Only proceed if device supports tokens
    if ! supports_tokens "$device"; then
        echo "    LUKS1 device - no token cleanup needed"
        return 0
    fi
    
    # Export all tokens to temporary file
    if ! cryptsetup token export --token-id all "$device" > "$temp_token_file" 2>/dev/null; then
        echo "    No existing tokens found"
        rm -f "$temp_token_file"
        return 0
    fi
    
    # Extract slots from unraid-derived tokens
    local old_slots
    mapfile -t old_slots < <(extract_derived_slots "$temp_token_file")
    
    if [[ ${#old_slots[@]} -eq 0 ]]; then
        echo "    No old derived slots found"
        rm -f "$temp_token_file"
        return 0
    fi
    
    # Remove old slots and their tokens
    for slot in "${old_slots[@]}"; do
        if [[ "$DRY_RUN" == "yes" ]]; then
            echo "    [DRY RUN] Would remove slot $slot"
            cleaned_slots=$((cleaned_slots + 1))
        else
            if echo -n "$PASSPHRASE" | cryptsetup luksKillSlot "$device" "$slot" --key-file=- 2>/dev/null; then
                echo "    Removed old slot $slot"
                cleaned_slots=$((cleaned_slots + 1))
            else
                echo "    Warning: Could not remove slot $slot (may already be gone)"
            fi
        fi
    done
    
    # Remove all unraid-derived tokens
    if [[ "$DRY_RUN" != "yes" && $cleaned_slots -gt 0 ]]; then
        cryptsetup token remove --token-type unraid-derived "$device" 2>/dev/null || true
    fi
    
    rm -f "$temp_token_file"
    echo "    Cleaned $cleaned_slots old derived slot(s)"
    return 0
}

#
# Add token metadata for newly added slot
#
add_token_metadata() {
    local device="$1" 
    local new_slot="$2"
    local temp_token_file="/tmp/luks_token_$$.json"
    
    # Only add tokens for LUKS2 devices
    if ! supports_tokens "$device"; then
        echo "    LUKS1 device - skipping token metadata"
        return 0
    fi
    
    # Create token JSON structure
    cat > "$temp_token_file" << EOF
{
  "type": "unraid-derived",
  "keyslots": ["$new_slot"],
  "version": "1.0",
  "metadata": {
    "motherboard_id": "$MOTHERBOARD_ID",
    "gateway_mac": "$GATEWAY_MAC", 
    "generation_time": "$KEY_GENERATION_TIME",
    "key_hash": "sha256:$(echo -n "$DERIVED_KEY" | cut -c1-32)"
  }
}
EOF

    if [[ "$DRY_RUN" == "yes" ]]; then
        echo "    [DRY RUN] Would add token metadata for slot $new_slot"
    else
        if cryptsetup token import --token-id "$new_slot" "$device" < "$temp_token_file" 2>/dev/null; then
            echo "    Added token metadata for slot $new_slot"
        else
            echo "    Warning: Could not add token metadata (operation still successful)"
        fi
    fi
    
    rm -f "$temp_token_file"
}

#
# Get the slot number that was just used by luksAddKey
#
get_last_added_slot() {
    local device="$1"
    local dump_output
    
    # Get fresh dump after key addition
    dump_output=$(cryptsetup luksDump "$device")
    
    # For LUKS2, find the highest numbered slot that accepts our key
    if supports_tokens "$device"; then
        local slot
        for slot in {0..31}; do
            if echo -n "$DERIVED_KEY" | cryptsetup luksOpen --test-passphrase --key-slot "$slot" --key-file=- "$device" &>/dev/null; then
                echo "$slot"
                return 0
            fi
        done
    else
        # For LUKS1, check slots 0-7
        local slot
        for slot in {0..7}; do
            if echo -n "$DERIVED_KEY" | cryptsetup luksOpen --test-passphrase --key-slot "$slot" --key-file=- "$device" &>/dev/null; then
                echo "$slot"
                return 0
            fi
        done
    fi
    
    echo ""
    return 1
}

#
# Emergency rollback function - removes newly added slot if something goes wrong
#
rollback_slot_addition() {
    local device="$1"
    local slot="$2"
    
    echo "    ERROR: Rolling back slot $slot addition..."
    if echo -n "$PASSPHRASE" | cryptsetup luksKillSlot "$device" "$slot" --key-file=- 2>/dev/null; then
        echo "    Rollback successful - removed slot $slot"
    else
        echo "    Warning: Rollback failed - slot $slot may still exist"
    fi
}

#
# Enhanced device processing with better error handling
#
process_single_device() {
    local luks_device="$1"
    local dump_output
    
    echo
    echo "--- Processing device: $luks_device ---"

    # Get and display key slot info
    dump_output=$(cryptsetup luksDump "$luks_device")
    
    # Correctly determine used and total slots for LUKS1 and LUKS2
    local luks_version used_slots total_slots
    luks_version=$(echo "$dump_output" | grep 'Version:' | awk '{print $2}')
    if [[ "$luks_version" == "1" ]]; then
        used_slots=$(echo "$dump_output" | grep -c 'Key Slot [0-7]: ENABLED')
        total_slots=8
    else # Assuming LUKS2
        used_slots=$(echo "$dump_output" | grep -cE '^[[:space:]]+[0-9]+: luks2')
        total_slots=32
    fi
    echo "  - LUKS Version:     $luks_version"
    echo "  - Key Slots Used:   $used_slots / $total_slots"

    # 1. Check if the user-provided passphrase unlocks the device
    if ! echo -n "$PASSPHRASE" | cryptsetup luksOpen --test-passphrase --key-file=- "$luks_device" &>/dev/null; then
        echo "  - Passphrase Check: FAILED. Skipping this device."
        failed_devices+=("$luks_device: Invalid passphrase")
        return 1
    fi
    echo "  - Passphrase Check: OK"

    # 2. Perform header backup (always enabled for safety)
    local luks_uuid backup_file
    luks_uuid=$(echo "$dump_output" | grep UUID | awk '{print $2}')
    if [[ -z "$luks_uuid" ]]; then
        echo "  - Header Backup:    SKIPPED (Could not retrieve UUID)."
    else
        backup_file="${HEADER_BACKUP_DIR}/HEADER_UUID_${luks_uuid}_DEVICE_$(basename "$luks_device").img"
        if [[ "$DRY_RUN" == "yes" ]]; then
            echo "  - Header Backup:    [DRY RUN] Would be backed up."
            headers_found=$((headers_found + 1))
        else
            echo "  - Header Backup:    Backing up..."
            if echo -n "$PASSPHRASE" | cryptsetup luksHeaderBackup "$luks_device" --header-backup-file "$backup_file"; then
                echo "    ...Success."
                headers_found=$((headers_found + 1))
            else
                echo "    ...Error."
                failed_devices+=("$luks_device: Header backup failed")
                return 1
            fi
        fi
    fi

    # 3. Clean up old derived slots (LUKS2 only)
    if ! cleanup_old_derived_slots "$luks_device"; then
        echo "  - Cleanup:          Failed. Continuing anyway..."
    fi

    # 4. Check if current hardware key already exists
    if cryptsetup luksOpen --test-passphrase --key-file="$KEYFILE" "$luks_device" &>/dev/null; then
        echo "  - Current Hardware Key: Present. No addition needed."
        skipped_devices+=("$luks_device")
        return 0
    fi
    echo "  - Current Hardware Key: Not present."

    # 5. Add the new derived key
    if [[ "$DRY_RUN" == "yes" ]]; then
        echo "  - Key Addition:     [DRY RUN] Would be added."
        added_keys+=("$luks_device")
        return 0
    fi
    
    echo "  - Key Addition:     Adding key..."
    if echo -n "$PASSPHRASE" | cryptsetup luksAddKey "$luks_device" "$KEYFILE" --key-file=-; then
        echo "    ...Success."
        
        # 6. Add token metadata for the new slot
        local new_slot
        new_slot=$(get_last_added_slot "$luks_device")
        if [[ -n "$new_slot" ]]; then
            if ! add_token_metadata "$luks_device" "$new_slot"; then
                echo "    Warning: Token metadata failed but key addition successful"
            fi
        else
            echo "    Warning: Could not determine new slot number"
        fi
        
        added_keys+=("$luks_device")
        return 0
    else
        echo "    ...Error."
        failed_devices+=("$luks_device: luksAddKey command failed")
        return 1
    fi
}

#
# Display script usage information and exit
#
usage() {
    echo "Usage: This script is intended to be called from the plugin UI."
    echo "Flags: [-d] [-b]"
    exit 1
}

#
# Custom argument parser for the Unraid Plugin environment
#
parse_args() {
    # Read the passphrase securely from an environment variable.
    if [[ -n "$LUKS_PASSPHRASE" ]]; then
        PASSPHRASE="$LUKS_PASSPHRASE"
    else
        echo "Error: Passphrase not found in environment variable."
        usage
    fi

    # Always enable header backup for safety
    echo "Header backup enabled (always on for safety)."
    
    # Process command-line flags (-d, --download-mode)
    for arg in "$@"; do
        case "$arg" in
            -d)
                DRY_RUN="yes"
                echo "Dry run mode enabled."
                ;;
            --download-mode)
                DOWNLOAD_MODE="yes"
                ZIPPED_HEADER_BACKUP_LOCATION="$DOWNLOAD_TEMP_DIR"
                echo "Download mode enabled - backups will be prepared for browser download."
                ;;
        esac
    done
}

#
# Get Motherboard Serial Number
#
get_motherboard_id() {
    dmidecode -s baseboard-serial-number
}

#
# Get MAC address of the default gateway. Handles multiple gateways.
#
get_gateway_mac() {
    local interface gateway_ip mac_address
    # Read all default routes into an array
    mapfile -t routes < <(ip route show default | awk '/default/ {print $5 " " $3}')

    if [[ ${#routes[@]} -eq 0 ]]; then
        echo "Error: No default gateway found." >&2
        return 1
    fi

    for route in "${routes[@]}"; do
        interface=$(echo "$route" | awk '{print $1}')
        gateway_ip=$(echo "$route" | awk '{print $2}')
        # Use arping to find the MAC address for the gateway IP on the correct interface
        mac_address=$(arping -c 1 -I "$interface" "$gateway_ip" 2>/dev/null | grep "reply from" | awk '{print $5}' | tr -d '[]')
        if [[ -n "$mac_address" ]]; then
            echo "$mac_address"
            return 0 # Success
        fi
    done

    echo "Error: Unable to retrieve MAC address of the default gateway." >&2
    return 1
}

#
# Generate a keyfile based on hardware identifiers
#
generate_keyfile() {
    echo "Generating hardware-tied key..."
    
    # Store generation time
    KEY_GENERATION_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')

    MOTHERBOARD_ID=$(get_motherboard_id)
    if [[ -z "$MOTHERBOARD_ID" ]]; then
        echo "Error: Could not retrieve motherboard serial number." >&2
        exit 1
    fi

    GATEWAY_MAC=$(get_gateway_mac)
    if [[ -z "$GATEWAY_MAC" ]]; then
        echo "Error: Could not retrieve gateway MAC address." >&2
        exit 1
    fi

    # Combine hardware IDs and hash them to create the key
    DERIVED_KEY=$(echo -n "${MOTHERBOARD_ID}_${GATEWAY_MAC}" | sha256sum | awk '{print $1}')

    # Create the keyfile
    mkdir -p "$(dirname "$KEYFILE")"
    echo -n "$DERIVED_KEY" > "$KEYFILE"
    echo "Keyfile generated successfully at $KEYFILE"
}

#
# Create a hardware key metadata file with all relevant information
#
# Create enhanced metadata file with hardware key info and encryption analysis
#
create_enhanced_metadata() {
    local metadata_file="$1"
    
    echo "Creating enhanced metadata file with encryption analysis: $metadata_file"
    
    cat > "$metadata_file" << EOF
===============================================
LUKS Hardware-Derived Key & Encryption Analysis
===============================================

Generated: $KEY_GENERATION_TIME
Plugin: LUKS Key Management for Unraid
Version: Generated by luks_management.sh

HARDWARE IDENTIFIERS:
- Motherboard Serial: $MOTHERBOARD_ID
- Gateway MAC Address: $GATEWAY_MAC

DERIVED KEY:
$DERIVED_KEY

KEY GENERATION METHOD:
The hardware key is generated by combining the motherboard serial number
and default gateway MAC address, then creating a SHA256 hash:
  Input: ${MOTHERBOARD_ID}_${GATEWAY_MAC}
  SHA256: $DERIVED_KEY

SECURITY NOTES:
- This key is tied to your specific hardware configuration
- If you change your motherboard or router, this key will no longer work
- Keep this file secure alongside your LUKS header backups
- The original LUKS passphrase is still valid and should be kept safe

USAGE:
This key can be used to unlock LUKS-encrypted devices on this system
using the cryptsetup command or during boot via the auto-unlock feature.

EOF

    # Add current encryption analysis
    echo "" >> "$metadata_file"
    echo "CURRENT ENCRYPTION ANALYSIS:" >> "$metadata_file"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$metadata_file"
    echo "Analysis Mode: Detailed" >> "$metadata_file"
    echo "" >> "$metadata_file"
    
    # Call the encryption info viewer script to append analysis
    local info_script="/usr/local/emhttp/plugins/luks-key-management/scripts/luks_info_viewer.sh"
    if [[ -f "$info_script" ]]; then
        # Run encryption analysis and append to metadata file
        LUKS_PASSPHRASE="$PASSPHRASE" "$info_script" -d detailed >> "$metadata_file" 2>/dev/null || {
            echo "Warning: Could not generate encryption analysis" >> "$metadata_file"
        }
    else
        echo "Warning: Encryption analysis script not found" >> "$metadata_file"
    fi
    
    echo "" >> "$metadata_file"
    echo "===============================================" >> "$metadata_file"
    echo "Generated by LUKS Key Management Plugin" >> "$metadata_file"
    
    echo "Enhanced metadata with encryption analysis saved to: $metadata_file"
}

#
# Get a list of all LUKS-encrypted block devices
#
get_luks_devices() {
    # Reverted to the user's original, proven method for finding LUKS devices.
    lsblk --noheadings --pairs --output NAME,TYPE | grep 'TYPE="crypt"' | awk -F'"' '{print "/dev/" $2}'
}

#
# Classify disks into Array, Pool, and Standalone categories (Unraid specific)
#
# Note: This classification is for reporting purposes only.
#
classify_disks() {
    echo "Classifying disks for summary report..."
    # Ensure arrays are clean before populating
    array_disks=()
    pool_disks=()
    standalone_disks=()

    # --- Logic for GUI-managed pools (BTRFS/XFS/ZFS) ---
    declare -A all_pool_disk_ids
    for pool_cfg in /boot/config/pools/*.cfg; do
        [[ -f "$pool_cfg" ]] || continue
        local pool_name
        pool_name=$(basename "$pool_cfg" .cfg)
        
        # Read the config file line by line for robustness
        while IFS= read -r line; do
            # Match lines like diskId="..." or diskId.1="..." and extract the ID
            if [[ "$line" =~ diskId(\.[0-9]+)?=\"([^\"]+)\" ]]; then
                local disk_serial="${BASH_REMATCH[2]}"
                if [[ -n "$disk_serial" ]]; then
                    all_pool_disk_ids["$disk_serial"]=$pool_name
                fi
            fi
        done < "$pool_cfg"
    done

    # --- Map device paths to pool names ---
    declare -A device_to_pool
    for device in /dev/nvme* /dev/sd*; do
        [[ -b "$device" ]] || continue
        local disk_id
        # Get the serial number for the device
        disk_id=$(udevadm info --query=all --name="$device" 2>/dev/null | grep "ID_SERIAL=" | awk -F= '{print $2}')
        
        # Check if this serial number is in our list of pool disk IDs
        if [[ -n "$disk_id" && -n "${all_pool_disk_ids[$disk_id]}" ]]; then
            device_to_pool["$device"]=${all_pool_disk_ids[$disk_id]}
        fi
    done

    # --- Final Classification Logic ---
    for device in $(get_luks_devices); do
        # First, check if the LUKS device itself is an array device. This is the most reliable check.
        if [[ "$device" == "/dev/md"* ]]; then
            array_disks+=("$device (Array Device)")
            continue # Classification is done, move to the next device.
        fi

        # If not an array device, find its parent physical disk for pool classification.
        local physical_device_name=$(lsblk -no pkname "$device" | head -n 1)

        # If we can't find a parent, classify as standalone with an unknown parent.
        if [[ -z "$physical_device_name" ]]; then
             standalone_disks+=("$device (Underlying Device: Unknown)")
             continue
        fi
        
        local physical_device="/dev/$physical_device_name"

        # Check if the parent physical device is in a known pool.
        if [[ -n "${device_to_pool[$physical_device]}" ]]; then
            pool_disks+=("$device (Pool Device: $physical_device, Pool: ${device_to_pool[$physical_device]})")
        else
            # If not in the array and not in a pool, it's a standalone device.
            standalone_disks+=("$device (Underlying Device: $physical_device)")
        fi
    done
}

#
# Process each LUKS device: cleanup old slots, backup header, and add key
#
process_devices() {
    echo
    echo "--- Starting LUKS Device Processing ---"

    # Initialize result arrays
    added_keys=()
    skipped_devices=()
    failed_devices=()
    headers_found=0

    # Prepare for header backups if requested
    if [[ "$BACKUP_HEADERS" == "yes" ]]; then
        mkdir -p "$HEADER_BACKUP_DIR"
    fi

    for luks_device in $(get_luks_devices); do
        process_single_device "$luks_device"
    done
    
    # 5. Create the final encrypted archive if headers were backed up
    if [[ "$BACKUP_HEADERS" == "yes" && $headers_found -gt 0 ]]; then
        echo
        local final_backup_file="${ZIPPED_HEADER_BACKUP_LOCATION}/luksheaders_${TIMESTAMP}.zip"
        local metadata_file="${HEADER_BACKUP_DIR}/luks_system_analysis_${TIMESTAMP}.txt"
        
        if [[ "$DRY_RUN" == "yes" ]]; then
            echo "Dry Run: Final encrypted archive of $headers_found headers would be created at $final_backup_file"
            echo "Dry Run: Enhanced metadata with encryption analysis would be created and included"
        else
            # Create the enhanced metadata file with encryption analysis
            create_enhanced_metadata "$metadata_file"
            
            echo "Creating encrypted zip archive of $headers_found headers plus system analysis..."
            mkdir -p "$ZIPPED_HEADER_BACKUP_LOCATION"
            
            # Create archive with header backups and enhanced metadata
            zip -j --password "$PASSPHRASE" "$final_backup_file" "$HEADER_BACKUP_DIR"/*.img "$metadata_file"
            if [[ $? -eq 0 ]]; then
                echo "Final encrypted archive created at $final_backup_file"
                echo "Archive includes LUKS headers and comprehensive system analysis"
            else
                echo "Error: Failed to create the encrypted archive."
            fi
        fi
    else
        echo
        echo "No headers were backed up for the provided passphrase, skipping zip archive creation."
    fi
}

#
# Generate and display a final summary of all operations
#
generate_summary() {
    local total_devices
    total_devices=$(get_luks_devices | wc -l)
    
    local mode_string
    if [[ "$DRY_RUN" == "yes" ]]; then
        mode_string="Dry Run"
    else
        mode_string="Live Run"
    fi

    echo
    echo "================================================="
    echo "---           LUKS Management Summary         ---"
    echo "================================================="
    echo "Mode: $mode_string"
    echo "Timestamp: $TIMESTAMP"
    echo "Total LUKS devices found: $total_devices"
    echo

    echo "--- Disk Classification ---"
    echo "Array Disks:"
    if [ ${#array_disks[@]} -gt 0 ]; then
        for disk in "${array_disks[@]}"; do echo "  - $disk"; done
    else
        echo "  - None"
    fi
    echo
    echo "Pool Disks:"
    if [ ${#pool_disks[@]} -gt 0 ]; then
        for disk in "${pool_disks[@]}"; do echo "  - $disk"; done
    else
        echo "  - None"
    fi
    echo
    echo "Standalone Disks:"
    if [ ${#standalone_disks[@]} -gt 0 ]; then
        for disk in "${standalone_disks[@]}"; do echo "  - $disk"; done
    else
        echo "  - None"
    fi
    echo

    echo "--- Hardware Key Management Results ---"
    if [[ "$DRY_RUN" == "yes" ]]; then
        echo "Hardware keys WOULD HAVE BEEN REFRESHED on (${#added_keys[@]}) devices:"
    else
        echo "Hardware keys SUCCESSFULLY REFRESHED on (${#added_keys[@]}) devices:"
    fi
    if [ ${#added_keys[@]} -gt 0 ]; then
        for disk in "${added_keys[@]}"; do echo "  - $disk"; done
    else
        echo "  - None"
    fi
    echo

    echo "Devices SKIPPED (current hardware key already present) (${#skipped_devices[@]}):"
    if [ ${#skipped_devices[@]} -gt 0 ]; then
        for disk in "${skipped_devices[@]}"; do echo "  - $disk"; done
    else
        echo "  - None"
    fi
    echo

    echo "FAILED operations on (${#failed_devices[@]}) devices:"
    if [ ${#failed_devices[@]} -gt 0 ]; then
        for disk in "${failed_devices[@]}"; do echo "  - $disk"; done
    else
        echo "  - None"
    fi
    echo

    if [[ "$BACKUP_HEADERS" == "yes" ]]; then
        echo "--- Header Backup ---"
        if [[ "$DRY_RUN" == "yes" ]]; then
             echo "Header backup was simulated."
        else
             echo "Header backup process was run. Check logs for details."
        fi
        echo
    fi
    echo "================================================="
    echo "---                 End Summary               ---"
    echo "================================================="
}

#
# Clean up temporary files and directories
#
cleanup() {
    if [[ -d "$TEMP_WORK_DIR" ]]; then
        echo "Cleaning up temporary directory: $TEMP_WORK_DIR"
        rm -rf "$TEMP_WORK_DIR"
    fi
}

# --- Main Script Execution ---

# Ensure cleanup runs on script exit, including on error
trap cleanup EXIT

# Step 1: Parse command-line arguments.
parse_args "$@"

# Step 2: Generate the dynamic, hardware-tied keyfile
generate_keyfile

# Step 3: Classify disks for the final report
classify_disks

# Step 4: Process all devices (backup headers and add keys)
process_devices

# Step 5: Display a comprehensive summary of what happened
generate_summary

# Step 6: Auto-enable auto-unlock by adding to go file (unless dry run)
if [[ "$DRY_RUN" == "no" ]]; then
    echo ""
    echo "--- Auto-Enabling Boot Unlock ---"
    echo "Adding auto-unlock configuration to go file..."
    
    # Call the write_go.sh script to add auto-unlock
    GO_SCRIPT_PATH="/usr/local/emhttp/plugins/luks-key-management/scripts/write_go.sh"
    if [[ -f "$GO_SCRIPT_PATH" ]]; then
        if "$GO_SCRIPT_PATH" add; then
            echo "Auto-unlock successfully enabled in go file."
        else
            echo "Warning: Failed to add auto-unlock to go file. You may need to enable it manually."
        fi
    else
        echo "Warning: Go file script not found. Auto-unlock not enabled."
    fi
else
    echo ""
    echo "--- Dry Run: Auto-unlock Configuration Skipped ---"
    echo "In live mode, auto-unlock would be automatically enabled in go file."
fi

echo "Script finished."
