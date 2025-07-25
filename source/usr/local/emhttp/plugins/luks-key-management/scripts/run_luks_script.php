<?php
// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Define the absolute paths to the LUKS scripts
$main_script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/luks_management.sh";
$headers_script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/luks_headers_backup.sh";

// --- Get POST data from the UI ---
$key_type = $_POST['keyType'] ?? 'passphrase';
$backup_headers_option = $_POST['backupHeaders'] ?? 'no';
$dry_run_option = $_POST['dryRun'] ?? 'yes';
$headers_only = $_POST['headersOnly'] ?? 'false';

// --- Process Encryption Key Input ---
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
        return ['type' => 'passphrase', 'value' => $passphrase];
    } else {
        // Handle keyfile upload - Add debugging
        echo "DEBUG: Processing keyfile upload...\n";
        echo "DEBUG: _FILES array: " . print_r($_FILES, true) . "\n";
        
        if (!isset($_FILES['keyfile'])) {
            return ['error' => 'No keyfile in upload. Check form enctype and field name.'];
        }
        
        if ($_FILES['keyfile']['error'] !== UPLOAD_ERR_OK) {
            $error_msg = 'Keyfile upload error: ';
            switch ($_FILES['keyfile']['error']) {
                case UPLOAD_ERR_INI_SIZE:
                case UPLOAD_ERR_FORM_SIZE:
                    $error_msg .= 'File too large';
                    break;
                case UPLOAD_ERR_PARTIAL:
                    $error_msg .= 'Partial upload';
                    break;
                case UPLOAD_ERR_NO_FILE:
                    $error_msg .= 'No file uploaded';
                    break;
                default:
                    $error_msg .= 'Unknown error (' . $_FILES['keyfile']['error'] . ')';
            }
            return ['error' => $error_msg];
        }
        
        $uploaded_file = $_FILES['keyfile'];
        echo "DEBUG: File size: " . $uploaded_file['size'] . " bytes\n";
        echo "DEBUG: File name: " . $uploaded_file['name'] . "\n";
        
        // Validate file size (8 MiB limit)
        if ($uploaded_file['size'] > 8388608) {
            return ['error' => 'Keyfile exceeds 8 MiB limit (Unraid standard).'];
        }
        
        // Create secure temporary file
        $temp_keyfile = "/tmp/luks_keyfile_" . uniqid() . ".key";
        echo "DEBUG: Creating temp file: $temp_keyfile\n";
        
        if (!move_uploaded_file($uploaded_file['tmp_name'], $temp_keyfile)) {
            return ['error' => 'Failed to process keyfile upload. Check /tmp permissions.'];
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
    if ($encryption_key['type'] === 'passphrase') {
        $args .= " -p " . escapeshellarg($encryption_key['value']);
    } else {
        $args .= " -k " . escapeshellarg($encryption_key['value']);
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
if ($headers_only !== 'true') {
    if ($encryption_key['type'] === 'passphrase') {
        $env['LUKS_PASSPHRASE'] = $encryption_key['value'];
    } else {
        $env['LUKS_KEYFILE'] = $encryption_key['value'];
    }
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
            
            // Ensure download directory exists
            if (!is_dir($plugin_download_dir)) {
                mkdir($plugin_download_dir, 0755, true);
            }
            
            // Remove any existing symlink and create new one
            if (file_exists($symlink_path)) {
                unlink($symlink_path);
            }
            
            if (symlink($backup_file, $symlink_path)) {
                $output .= "\nDOWNLOAD_READY: $symlink_path";
            } else {
                $output .= "\nWarning: Could not create download link.";
            }
        }
    }

    echo $output;
} else {
    echo "Error: Failed to execute the script process (proc_open failed).";
    exit(1);
}

// Clean up temporary keyfile if one was created
if ($encryption_key['type'] === 'keyfile' && file_exists($encryption_key['value'])) {
    unlink($encryption_key['value']);
}
?>
