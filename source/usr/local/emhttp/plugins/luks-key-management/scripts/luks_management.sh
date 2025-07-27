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
KEY_TYPE=""
KEYFILE_PATH=""
ZIP_ENCRYPTION_TYPE=""  # Track original input type for ZIP encryption decisions
CUSTOM_ZIP_PASSWORD=""  # Custom ZIP password for keyfile users

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
# Validate hardware fingerprint components (fail fast if hardware detection fails)
#
validate_hardware_fingerprint() {
    if [[ -z "$MOTHERBOARD_ID" ]] || [[ -z "$GATEWAY_MAC" ]]; then
        echo "ERROR: Cannot detect hardware fingerprint"
        echo "  Motherboard ID: '$MOTHERBOARD_ID'"
        echo "  Gateway MAC: '$GATEWAY_MAC'"
        echo "Hardware-based auto-unlock not possible on this system."
        return 1
    fi
    echo "Hardware fingerprint detected successfully:"
    echo "  Motherboard ID: $MOTHERBOARD_ID"
    echo "  Gateway MAC: $GATEWAY_MAC"
    return 0
}

#
# Test encryption key (passphrase or keyfile) against a LUKS device
#
test_encryption_key() {
    local device="$1"
    
    if [[ "$KEY_TYPE" == "passphrase" ]]; then
        echo "$PASSPHRASE" | cryptsetup luksOpen --test-passphrase "$device" --stdin 2>/dev/null
    elif [[ "$KEY_TYPE" == "keyfile" ]]; then
        cryptsetup luksOpen --test-passphrase --key-file="$KEYFILE_PATH" "$device" 2>/dev/null
    else
        echo "Error: Unknown key type '$KEY_TYPE'" >&2
        return 1
    fi
}

#
# Remove a LUKS slot using the appropriate authentication method
#
remove_slot_with_key() {
    local device="$1"
    local slot="$2"
    
    if [[ "$KEY_TYPE" == "passphrase" ]]; then
        echo "$PASSPHRASE" | cryptsetup luksKillSlot "$device" "$slot" --stdin 2>/dev/null
    elif [[ "$KEY_TYPE" == "keyfile" ]]; then
        cryptsetup luksKillSlot "$device" "$slot" --key-file="$KEYFILE_PATH" 2>/dev/null
    else
        echo "Error: Unknown key type '$KEY_TYPE'" >&2
        return 1
    fi
}

#
# Create LUKS header backup using the appropriate authentication method
#
create_header_backup() {
    local device="$1"
    local backup_file="$2"
    
    if [[ "$KEY_TYPE" == "passphrase" ]]; then
        echo "$PASSPHRASE" | cryptsetup luksHeaderBackup "$device" --header-backup-file "$backup_file" --stdin 2>/dev/null
    elif [[ "$KEY_TYPE" == "keyfile" ]]; then
        cryptsetup luksHeaderBackup "$device" --header-backup-file "$backup_file" --key-file="$KEYFILE_PATH" 2>/dev/null
    else
        echo "Error: Unknown key type '$KEY_TYPE'" >&2
        return 1
    fi
}

#
# Add hardware key using the appropriate authentication method
#
add_hardware_key_with_auth() {
    local device="$1"
    local keyfile="$2"
    
    if [[ "$KEY_TYPE" == "passphrase" ]]; then
        echo "$PASSPHRASE" | cryptsetup luksAddKey "$device" "$keyfile" --stdin 2>/dev/null
    elif [[ "$KEY_TYPE" == "keyfile" ]]; then
        cryptsetup luksAddKey "$device" "$keyfile" --key-file="$KEYFILE_PATH" 2>/dev/null
    else
        echo "Error: Unknown key type '$KEY_TYPE'" >&2
        return 1
    fi
}

#
# Create encrypted archive using the user's LUKS passphrase for ZIP encryption
# This ensures the user can decrypt the backup using their known LUKS passphrase
#
create_encrypted_archive() {
    local archive_file="$1"
    local source_dir="$2"
    local metadata_file="$3"
    
    # Use ZIP_ENCRYPTION_TYPE if available, otherwise fall back to KEY_TYPE
    local zip_type="${ZIP_ENCRYPTION_TYPE:-$KEY_TYPE}"
    echo "DEBUG: ZIP encryption decision based on: $zip_type"
    
    if [[ "$zip_type" == "passphrase" ]]; then
        # Use the user's LUKS passphrase for ZIP encryption
        echo "DEBUG: Creating password-protected ZIP with user's passphrase"
        zip -j --password "$PASSPHRASE" "$archive_file" "$source_dir"/*.img "$metadata_file"
    else
        # For keyfile users, check if custom ZIP password was provided
        if [[ -n "$CUSTOM_ZIP_PASSWORD" ]]; then
            echo "DEBUG: Creating password-protected ZIP with custom password"
            zip -j --password "$CUSTOM_ZIP_PASSWORD" "$archive_file" "$source_dir"/*.img "$metadata_file"
        else
            # Fallback: create unencrypted archive (shouldn't happen with new UI)
            echo "Creating unencrypted archive (no ZIP password provided)..."
            zip -j "$archive_file" "$source_dir"/*.img "$metadata_file"
        fi
    fi
}

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
# Find all unraid-derived slots using proven luksDump + token export method
# Enhanced with comprehensive debugging and error handling
#
find_unraid_derived_slots() {
    local device="$1"
    local found_slots=()
    
    echo "    DEBUG: Starting unraid-derived slot detection for $device" >&2
    
    # Only works with LUKS2
    local luks_version=$(get_luks_version "$device")
    echo "    DEBUG: LUKS version detected: $luks_version" >&2
    if [[ "$luks_version" != "2" ]]; then
        echo "    DEBUG: LUKS1 device - no token support, returning empty" >&2
        return 0  # No slots found for LUKS1
    fi
    
    # Get luksDump output and extract tokens section
    local dump_info=$(cryptsetup luksDump "$device" 2>/dev/null)
    if [[ -z "$dump_info" ]]; then
        echo "    DEBUG: ERROR - luksDump returned empty output" >&2
        return 1
    fi
    
    # Check if tokens section exists
    if ! echo "$dump_info" | grep -q "^Tokens:"; then
        echo "    DEBUG: No Tokens section found in luksDump output" >&2
        return 0
    fi
    
    local tokens_section=$(echo "$dump_info" | awk '/^Tokens:$/,/^Digests:$/' | grep -v "^Tokens:$" | grep -v "^Digests:$")
    echo "    DEBUG: Tokens section extracted ($(echo "$tokens_section" | wc -l) lines)" >&2
    echo "    DEBUG: Raw tokens section: '$tokens_section'" >&2
    
    # Check if tokens section is truly empty (no content or just whitespace)
    local cleaned_tokens=$(echo "$tokens_section" | sed 's/^[[:space:]]*$//' | grep -v '^$')
    if [[ -z "$cleaned_tokens" ]]; then
        echo "    DEBUG: Tokens section is empty - no tokens configured" >&2
        return 0
    fi
    echo "    DEBUG: Non-empty tokens found, proceeding with token analysis" >&2
    
    # Enhanced parsing with better debugging
    local token_id=""
    local current_token_id=""
    local line_count=0
    
    while IFS= read -r line; do
        line_count=$((line_count + 1))
        [[ -z "$line" ]] && continue  # Skip empty lines
        
        # Debug each line being processed
        echo "    DEBUG: Processing line $line_count: '$line'" >&2
        
        # Match token ID lines: "  0: some_type"
        if [[ "$line" =~ ^[[:space:]]*([0-9]+):[[:space:]]*(.*) ]]; then
            current_token_id="${BASH_REMATCH[1]}"
            local token_type_display="${BASH_REMATCH[2]}"
            echo "    DEBUG: Found token ID $current_token_id, type: '$token_type_display'" >&2
            
        # Match keyslot lines: "    Keyslot: 3"
        elif [[ "$line" =~ ^[[:space:]]*Keyslot:[[:space:]]*([0-9]+) ]]; then
            local keyslot_num="${BASH_REMATCH[1]}"
            echo "    DEBUG: Found keyslot $keyslot_num for token $current_token_id" >&2
            
            if [[ -n "$current_token_id" ]]; then
                # Export this token to check if it's unraid-derived
                echo "    DEBUG: Exporting token $current_token_id for verification..." >&2
                local token_json=$(cryptsetup token export --token-id "$current_token_id" "$device" 2>/dev/null)
                
                if [[ -n "$token_json" ]]; then
                    echo "    DEBUG: Token JSON retrieved successfully" >&2
                    local token_type_check=$(echo "$token_json" | grep -o '"type":"[^"]*"' | cut -d'"' -f4)
                    echo "    DEBUG: Token type from JSON: '$token_type_check'" >&2
                    
                    if [[ "$token_type_check" == "unraid-derived" ]]; then
                        echo "    DEBUG: ✅ Found unraid-derived slot: $keyslot_num" >&2
                        found_slots+=("$keyslot_num")
                    else
                        echo "    DEBUG: ❌ Token type '$token_type_check' != 'unraid-derived'" >&2
                    fi
                else
                    echo "    DEBUG: ERROR - Token export failed for token $current_token_id" >&2
                fi
            else
                echo "    DEBUG: ERROR - No current_token_id set for keyslot $keyslot_num" >&2
            fi
        else
            echo "    DEBUG: Line doesn't match expected patterns: '$line'" >&2
        fi
    done <<< "$tokens_section"
    
    echo "    DEBUG: Final result - found ${#found_slots[@]} unraid-derived slots: ${found_slots[*]}" >&2
    
    # Output found slots (one per line)
    printf '%s\n' "${found_slots[@]}"
}

#
# Remove all unraid-derived slots from LUKS device (used when hardware changes)
# Uses our proven token detection method for reliability
#
remove_unraid_derived_slots() {
    local device="$1"
    local cleaned_slots=0
    
    # Find all unraid-derived slots using our proven method
    local old_slots
    echo "    DEBUG: About to call find_unraid_derived_slots..."
    mapfile -t old_slots < <(find_unraid_derived_slots "$device")
    echo "    DEBUG: mapfile completed, captured ${#old_slots[@]} elements"
    echo "    DEBUG: Raw captured elements: '${old_slots[*]}'"
    
    # Debug each captured element
    local i=0
    for slot in "${old_slots[@]}"; do
        echo "    DEBUG: Element $i: '$slot'"
        i=$((i + 1))
    done
    
    if [[ ${#old_slots[@]} -eq 0 ]]; then
        echo "    No unraid-derived slots found"
        return 0
    fi
    
    echo "    Found unraid-derived slots: ${old_slots[*]}"
    
    # CRITICAL SAFEGUARD: Count total active slots and ensure we don't remove all keys
    local dump_output=$(cryptsetup luksDump "$device" 2>/dev/null)
    local luks_version=$(echo "$dump_output" | grep 'Version:' | awk '{print $2}')
    local total_active_slots
    
    if [[ "$luks_version" == "1" ]]; then
        total_active_slots=$(echo "$dump_output" | grep -c 'Key Slot [0-7]: ENABLED')
    else
        total_active_slots=$(echo "$dump_output" | grep -cE '^[[:space:]]+[0-9]+: luks2')
    fi
    
    echo "    DEBUG: Total active slots on device: $total_active_slots"
    echo "    DEBUG: Unraid-derived slots to remove: ${#old_slots[@]}"
    
    # Calculate slots that would remain after removal (excluding slot 0 protection)
    local slots_to_remove=0
    for slot in "${old_slots[@]}"; do
        if [[ "$slot" != "0" ]]; then
            slots_to_remove=$((slots_to_remove + 1))
        fi
    done
    
    local remaining_slots=$((total_active_slots - slots_to_remove))
    echo "    DEBUG: Slots remaining after removal: $remaining_slots"
    
    if [[ $remaining_slots -lt 1 ]]; then
        echo "    ERROR: SAFETY ABORT - Removing these slots would leave NO working keys!"
        echo "    ERROR: This would cause complete lockout. Skipping slot removal."
        return 1
    fi
    
    if [[ $remaining_slots -eq 1 ]]; then
        echo "    WARNING: After removal, only 1 slot will remain. Proceeding with caution..."
    fi
    
    # Remove old slots one by one (more robust than batch removal)
    for slot in "${old_slots[@]}"; do
        # CRITICAL PROTECTION: Never remove slot 0 (original passphrase)
        if [[ "$slot" == "0" ]]; then
            echo "    PROTECTION: Skipping slot 0 (original passphrase) - never removed"
            continue
        fi
        
        if [[ "$DRY_RUN" == "yes" ]]; then
            echo "    [DRY RUN] Would remove slot $slot"
            cleaned_slots=$((cleaned_slots + 1))
        else
            if remove_slot_with_key "$device" "$slot"; then
                echo "    ✅ Removed old hardware key from slot $slot"
                cleaned_slots=$((cleaned_slots + 1))
            else
                echo "    ERROR: Failed to remove old hardware key from slot $slot, but continuing..."
            fi
        fi
    done
    
    echo "    Cleaned $cleaned_slots old derived slot(s)"
    return 0
}

#
# Add secure token metadata for newly added slot
# Only stores safe information that cannot be used to regenerate the key
#
add_secure_token_metadata() {
    local device="$1" 
    local new_slot="$2"
    local temp_token_file="/tmp/luks_token_$$.json"
    
    # Only add tokens for LUKS2 devices
    if ! supports_tokens "$device"; then
        echo "    LUKS1 device - skipping token metadata"
        return 0
    fi
    
    # Create secure token JSON structure - NO SENSITIVE DATA
    cat > "$temp_token_file" << EOF
{
  "type": "unraid-derived",
  "keyslots": ["$new_slot"],
  "version": "1.0",
  "metadata": {
    "generation_time": "$KEY_GENERATION_TIME"
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

    # 1. Check if the user-provided encryption key unlocks the device
    if ! test_encryption_key "$luks_device"; then
        echo "  - Encryption Key Check: FAILED. Skipping this device."
        if [[ "$KEY_TYPE" == "passphrase" ]]; then
            failed_devices+=("$luks_device: Invalid passphrase")
        else
            failed_devices+=("$luks_device: Invalid keyfile")
        fi
        return 1
    fi
    echo "  - Encryption Key Check: OK"

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
            if create_header_backup "$luks_device" "$backup_file"; then
                echo "    ...Success."
                headers_found=$((headers_found + 1))
            else
                echo "    ...Error."
                failed_devices+=("$luks_device: Header backup failed")
                return 1
            fi
        fi
    fi

    # 3. Secure Hardware Key Management
    echo "  - Hardware Key Check: Testing if current hardware key works..."
    
    # Step 1: Test if current hardware key can unlock the device
    if cryptsetup luksOpen --test-passphrase --key-file="$KEYFILE" "$luks_device" &>/dev/null; then
        echo "    ✅ Current hardware key works - no changes needed"
        skipped_devices+=("$luks_device")
        return 0
    fi
    
    # Step 2: Hardware key doesn't work - hardware must have changed
    echo "    ❌ Current hardware key doesn't work - hardware likely changed"
    echo "  - Slot Cleanup:     Removing old hardware-derived keys..."
    
    # Step 3: Remove all unraid-derived slots using proven method
    if ! remove_unraid_derived_slots "$luks_device"; then
        echo "    Warning: Slot cleanup had issues, but continuing..."
    fi

    # Step 4: Add new hardware key with retry logic
    echo "  - Key Addition:     Adding new hardware key..."
    
    if [[ "$DRY_RUN" == "yes" ]]; then
        echo "    [DRY RUN] Would add new hardware key"
        added_keys+=("$luks_device")
        return 0
    fi
    
    # Try adding the key with retry logic (attempt 1/2)
    local success=0
    for attempt in 1 2; do
        if add_hardware_key_with_auth "$luks_device" "$KEYFILE"; then
            echo "    ✅ Added new hardware key for current hardware"
            success=1
            break
        else
            echo "    ERROR: Failed to add new hardware key (attempt $attempt/2)"
            if [[ $attempt -eq 2 ]]; then
                echo "    FATAL: Could not add hardware key after 2 attempts. Device will not auto-unlock."
                failed_devices+=("$luks_device: Failed to add hardware key after 2 attempts")
                return 1
            fi
        fi
    done
    
    # Step 5: Add secure token metadata for the new slot
    if [[ $success -eq 1 ]]; then
        local new_slot
        new_slot=$(get_last_added_slot "$luks_device")
        if [[ -n "$new_slot" ]]; then
            if ! add_secure_token_metadata "$luks_device" "$new_slot"; then
                echo "    Warning: Token metadata failed but key addition successful"
            fi
        else
            echo "    Warning: Could not determine new slot number"
        fi
        
        added_keys+=("$luks_device")
        return 0
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
    # Read the encryption key securely from environment variables
    if [[ -n "$LUKS_PASSPHRASE" ]]; then
        PASSPHRASE="$LUKS_PASSPHRASE"
        KEY_TYPE="passphrase"
    elif [[ -n "$LUKS_KEYFILE" ]]; then
        KEYFILE_PATH="$LUKS_KEYFILE"
        KEY_TYPE="keyfile"  # Always use keyfile method for LUKS operations
        
        # Check if we have original input type (for ZIP encryption decisions only)
        if [[ -n "$LUKS_ORIGINAL_INPUT_TYPE" ]]; then
            ZIP_ENCRYPTION_TYPE="$LUKS_ORIGINAL_INPUT_TYPE"
            echo "DEBUG: Original input type for ZIP encryption: $ZIP_ENCRYPTION_TYPE"
            # For passphrase users, read the passphrase from the temp file for ZIP encryption
            if [[ "$ZIP_ENCRYPTION_TYPE" == "passphrase" ]]; then
                PASSPHRASE=$(cat "$KEYFILE_PATH")
                echo "DEBUG: Read passphrase from temp file for ZIP encryption"
            fi
        else
            ZIP_ENCRYPTION_TYPE="keyfile"
        fi
        
        # Check for custom ZIP password from environment variable
        if [[ -n "$LUKS_ZIP_PASSWORD" ]]; then
            CUSTOM_ZIP_PASSWORD="$LUKS_ZIP_PASSWORD"
            echo "DEBUG: Custom ZIP password received from PHP"
        fi
        
        # Validate keyfile exists and is readable
        if [[ ! -f "$KEYFILE_PATH" ]]; then
            echo "Error: Keyfile not found at $KEYFILE_PATH" >&2
            exit 1
        fi
        if [[ ! -r "$KEYFILE_PATH" ]]; then
            echo "Error: Keyfile not readable at $KEYFILE_PATH" >&2
            exit 1
        fi
    else
        echo "Error: No encryption key found. Provide LUKS_PASSPHRASE or LUKS_KEYFILE environment variable." >&2
        exit 1
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

    # Collect hardware identifiers
    MOTHERBOARD_ID=$(get_motherboard_id)
    GATEWAY_MAC=$(get_gateway_mac)
    
    # Step 1: Validate hardware fingerprint (fail fast with clear messaging)
    if ! validate_hardware_fingerprint; then
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
        if [[ "$KEY_TYPE" == "passphrase" ]]; then
            LUKS_PASSPHRASE="$PASSPHRASE" "$info_script" -d detailed >> "$metadata_file" 2>/dev/null || {
                echo "Warning: Could not generate encryption analysis" >> "$metadata_file"
            }
        elif [[ "$KEY_TYPE" == "keyfile" ]]; then
            LUKS_KEYFILE="$KEYFILE_PATH" "$info_script" -d detailed >> "$metadata_file" 2>/dev/null || {
                echo "Warning: Could not generate encryption analysis" >> "$metadata_file"
            }
        else
            echo "Warning: Could not generate encryption analysis" >> "$metadata_file"
        fi
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
            create_encrypted_archive "$final_backup_file" "$HEADER_BACKUP_DIR" "$metadata_file"
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
