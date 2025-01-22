#!/bin/bash
#description=Encrypt drives with a hardware-tied key and manage LUKS headers
#foregroundOnly=true
#arrayStarted=true
#name=LUKS Key Management
#clearLog=true
#argumentDescription=Provide script arguments such as passphrase=<password>, dryrun, backupheaders
#argumentDefault=
#set -x

# Variables
dry_run="yes"  # Default to no dry run unless overridden
backup_luks_headers="yes"  # Default to no header backup unless overridden
header_backup_location="/tmp/autostart_array_headers"
zipped_header_backup_location="/boot/config/luksheaders"
timestamp=$(date +%Y%m%d_%H%M%S)
keyfile="$header_backup_location/Dynamic_2Factor_Keyfile_$timestamp"
current_password=""

# Function to interpret arguments
interpret_args() {
    if [[ $# -lt 1 ]]; then
        echo "Error: At least one argument is required."
        echo "Usage: <passphrase> [dryrun] [backupheaders]"
        exit 1
    fi

    # First argument is treated as the passphrase
    current_password="$1"
    shift  # Shift to process remaining arguments

    # Warn if the passphrase looks like a flag
    case "$current_password" in
        dryrun|backupheaders)
            echo "Error: The first argument ($current_password) looks like a flag. The first argument must be the passphrase."
            exit 1
            ;;
    esac

    # Process remaining arguments
    for arg in "$@"; do
        case "$arg" in
            dryrun)
                dry_run="yes"
                ;;
            backupheaders)
                backup_luks_headers="yes"
                ;;
            *)
                echo "Unknown argument: $arg"
                echo "Valid arguments are:"
                echo "  <passphrase>            - The LUKS passphrase (must be the first argument)."
                echo "  dryrun                  - Enable dry-run mode."
                echo "  backupheaders           - Force header backup even in dry-run mode."
                exit 1
                ;;
        esac
    done

    # Ensure the passphrase is valid
    if [[ -z "$current_password" ]]; then
        echo "Error: A passphrase is required as the first argument."
        exit 1
    fi
}

# Function to extract the CPU ID
get_cpu_id() {
    # Extract the Processor ID from dmidecode
    local cpu_id
    cpu_id=$(dmidecode -t processor | grep 'ID:' | head -n1 | awk '{print $2, $3, $4, $5, $6, $7, $8, $9}')
    echo "${cpu_id:-unknown}" # Fallback to "unknown" if not found
}

get_gateway_mac() {
    local interface gateway_ip mac_address
    mapfile -t routes < <(ip route show default | awk '/default/ {print $5 " " $3}')
    for route in "${routes[@]}"; do
        interface=$(echo "$route" | awk '{print $1}')
        gateway_ip=$(echo "$route" | awk '{print $2}')
        mac_address=$(arping -c 1 -I "$interface" "$gateway_ip" 2>/dev/null | grep "reply from" | awk '{print $5}' | tr -d '[]')
        [[ -n "$mac_address" ]] && echo "$mac_address" && return 0
    done
    echo "Error: Unable to retrieve MAC address of the default gateway."
    return 1
}

generate_keyfile() {
    local cpu_id mac_address derived_key
    cpu_id=$(get_cpu_id)
    mac_address=$(get_gateway_mac)
    [[ -z "$cpu_id" || -z "$mac_address" ]] && { echo "Error: Unable to generate key."; exit 1; }
    derived_key=$(echo -n "${cpu_id}_${mac_address}" | sha256sum | awk '{print $1}')
    mkdir -p "$(dirname "$keyfile")"  # Ensure directory exists
    echo -n "$derived_key" > "$keyfile"
    echo "Keyfile generated successfully at $keyfile"
}

# Function to get all LUKS-encrypted devices
get_luks_devices() {
    lsblk --noheadings --pairs --output NAME,TYPE | grep 'TYPE="crypt"' | awk -F'"' '{print "/dev/" $2}'
}

resolve_physical_device() {
    local md_device="$1"
    resolved_device=$(lsblk --noheadings --pairs --output KNAME --path "$md_device" | awk '{print $1}')
    if [[ -z "$resolved_device" ]]; then
        echo "Unable to resolve physical device for $md_device"
        return 1
    fi
    echo "$resolved_device"
    return 0
}
classify_disks() {
    array_disks=()
    pool_disks=()
    standalone_disks=()

    # Collect pool disk info from Unraid configuration
    declare -A pool_map
    for pool_cfg in /boot/config/pools/*.cfg; do
        pool_name=$(basename "$pool_cfg" .cfg)
        while IFS= read -r line; do
            if [[ "$line" =~ diskId=\"([^\"]+)\" ]]; then
                pool_map["${BASH_REMATCH[1]}"]=$pool_name
            fi
        done < "$pool_cfg"
    done

    # Map device names to pool names using udevadm
    declare -A device_to_pool
    for device in /dev/nvme* /dev/sd*; do
        disk_id=$(udevadm info --query=all --name="$device" 2>/dev/null | grep "ID_SERIAL=" | awk -F= '{print $2}')
        if [[ -n "$disk_id" && -n "${pool_map[$disk_id]}" ]]; then
            device_to_pool["$device"]=${pool_map[$disk_id]}
        fi
    done

    # Classify disks based on lsblk output
    while read -r line; do
        eval "$line"
        device="/dev/$NAME"
        mount_path="${MOUNTPOINT#/mnt/}"

        if [[ "$device" == "/dev/md"* ]]; then
            array_disks+=("$device")
        elif [[ -n "${device_to_pool[$device]}" ]]; then
            pool_disks+=("$device (${device_to_pool[$device]})")
        elif [[ -z "$mount_path" ]]; then
            standalone_disks+=("$device")
        fi
    done < <(lsblk --pairs --output NAME,MOUNTPOINT,TYPE | grep 'TYPE="crypt"')
}


# Function to back up LUKS headers
backup_headers() {
    if [[ "$backup_luks_headers" =~ ^(yes|Yes)$ ]]; then
        mkdir -p "$header_backup_location"
        final_backup_file="${zipped_header_backup_location}/luksheaders_${timestamp}.zip"

        # Temporarily override dry_run for this function
        local function_dry_run="$dry_run"
        if [[ "$backup_luks_headers" =~ ^(yes|Yes)$ ]]; then
            function_dry_run="no"
        fi

        for luks_device in $(get_luks_devices); do
            # Get the UUID of the LUKS device
            luks_uuid=$(cryptsetup luksUUID "$luks_device" 2>/dev/null)
            if [[ -z "$luks_uuid" ]]; then
                echo "Error: Could not retrieve UUID for $luks_device. Skipping."
                continue
            fi

            # Construct the backup file name
            backup_file="${header_backup_location%/}/HEADER_UUID_${luks_uuid}_DEVICE_$(basename "$luks_device").img"

            if [[ "$function_dry_run" =~ ^(yes|Yes)$ ]]; then
                echo "Dry Run: Header for $luks_device would be backed up to $backup_file"
                continue
            fi

            if [[ -f "$backup_file" ]]; then
                echo "Backup file $backup_file already exists. Skipping."
                continue
            fi

            # Backup LUKS header
            cryptsetup luksHeaderBackup "$luks_device" --header-backup-file="$backup_file"
            if [[ $? -eq 0 ]]; then
                echo "Header backed up for $luks_device at $backup_file"
            else
                echo "Error: Failed to back up header for $luks_device"
            fi
        done

        # Create the encrypted archive
        if [[ "$function_dry_run" =~ ^(yes|Yes)$ ]]; then
            echo "Dry Run: Final archive would be created at $final_backup_file"
        else
            mkdir -p "$zipped_header_backup_location"
            cd "$header_backup_location" || return
            zip -0 --password "$current_password" "$final_backup_file" ./*.img
            if [[ $? -eq 0 ]]; then
                echo "Final encrypted archive created at $final_backup_file"
            else
                echo "Error: Failed to create the encrypted archive at $final_backup_file"
            fi
        fi
    fi
}
add_luks_key() {
    echo "Starting LUKS key addition process..."

    local processed_devices=()
    local added_keys=()
    local skipped_devices=()
    local failed_devices=()

    for luks_device in $(get_luks_devices); do
        echo "Processing device: $luks_device"

        # Validate supplied key (current_password)
        if echo -n "$current_password" | cryptsetup luksOpen --test-passphrase --key-file=- "$luks_device" 2>/dev/null; then
            echo "Supplied key unlocks $luks_device."

            # Validate dynamic key (/tmp/mykeyfile)
            if cryptsetup luksOpen --test-passphrase --key-file=/tmp/mykeyfile "$luks_device" 2>/dev/null; then
                echo "Dynamic key already exists for $luks_device. Skipping."
                skipped_devices+=("$luks_device")
            else
                if [[ "$dry_run" =~ ^(yes|Yes)$ ]]; then
                    echo "Dynamic key would be added to $luks_device (dry run)."
                    added_keys+=("$luks_device")
                else
                    if echo -n "$current_password" | cryptsetup luksAddKey "$luks_device" --key-file=/tmp/mykeyfile; then
                        echo "Dynamic key added to $luks_device."
                        added_keys+=("$luks_device")
                    else
                        echo "Failed to add dynamic key to $luks_device."
                        failed_devices+=("$luks_device: Key addition failed")
                    fi
                fi
            fi
        else
            echo "Supplied key does not unlock $luks_device. Skipping."
            failed_devices+=("$luks_device: Unlock failed")
        fi
        processed_devices+=("$luks_device")
    done

    # Pass results to the summary function
    generate_summary "$dry_run" "${#processed_devices[@]}" "${added_keys[@]}" "${skipped_devices[@]}" "${failed_devices[@]}"
}

generate_summary() {
    echo "--- LUKS Key Addition Summary ---"
    echo "DryRun - $dry_run"
    echo "Total LUKS devices identified containing your provided unlock key: ${#processed_devices[@]}"
    echo

    echo "Array Disks:"
    for disk in "${array_disks[@]}"; do
        if [[ $disk =~ /dev/md([0-9]+) ]]; then
            array_number="${BASH_REMATCH[1]}"
            echo "$disk (Array Disk $array_number)"
        else
            echo "$disk"
        fi
    done
    echo

    echo "Pool Disks:"
    for disk in "${pool_disks[@]}"; do
        echo "$disk"
    done
    echo

    echo "Standalone Disks:"
    for disk in "${standalone_disks[@]}"; do
        echo "$disk"
    done
    echo

    echo "Devices where the key would be added:"
    if [[ "$dry_run" =~ ^(yes|Yes)$ ]]; then
        echo "Dry Run: Keys would have been added to the following devices:"
        for device in "${added_keys[@]}"; do
            echo "- $device"
        done
     elif [[ ${#added_keys[@]} -gt 0 ]]; then
        for device in "${added_keys[@]}"; do
            echo "- $device"
        done
    else
        echo "None"
    fi
    echo

    echo "No failures detected."
    echo "---------------------------------"
}

# Main script execution
interpret_args "$@"       # Parse arguments passed to the script
generate_keyfile          # Generate the dynamic keyfile
classify_disks            # Classify the disks into categories
backup_headers            # Backup LUKS headers (if enabled)
add_luks_key              # Add dynamic keys to the LUKS devices
rm -r "$header_backup_location"  # Cleanup temporary header backup directory
