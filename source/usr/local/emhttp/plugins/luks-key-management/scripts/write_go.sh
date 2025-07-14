#!/bin/bash
#
# Description: Safely adds or removes the auto-unlock block from the /boot/config/go file.
#
# Unraid User Script Header:
# description=Safely adds or removes the auto-unlock block from the /boot/config/go file.
# name=Go File Auto-Unlock Config
# foregroundOnly=true
# argumentDescription=Use '-r' or '--remove' to remove the block. No argument adds it.
# argumentDefault=

# --- Configuration ---
GO_FILE="/boot/config/go"
SCRIPT_SOURCE_DIR="/boot/config/driveunlock" # The location of your fetch_key and delete_key scripts
START_MARKER="# auto unlock block start"
END_MARKER="# auto unlock block end"
SHEBANG="#!/bin/bash"

# The entire block of code to be added to the go file.
# Note: We use <<EOF (without quotes) to allow for variable expansion.
read -r -d '' CODE_BLOCK <<EOF

# auto unlock block start
mkdir -p /usr/local/emhttp/webGui/event/{starting,started}
install -D ${SCRIPT_SOURCE_DIR}/fetch_key /usr/local/emhttp/webGui/event/starting/fetch_key
install -D ${SCRIPT_SOURCE_DIR}/delete_key /usr/local/emhttp/webGui/event/started/delete_key
chmod a+x /usr/local/emhttp/webGui/event/{starting/fetch_key,started/delete_key}
# auto unlock block end
EOF

# --- Functions ---

add_block() {
    echo "Checking status of auto-unlock block in $GO_FILE..."

    # First, ensure the go file exists and has a shebang.
    if [[ ! -f "$GO_FILE" ]] || ! grep -qF "$SHEBANG" "$GO_FILE"; then
        echo "$SHEBANG" > "$GO_FILE"
        echo "Created or repaired $GO_FILE with shebang."
    fi

    # Check if the start marker is already in the file.
    if grep -qF "$START_MARKER" "$GO_FILE"; then
        echo "Auto-unlock block already found. No action taken."
    else
        echo "Auto-unlock block not found. Inserting it at the top of the file..."
        
        # Create a temporary file for the new content
        local TEMP_FILE
        TEMP_FILE=$(mktemp)
        
        # Write the shebang and the new code block to the temp file
        echo "$SHEBANG" > "$TEMP_FILE"
        echo "$CODE_BLOCK" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE" # Add a blank line for spacing
        
        # Append the rest of the original go file (excluding the shebang) to the temp file
        grep -vF "$SHEBANG" "$GO_FILE" >> "$TEMP_FILE"
        
        # Safely replace the original file with the new one
        mv "$TEMP_FILE" "$GO_FILE"
        
        # Ensure the go file is executable
        chmod +x "$GO_FILE"
        
        echo "Auto-unlock block successfully added to $GO_FILE."
        echo "Please review the file to ensure correctness."
    fi
}

remove_block() {
    echo "Checking for auto-unlock block to remove from $GO_FILE..."

    # Check if the go file exists and if our block is in it.
    if [[ ! -f "$GO_FILE" ]] || ! grep -qF "$START_MARKER" "$GO_FILE"; then
        echo "Auto-unlock block not found. Nothing to remove."
        return
    fi
    
    echo "Auto-unlock block found. Removing it now..."
    
    # Use sed to delete the lines between the start and end markers (inclusive).
    # The -i flag performs the edit in-place. A backup is created first for safety.
    sed -i.bak "/$START_MARKER/,/$END_MARKER/d" "$GO_FILE"
    
    echo "Auto-unlock block successfully removed."
    echo "A backup of the original file has been saved to ${GO_FILE}.bak"
}

# --- Main Execution ---

# Check the first argument to decide which action to take.
case "$1" in
    -r|--remove)
        remove_block
        ;;
    *)
        add_block
        ;;
esac

exit 0
