<?php
// Include Unraid's webGUI session handling for CSRF validation (using official pattern)
$docroot = $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
require_once "$docroot/webGui/include/Wrappers.php";

// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Debug CSRF token
echo "DEBUG: POST data keys: " . implode(', ', array_keys($_POST)) . "\n";
echo "DEBUG: CSRF token in POST: " . ($_POST['csrf_token'] ?? 'NOT SET') . "\n";
echo "DEBUG: CSRF token length: " . strlen($_POST['csrf_token'] ?? '') . "\n";

// Define the absolute paths to the LUKS scripts
$main_script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/luks_management.sh";
$headers_script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/luks_headers_backup.sh";

// --- Get POST data from the UI ---
$key_type = $_POST['keyType'] ?? 'passphrase';
$backup_headers_option = $_POST['backupHeaders'] ?? 'no';
$dry_run_option = $_POST['dryRun'] ?? 'yes';
$headers_only = $_POST['headersOnly'] ?? 'false';
$zip_password = $_POST['zipPassword'] ?? '';

// --- Process Encryption Key Input (using Unraid pattern) ---
function processEncryptionKey() {
    global $key_type;
    
    if ($key_type === 'passphrase') {
        $passphrase = $_POST['passphrase'] ?? '';
        if (empty($passphrase)) {
            return ['error' => 'Passphrase is required.'];
        }
        if (strlen($passphrase) > 512) {
            return ['error' => 'Passphrase exceeds 512 character limit (Unraid standard).'];
        }
        
        // Follow official Unraid pattern: write passphrase to temp file and use --key-file
        // This matches how Unraid's official LUKS key change function works
        $temp_passphrase_file = "/tmp/luks_passphrase_" . uniqid() . ".key";
        if (file_put_contents($temp_passphrase_file, $passphrase) === false) {
            return ['error' => 'Failed to create temporary passphrase file.'];
        }
        chmod($temp_passphrase_file, 0600);
        
        return ['type' => 'keyfile', 'value' => $temp_passphrase_file];
    } else {
        // Handle keyfile data (base64 encoded, following Unraid pattern)
        echo "DEBUG: Processing keyfile data...\n";
        
        if (!isset($_POST['keyfileData'])) {
            return ['error' => 'No keyfile data provided.'];
        }
        
        $keyfile_data = $_POST['keyfileData'];
        echo "DEBUG: Keyfile data length: " . strlen($keyfile_data) . "\n";
        
        // Extract base64 data (remove data URL prefix if present)
        if (strpos($keyfile_data, 'base64,') !== false) {
            $base64_data = explode('base64,', $keyfile_data)[1];
        } else {
            $base64_data = $keyfile_data;
        }
        
        // Decode base64 data
        $decoded_data = base64_decode($base64_data);
        if ($decoded_data === false) {
            return ['error' => 'Invalid keyfile data (base64 decode failed).'];
        }
        
        echo "DEBUG: Decoded data size: " . strlen($decoded_data) . " bytes\n";
        
        // Validate file size (8 MiB limit)
        if (strlen($decoded_data) > 8388608) {
            return ['error' => 'Keyfile exceeds 8 MiB limit (Unraid standard).'];
        }
        
        // Create secure temporary file
        $temp_keyfile = "/tmp/luks_keyfile_" . uniqid() . ".key";
        echo "DEBUG: Creating temp file: $temp_keyfile\n";
        
        if (file_put_contents($temp_keyfile, $decoded_data) === false) {
            return ['error' => 'Failed to write keyfile data.'];
        }
        
        // Set secure permissions (read-only for owner)
        chmod($temp_keyfile, 0600);
        echo "DEBUG: Keyfile processed successfully\n";
        
        return ['type' => 'keyfile', 'value' => $temp_keyfile];
    }
}

// Process the encryption key
$encryption_key = processEncryptionKey();
if (isset($encryption_key['error'])) {
    echo "Error: " . $encryption_key['error'];
    exit(1);
}

// --- Determine which script to use and build arguments ---
if ($headers_only === 'true') {
    // Headers-only operation - use dedicated backup script
    $script_path = $headers_script_path;
    $args = "";
    if ($dry_run_option === 'yes') {
        $args .= " -d";
    }
    if ($backup_headers_option === 'download') {
        $args .= " --download-mode";
    }
    // For headers script, pass encryption key via command line
    // Since we now use temp files for both passphrases and keyfiles (Unraid pattern),
    // we always use -k (keyfile) option, but also pass original input type
    $args .= " -k " . escapeshellarg($encryption_key['value']);
    $args .= " --original-input-type " . escapeshellarg($key_type);
    if (!empty($zip_password)) {
        $args .= " --zip-password " . escapeshellarg($zip_password);
        echo "DEBUG: ZIP password added to headers script arguments\n";
    }
} else {
    // Full auto-start setup - use main management script
    $script_path = $main_script_path;
    $args = "";
    if ($dry_run_option === 'yes') {
        $args .= " -d";
    }
    // Headers are always backed up now, so pass download mode if needed
    if ($backup_headers_option === 'download') {
        $args .= " --download-mode";
    }
}

$command = $script_path . $args;

// --- Execute the Command using proc_open ---

// Define the process descriptors
$descriptorspec = array(
   0 => array("pipe", "r"),  // stdin
   1 => array("pipe", "w"),  // stdout
   2 => array("pipe", "w")   // stderr
);

// Prepare environment variables for encryption key
$env = array(
    'PATH' => '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin'
);

// For main script, pass encryption key via environment variables
// Since we now use temp files for both passphrases and keyfiles (Unraid pattern),
// we always use LUKS_KEYFILE, but also pass the original user input type
if ($headers_only !== 'true') {
    $env['LUKS_KEYFILE'] = $encryption_key['value'];
    $env['LUKS_ORIGINAL_INPUT_TYPE'] = $key_type;  // 'passphrase' or 'keyfile'
    if (!empty($zip_password)) {
        $env['LUKS_ZIP_PASSWORD'] = $zip_password;
        echo "DEBUG: ZIP password provided for keyfile user\n";
    }
    echo "DEBUG: Auto Start using keyfile path: " . $encryption_key['value'] . "\n";
    echo "DEBUG: Original input type: " . $key_type . "\n";
}

// Start the process with the explicit environment
$process = proc_open($command, $descriptorspec, $pipes, null, $env);

if (is_resource($process)) {
    // We don't need to write to stdin anymore, so close it immediately.
    fclose($pipes[0]);

    // Read the output from the script's standard output
    $output = stream_get_contents($pipes[1]);
    fclose($pipes[1]);

    // Read any errors from the script's standard error
    $errors = stream_get_contents($pipes[2]);
    fclose($pipes[2]);

    // Close the process
    proc_close($process);

    // Combine output and errors for display
    if (!empty($errors)) {
        $output .= "\n--- SCRIPT ERRORS ---\n" . $errors;
    }

    // Handle symlink creation for download mode
    if ($backup_headers_option === 'download' && $dry_run_option === 'no') {
        // Look for the backup file path in the output
        if (preg_match('/Final encrypted archive created at (.+\.zip)/', $output, $matches)) {
            $backup_file = $matches[1];
            $filename = basename($backup_file);
            
            // Create symlink in plugin directory for browser access
            $plugin_download_dir = "/usr/local/emhttp/plugins/luks-key-management/downloads";
            $symlink_path = "$plugin_download_dir/$filename";
            
            // Ensure download directory exists with proper permissions
            if (!is_dir($plugin_download_dir)) {
                if (!mkdir($plugin_download_dir, 0755, true)) {
                    echo "DEBUG: Failed to create download directory: $plugin_download_dir\n";
                    $output .= "\nWarning: Could not create download directory.";
                    return;
                }
                echo "DEBUG: Created download directory: $plugin_download_dir\n";
            }
            
            // Remove any existing file and create new one
            if (file_exists($symlink_path)) {
                unlink($symlink_path);
            }
            
            // Check if source file exists before copying
            if (!file_exists($backup_file)) {
                echo "DEBUG: Source file does not exist: $backup_file\n";
                $output .= "\nWarning: Source backup file not found.";
                return;
            }
            
            // Copy the file to the plugin directory instead of symlinking from temp location
            // This prevents issues with temp directory cleanup
            if (copy($backup_file, $symlink_path)) {
                // Set proper permissions on the copied file
                chmod($symlink_path, 0644);
                $output .= "\nDOWNLOAD_READY: $symlink_path";
                echo "DEBUG: Archive copied to download location: $symlink_path\n";
            } else {
                $output .= "\nWarning: Could not copy backup file to download location.";
                echo "DEBUG: Failed to copy $backup_file to $symlink_path\n";
                echo "DEBUG: Source file exists: " . (file_exists($backup_file) ? "yes" : "no") . "\n";
                echo "DEBUG: Destination dir writable: " . (is_writable($plugin_download_dir) ? "yes" : "no") . "\n";
            }
        }
    }

    echo $output;
} else {
    echo "Error: Failed to execute the script process (proc_open failed).";
    exit(1);
}

// Clean up temporary files (both passphrase temp files and uploaded keyfiles)
if (isset($encryption_key['value']) && file_exists($encryption_key['value'])) {
    // Check if it's a temp file we created (either passphrase or keyfile)
    if (strpos($encryption_key['value'], '/tmp/luks_') === 0) {
        unlink($encryption_key['value']);
        echo "DEBUG: Auto Start cleaned up temporary file: " . $encryption_key['value'] . "\n";
    }
}
?>
