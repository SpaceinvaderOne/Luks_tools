#!/bin/bash
#
# Description: Encrypt drives with a hardware-tied key and manage LUKS headers.
# This script generates a dynamic key based on hardware identifiers (motherboard
# serial and default gateway MAC address) and adds it as a valid key to all
# LUKS-encrypted devices. It also provides functionality to back up LUKS headers.
#
# Unraid User Script Header:
# description=Encrypt drives with a hardware-tied key and manage LUKS headers
# foregroundOnly=true
# arrayStarted=true
# name=LUKS Key Management
# clearLog=true
# argumentDescription=Use flags: -p <pass> -d (dry-run) -b (backup headers). Quote passwords with special characters!
# argumentDefault=-p 'YOUR_PASSWORD_HERE' -d

# Exit on any error
set -e
# Uncomment for debugging
# set -x

# --- Configuration & Variables ---

# Default values for script options
DRY_RUN="no"
BACKUP_HEADERS="no"
PASSPHRASE=""

# Locations
# Using a single temp directory for all transient files (keyfile, header backups)
TEMP_WORK_DIR="/tmp/luks_mgt_temp_$$" # $$ makes it unique per script run
KEYFILE="$TEMP_WORK_DIR/hardware_tied.key"
HEADER_BACKUP_DIR="$TEMP_WORK_DIR/header_backups"
# Final backup location on the boot flash drive
ZIPPED_HEADER_BACKUP_LOCATION="/boot/config/luksheaders"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# --- Functions ---

#
# Display script usage information and exit
#
usage() {
    echo "Usage: In the User Scripts GUI, provide arguments like:"
    echo "  -p '<passphrase>' [-d] [-b]"
    echo "IMPORTANT: Always wrap your passphrase in single quotes."
    exit 1
}

#
# Custom argument parser for the Unraid User Scripts environment
#
parse_args() {
    local input_string="$*" # Combine all arguments into a single string

    # Extract the passphrase from within single quotes after the -p flag
    if [[ "$input_string" =~ -p[[:space:]]\'([^\']+)\' ]]; then
        PASSPHRASE="${BASH_REMATCH[1]}"
    else
        echo "Error: Could not find a valid passphrase. Please provide it using -p '<password>'"
        usage
    fi

    # Check for other flags in the string
    if [[ "$input_string" =~ -d ]]; then
        DRY_RUN="yes"
        echo "Dry run mode enabled."
    fi
    if [[ "$input_string" =~ -b ]]; then
        BACKUP_HEADERS="yes"
        echo "Header backup enabled."
    fi

    # Final validation
    if [[ -z "$PASSPHRASE" ]]; then
        echo "Error: Passphrase is required and could not be parsed."
        usage
    fi
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
    local motherboard_id mac_address derived_key

    motherboard_id=$(get_motherboard_id)
    if [[ -z "$motherboard_id" ]]; then
        echo "Error: Could not retrieve motherboard serial number." >&2
        exit 1
    fi

    mac_address=$(get_gateway_mac)
    if [[ -z "$mac_address" ]]; then
        echo "Error: Could not retrieve gateway MAC address." >&2
        exit 1
    fi

    # Combine hardware IDs and hash them to create the key
    derived_key=$(echo -n "${motherboard_id}_${mac_address}" | sha256sum | awk '{print $1}')

    # Create the keyfile
    mkdir -p "$(dirname "$KEYFILE")"
    echo -n "$derived_key" > "$KEYFILE"
    echo "Keyfile generated successfully at $KEYFILE"
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
# Process each LUKS device: backup header and add key in a single pass.
#
process_devices() {
    echo
    echo "--- Starting LUKS Device Processing ---"

    # Initialize result arrays
    added_keys=()
    skipped_devices=()
    failed_devices=()
    local headers_found=0

    # Prepare for header backups if requested
    if [[ "$BACKUP_HEADERS" == "yes" ]]; then
        mkdir -p "$HEADER_BACKUP_DIR"
    fi

    for luks_device in $(get_luks_devices); do
        echo
        echo "--- Processing device: $luks_device ---"

        # Get and display key slot info
        local dump_output
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
        echo "  - Key Slots Used:   $used_slots / $total_slots"

        # 1. Check if the user-provided passphrase unlocks the device
        if ! echo -n "$PASSPHRASE" | cryptsetup luksOpen --test-passphrase --key-file=- "$luks_device" &>/dev/null; then
            echo "  - Passphrase Check: FAILED. Skipping this device."
            failed_devices+=("$luks_device: Invalid passphrase")
            continue
        fi
        echo "  - Passphrase Check: OK"

        # 2. Perform header backup if requested
        if [[ "$BACKUP_HEADERS" == "yes" ]]; then
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
                    fi
                fi
            fi
        fi

        # 3. Check if the new hardware key *already* exists on the device
        if cryptsetup luksOpen --test-passphrase --key-file="$KEYFILE" "$luks_device" &>/dev/null; then
            echo "  - Hardware Key:     Present. No action needed."
            skipped_devices+=("$luks_device")
            continue
        fi
        echo "  - Hardware Key:     Not Present."

        # 4. Add the new key
        if [[ "$DRY_RUN" == "yes" ]]; then
            echo "  - Key Addition:     [DRY RUN] Would be added."
            added_keys+=("$luks_device")
        else
            echo "  - Key Addition:     Adding key..."
            if echo -n "$PASSPHRASE" | cryptsetup luksAddKey "$luks_device" "$KEYFILE" --key-file=-; then
                echo "    ...Success."
                added_keys+=("$luks_device")
            else
                echo "    ...Error."
                failed_devices+=("$luks_device: luksAddKey command failed")
            fi
        fi
    done
    
    # 5. Create the final encrypted archive if headers were backed up
    if [[ "$BACKUP_HEADERS" == "yes" && $headers_found -gt 0 ]]; then
        echo
        local final_backup_file="${ZIPPED_HEADER_BACKUP_LOCATION}/luksheaders_${TIMESTAMP}.zip"
        if [[ "$DRY_RUN" == "yes" ]]; then
            echo "Dry Run: Final encrypted archive of $headers_found headers would be created at $final_backup_file"
        else
            echo "Creating encrypted zip archive of $headers_found headers..."
            mkdir -p "$ZIPPED_HEADER_BACKUP_LOCATION"
            zip -j --password "$PASSPHRASE" "$final_backup_file" "$HEADER_BACKUP_DIR"/*.img
            if [[ $? -eq 0 ]]; then
                echo "Final encrypted archive created at $final_backup_file"
            else
                echo "Error: Failed to create the encrypted archive."
            fi
        fi
    elif [[ "$BACKUP_HEADERS" == "yes" ]]; then
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

    echo "--- Key Addition Results ---"
    if [[ "$DRY_RUN" == "yes" ]]; then
        echo "Keys WOULD HAVE BEEN ADDED to (${#added_keys[@]}) devices:"
    else
        echo "Keys SUCCESSFULLY ADDED to (${#added_keys[@]}) devices:"
    fi
    if [ ${#added_keys[@]} -gt 0 ]; then
        for disk in "${added_keys[@]}"; do echo "  - $disk"; done
    else
        echo "  - None"
    fi
    echo

    echo "Keys SKIPPED on (${#skipped_devices[@]}) devices (key already exists):"
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

# Step 1: Parse command-line arguments. Use "$*" to pass all args as a single string.
parse_args "$*"

# Step 2: Generate the dynamic, hardware-tied keyfile
generate_keyfile

# Step 3: Classify disks for the final report
classify_disks

# Step 4: Process all devices (backup headers and add keys)
process_devices

# Step 5: Display a comprehensive summary of what happened
generate_summary

echo "Script finished."
