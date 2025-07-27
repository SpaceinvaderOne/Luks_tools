<?php
// Include Unraid's webGUI session handling for CSRF validation
require_once '/usr/local/emhttp/webGUI/include/Wrappers.php';

// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Define paths
$info_script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/luks_info_viewer.sh";
$download_temp_dir = "/tmp/luksheaders";
$plugin_download_dir = "/usr/local/emhttp/plugins/luks-key-management/downloads";

// --- Get POST data from the UI ---
$key_type = $_POST['keyType'] ?? 'passphrase';
$detail_level = $_POST['detailLevel'] ?? 'detailed';

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
        // Handle keyfile data (base64 encoded, following Unraid pattern)
        if (!isset($_POST['keyfileData'])) {
            return ['error' => 'No keyfile data provided.'];
        }
        
        $keyfile_data = $_POST['keyfileData'];
        
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
        
        // Validate file size (8 MiB limit)
        if (strlen($decoded_data) > 8388608) {
            return ['error' => 'Keyfile exceeds 8 MiB limit (Unraid standard).'];
        }
        
        // Create secure temporary file
        $temp_keyfile = "/tmp/luks_keyfile_" . uniqid() . ".key";
        if (file_put_contents($temp_keyfile, $decoded_data) === false) {
            return ['error' => 'Failed to write keyfile data.'];
        }
        
        // Set secure permissions (read-only for owner)
        chmod($temp_keyfile, 0600);
        
        return ['type' => 'keyfile', 'value' => $temp_keyfile];
    }
}

// Process the encryption key
$encryption_key = processEncryptionKey();
if (isset($encryption_key['error'])) {
    echo "Error: " . $encryption_key['error'];
    exit(1);
}

// Validate detail level
if (!in_array($detail_level, ['simple', 'detailed', 'very_detailed'])) {
    echo "Error: Invalid detail level. Must be 'simple', 'detailed', or 'very_detailed'.";
    exit(1);
}

// Generate timestamp for unique filename
$timestamp = date('Ymd_His');
$analysis_filename = "luks_encryption_analysis_{$timestamp}.txt";
$temp_analysis_file = "$download_temp_dir/$analysis_filename";
$zip_filename = "luks_encryption_analysis_{$timestamp}.zip";
$temp_zip_file = "$download_temp_dir/$zip_filename";
$symlink_path = "$plugin_download_dir/$zip_filename";

echo "Generating encryption analysis report...\n";

// Create temp directory
if (!is_dir($download_temp_dir)) {
    mkdir($download_temp_dir, 0755, true);
}

// --- Execute the encryption info script to generate analysis ---
$descriptorspec = array(
   0 => array("pipe", "r"),  // stdin
   1 => array("file", $temp_analysis_file, "w"),  // stdout to file
   2 => array("pipe", "w")   // stderr
);

$command = "$info_script_path -d " . escapeshellarg($detail_level);
$env = array(
    'PATH' => '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin'
);

if ($encryption_key['type'] === 'passphrase') {
    $env['LUKS_PASSPHRASE'] = $encryption_key['value'];
} else {
    $env['LUKS_KEYFILE'] = $encryption_key['value'];
}

$process = proc_open($command, $descriptorspec, $pipes, null, $env);

if (is_resource($process)) {
    // Close stdin
    fclose($pipes[0]);
    
    // Read any errors
    $errors = stream_get_contents($pipes[2]);
    fclose($pipes[2]);
    
    $return_value = proc_close($process);
    
    if ($return_value !== 0) {
        echo "Error: Failed to generate encryption analysis.\n";
        if (!empty($errors)) {
            echo "Details: $errors\n";
        }
        exit(1);
    }
} else {
    echo "Error: Failed to execute encryption analysis script.\n";
    exit(1);
}

// Check if analysis file was created
if (!file_exists($temp_analysis_file)) {
    echo "Error: Analysis file was not generated.\n";
    exit(1);
}

echo "Analysis generated successfully.\n";
echo "Creating encrypted archive...\n";

// Create encrypted ZIP archive using appropriate password
$zip_password = ($encryption_key['type'] === 'passphrase') ? $encryption_key['value'] : file_get_contents($encryption_key['value']);
$zip_command = "cd " . escapeshellarg($download_temp_dir) . " && echo " . escapeshellarg($zip_password) . " | zip -e --password-from-stdin " . escapeshellarg($zip_filename) . " " . escapeshellarg($analysis_filename) . " 2>&1";

$zip_output = shell_exec($zip_command);
$zip_exit_code = 0;
exec("cd " . escapeshellarg($download_temp_dir) . " && echo " . escapeshellarg($zip_password) . " | zip -e --password-from-stdin " . escapeshellarg($zip_filename) . " " . escapeshellarg($analysis_filename), $zip_result, $zip_exit_code);

if ($zip_exit_code !== 0 || !file_exists($temp_zip_file)) {
    echo "Error: Failed to create encrypted archive.\n";
    echo "Output: $zip_output\n";
    exit(1);
}

echo "Encrypted archive created successfully.\n";

// Create symlink in plugin directory for browser access
if (!is_dir($plugin_download_dir)) {
    mkdir($plugin_download_dir, 0755, true);
}

// Remove any existing symlink and create new one
if (file_exists($symlink_path)) {
    unlink($symlink_path);
}

if (symlink($temp_zip_file, $symlink_path)) {
    echo "Final encrypted analysis archive created.\n";
    echo "Archive includes detailed encryption analysis for download.\n";
    echo "\nDOWNLOAD_READY: $symlink_path\n";
    
    // Clean up the temporary analysis file (keep the zip for download)
    unlink($temp_analysis_file);
    
    // Clean up temporary keyfile if one was created
    if ($encryption_key['type'] === 'keyfile' && file_exists($encryption_key['value'])) {
        unlink($encryption_key['value']);
    }
} else {
    echo "Warning: Could not create download link.\n";
    
    // Clean up temporary keyfile if one was created
    if ($encryption_key['type'] === 'keyfile' && file_exists($encryption_key['value'])) {
        unlink($encryption_key['value']);
    }
}
?>