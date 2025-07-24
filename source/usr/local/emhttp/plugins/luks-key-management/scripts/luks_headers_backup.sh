#!/bin/bash
#
# Description: Standalone LUKS header backup utility
# This script creates encrypted backups of LUKS headers for all devices
# that can be unlocked with the provided passphrase.
#

# Exit on any error
set -e

# --- Configuration & Variables ---

# Default values for script options
DRY_RUN="no"
DOWNLOAD_MODE="no"
PASSPHRASE=""

# Locations
TEMP_WORK_DIR="/tmp/luks_header_backup_$$" # $$ makes it unique per script run
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
# Create header backup for a single device
#
backup_device_header() {
    local device="$1"
    local passphrase="$2"
    
    echo "--- Processing device: $device ---"
    
    # Get LUKS version
    local luks_version=$(get_luks_version "$device")
    echo "  - LUKS Version:     $luks_version"
    
    # Validate passphrase
    echo -n "  - Passphrase Check: "
    if validate_passphrase "$device" "$passphrase"; then
        echo "OK"
    else
        echo "FAILED - Skipping device"
        return 1
    fi
    
    # Extract UUID from cryptsetup dump
    echo -n "  - Header Backup:    "
    local uuid=$(cryptsetup luksDump "$device" | grep 'UUID:' | awk '{print $2}')
    local device_name=$(basename "$device")
    local backup_filename="HEADER_UUID_${uuid}_DEVICE_${device_name}.img"
    local backup_path="$HEADER_BACKUP_DIR/$backup_filename"
    
    if [[ "$DRY_RUN" == "yes" ]]; then
        echo "Would backup to $backup_filename"
        return 0
    fi
    
    echo "Backing up..."
    if cryptsetup luksHeaderBackup "$device" --header-backup-file "$backup_path" 2>/dev/null; then
        echo "    ...Success."
        return 0
    else
        echo "    ...FAILED."
        return 1
    fi
}

#
# Create encrypted archive of all header backups
#
create_backup_archive() {
    local passphrase="$1"
    local headers_found="$2"
    
    if [[ "$headers_found" -eq 0 ]]; then
        echo "No headers were backed up - skipping archive creation."
        return 0
    fi
    
    # Determine archive location based on download mode
    local archive_location
    if [[ "$DOWNLOAD_MODE" == "yes" ]]; then
        archive_location="$DOWNLOAD_TEMP_DIR"
        mkdir -p "$archive_location"
        echo "Download mode enabled - archive will be prepared for browser download."
    else
        archive_location="$ZIPPED_HEADER_BACKUP_LOCATION"
        mkdir -p "$archive_location"
    fi
    
    local archive_name="luksheaders_${TIMESTAMP}.zip"
    local archive_path="$archive_location/$archive_name"
    
    echo "Creating encrypted zip archive of $headers_found headers..."
    
    if [[ "$DRY_RUN" == "yes" ]]; then
        echo "Would create encrypted archive: $archive_path"
        return 0
    fi
    
    # Create encrypted ZIP archive with all headers
    cd "$HEADER_BACKUP_DIR"
    echo "$passphrase" | zip -r -e --password-from-stdin "$archive_path" *.img 2>/dev/null
    
    echo "Final encrypted archive created at $archive_path"
    echo "Archive includes LUKS headers for $headers_found devices"
    
    return 0
}

#
# Main processing function
#
process_devices() {
    local passphrase="$1"
    
    echo ""
    echo "--- Starting LUKS Header Backup ---"
    echo ""
    
    # Get all LUKS devices
    local devices=($(get_luks_devices))
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "No LUKS encrypted devices found."
        return 0
    fi
    
    echo "Found ${#devices[@]} LUKS encrypted devices"
    
    # Create temporary directories
    mkdir -p "$TEMP_WORK_DIR"
    mkdir -p "$HEADER_BACKUP_DIR"
    
    # Process each device
    local headers_found=0
    for device in "${devices[@]}"; do
        if backup_device_header "$device" "$passphrase"; then
            ((headers_found++))
        fi
        echo ""
    done
    
    echo "Successfully backed up headers for $headers_found devices"
    
    # Create archive if we have any headers
    if [[ "$headers_found" -gt 0 ]]; then
        create_backup_archive "$passphrase" "$headers_found"
    fi
    
    return 0
}

#
# Parse command line arguments
#
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dry-run)
                DRY_RUN="yes"
                echo "Dry run enabled."
                shift
                ;;
            --download-mode)
                DOWNLOAD_MODE="yes"
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

LUKS Header Backup Utility

OPTIONS:
    -d, --dry-run           Simulate the backup process without creating files
    --download-mode         Prepare backup for browser download instead of server storage
    -p, --passphrase PASS   LUKS passphrase (can also be provided via LUKS_PASSPHRASE env var)
    -h, --help              Show this help message

ENVIRONMENT VARIABLES:
    LUKS_PASSPHRASE         LUKS passphrase (alternative to -p option)

EXAMPLES:
    $0 -p "mypassphrase"                    # Backup headers to server
    $0 -p "mypassphrase" --download-mode    # Prepare backup for download
    $0 -d -p "mypassphrase"                 # Dry run simulation

EOF
}

#
# Cleanup function
#
cleanup() {
    if [[ -d "$TEMP_WORK_DIR" ]]; then
        echo "Cleaning up temporary directory: $TEMP_WORK_DIR"
        rm -rf "$TEMP_WORK_DIR"
    fi
}

# Set up cleanup trap
trap cleanup EXIT

# --- Main Script Logic ---

echo "==================================================="
echo "---         LUKS Header Backup Utility         ---"
echo "==================================================="

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

# Show configuration
echo "Configuration:"
echo "  - Dry Run: $DRY_RUN"
echo "  - Download Mode: $DOWNLOAD_MODE"
echo "  - Timestamp: $TIMESTAMP"

# Process all devices
process_devices "$PASSPHRASE"

echo ""
echo "==================================================="
echo "---            Backup Complete                  ---"
echo "==================================================="
echo "Script finished."