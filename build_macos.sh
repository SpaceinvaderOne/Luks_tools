#!/bin/bash
#
# Unraid Plugin Build Script (for macOS)
#
# This script automates the process of packaging an Unraid plugin,
# calculating its MD5 checksum, and updating the .plg installer file.

echo "--- Unraid Plugin Build Script ---"
echo

# --- Configuration ---
# The path to your plugin's source files. The structure inside this directory
# should be `usr/local/emhttp/plugins/...`
SOURCE_ROOT="./source"

# The directory where the final .txz packages will be placed.
OUTPUT_DIR="./packages/pluginmain"

# The directory where old packages will be archived.
ARCHIVE_DIR="./packages/archive"

# The path to your .plg installer file.
# The script will read the plugin name from this file.
PLG_FILE="./unraid-plugin/luks-key-management.plg" # CORRECTED PATH

# The base URL of your GitHub repository.
# The script will use this to construct the final download URL.
GITHUB_BASE_URL="https://github.com/SpaceinvaderOne/Luks_tools"


# --- Pre-flight Checks ---

# Ensure the .plg file exists.
if [ ! -f "$PLG_FILE" ]; then
    echo "Error: Plugin installer file not found at '$PLG_FILE'"
    exit 1
fi

# Ensure the source directory exists.
if [ ! -d "$SOURCE_ROOT" ]; then
    echo "Error: Source directory not found at '$SOURCE_ROOT'"
    exit 1
fi

# --- Read Info from .plg File ---

# Read the plugin name directly from the .plg file.
PLUGIN_NAME=$(grep '<!ENTITY name' "$PLG_FILE" | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$PLUGIN_NAME" ]; then
    echo "Error: Could not determine plugin name from '$PLG_FILE'."
    exit 1
fi
echo "Plugin Name: $PLUGIN_NAME"

# --- IMPORTANT: Check for directory name consistency ---
PLUGIN_SOURCE_DIR="${SOURCE_ROOT}/usr/local/emhttp/plugins/${PLUGIN_NAME}"
if [ ! -d "$PLUGIN_SOURCE_DIR" ]; then
    echo "********************************************************************"
    echo "Error: Directory Mismatch!"
    echo "The plugin name in your .plg file is '${PLUGIN_NAME}',"
    echo "but the source directory was not found at:"
    echo "'${PLUGIN_SOURCE_DIR}'"
    echo "Please ensure the folder name in 'source/usr/local/emhttp/plugins/'"
    echo "matches the plugin name in your .plg file."
    echo "********************************************************************"
    exit 1
fi


# --- Set Version and Filenames ---

# Set the new version to the current date in YYYY.MM.DD format.
NEW_VERSION=$(date +%Y.%m.%d)
echo "New Version: $NEW_VERSION"

# Define the final output filename for the package.
OUTPUT_FILENAME="${PLUGIN_NAME}-${NEW_VERSION}-x86_64.txz"
FULL_OUTPUT_PATH="${OUTPUT_DIR}/${OUTPUT_FILENAME}"

# Construct the full GitHub raw download URL.
# Assumes the package is in a 'packages/pluginmain' directory on the 'main' branch.
# Adjust the path if your repository structure is different.
FULL_PLUGIN_URL="${GITHUB_BASE_URL}/raw/main/packages/pluginmain/${OUTPUT_FILENAME}"

# --- Prepare Directories ---

# Ensure the necessary output and archive directories exist.
mkdir -p "$OUTPUT_DIR" "$ARCHIVE_DIR"

# Move any existing packages from the output directory to the archive directory.
if compgen -G "$OUTPUT_DIR/*" > /dev/null; then
    echo "Archiving old packages from '$OUTPUT_DIR'..."
    mv "$OUTPUT_DIR"/* "$ARCHIVE_DIR"/
else
    echo "No old packages to archive."
fi
echo

# --- Create Plugin Package ---

echo "Creating new plugin package..."
# Create the .txz archive. The -C flag changes to the source directory,
# which prevents 'source/' from being included in the archive's path structure.
# Exclude macOS metadata files and other unwanted files
tar -cJf "$FULL_OUTPUT_PATH" -C "$SOURCE_ROOT" --exclude='.DS_Store' --exclude='._*' --exclude='.AppleDouble' --exclude='.LSOverride' usr
if [ $? -ne 0 ]; then
    echo "Error: Failed to create tar archive."
    exit 1
fi
echo "Successfully created: $OUTPUT_FILENAME"
echo

# --- Calculate Checksum ---

echo "Calculating MD5 checksum..."
# Calculate the MD5 checksum of the new package.
# The `md5 -q` flag on macOS outputs only the hash, which is cleaner.
NEW_MD5=$(md5 -q "$FULL_OUTPUT_PATH")
if [ -z "$NEW_MD5" ]; then
    echo "Error: Failed to calculate MD5 checksum."
    exit 1
fi
echo "New MD5: $NEW_MD5"
echo

# --- Update .plg File ---

echo "Updating '$PLG_FILE' with new version, MD5, and URL..."
# Use sed to update the entities in-place. The -i '' flag is for macOS.
# Using '|' as the sed delimiter is safer for URLs which contain '/'.
sed -i '' "s|<!ENTITY plugin_version.*|<!ENTITY plugin_version       \"${NEW_VERSION}\">|" "$PLG_FILE"
sed -i '' "s|<!ENTITY plugin_md5.*|<!ENTITY plugin_md5           \"${NEW_MD5}\">|" "$PLG_FILE"
sed -i '' "s|<!ENTITY plugin_url.*|<!ENTITY plugin_url           \"${FULL_PLUGIN_URL}\">|" "$PLG_FILE"

echo "Successfully updated version, MD5, and URL in the .plg file."
echo

# --- Finish ---

echo "--- Build Complete ---"
