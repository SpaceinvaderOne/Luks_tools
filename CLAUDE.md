# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Unraid plugin for LUKS key management that provides secure auto-unlock functionality for encrypted arrays and pools. The plugin generates hardware-bound secondary keys from router MAC address and motherboard ID without storing keys on disk.

## Build System

### Building the Plugin Package
```bash
./build_macos.sh
```
This script:
- Creates a `.txz` package from the `source/` directory
- Excludes macOS metadata files (`.DS_Store`, `._*`, etc.) during packaging
- Archives old packages to `packages/archive/`
- Calculates MD5 checksum
- Updates the `.plg` installer file with new version, URL, and MD5
- Uses current date as version (YYYY.MM.DD format)

### Directory Structure
```
source/usr/local/emhttp/plugins/luks-key-management/
├── luks_management.page          # Main UI (Menu="Utilities")
├── scripts/
│   ├── luks_management.sh        # Core LUKS operations
│   ├── fetch_key.sh             # Hardware key generation
│   ├── delete_key.sh            # Key removal
│   ├── write_go.sh              # Boot integration
│   ├── run_luks_script.php      # LUKS script executor
│   ├── run_go_script.php        # Go script executor
│   ├── download_backup.php      # LUKS header backup download
│   └── cleanup_download.php     # Temporary file cleanup
└── images/                      # Plugin icons/assets
```

## Architecture

### Multi-Language System
- **Shell Scripts**: Core LUKS operations and hardware fingerprinting
- **PHP**: Web interface backend with process execution via `proc_open`
- **JavaScript**: Frontend interactions embedded in `.page` file
- **XML**: Unraid plugin installer (`.plg` format)

### Key Components

#### Hardware Fingerprinting (`fetch_key.sh:30-98`)
- Extracts default gateway MAC address
- Retrieves motherboard serial number
- Combines with salt to generate hardware-bound key
- Never stores keys on disk

#### LUKS Operations (`luks_management.sh`)
- Adds secondary key slots to encrypted devices
- Supports dry-run mode for testing
- Creates encrypted header backups
- Uses error output redirection (`>&2`)

#### Web Interface (`luks_management.page`)
- Two-step process: Add derived key → Enable auto-unlock
- AJAX communication with PHP backends
- Form validation and user feedback
- LUKS header backup download functionality

#### Backup Management
- Headers stored in `/boot/config/luksheaders/`
- Download via `download_backup.php` with security validation
- Temporary file cleanup via `cleanup_download.php`

## Error Handling Patterns

### Shell Scripts
```bash
echo "Error: Description here" >&2
set -e  # Exit on any error
```

### PHP Scripts
```php
echo "Error: Description here";
# Process error capture via proc_open pipes
```

### JavaScript
```javascript
outputDiv.textContent = 'Error: Description here';
```

## Security Considerations

- Hardware-bound key generation prevents theft scenarios
- Original LUKS passphrase remains unchanged
- No network dependencies for unlock process
- Keys are derived, not stored
- Header backups are password-protected

## Plugin Installation Flow

1. Compatibility check (Unraid 6.9.0+)
2. Download `.txz` package with MD5 verification
3. Install to `/usr/local/emhttp/plugins/luks-key-management/`
4. Set executable permissions on shell scripts
5. Plugin appears in Utilities menu