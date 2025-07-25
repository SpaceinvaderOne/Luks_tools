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
echo "DEBUG: All POST data: " . print_r($_POST, true) . "\n";
echo "DEBUG: All FILES data: " . print_r($_FILES, true) . "\n";

// Define the absolute path to the encryption info viewer script
$script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/luks_info_viewer.sh";

// --- Get POST data from the UI ---
$key_type = $_POST['keyType'] ?? 'passphrase';
$detail_level = $_POST['detailLevel'] ?? 'simple';

// --- Process Encryption Key Input (reusing function from run_luks_script.php) ---
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
        // Handle keyfile upload
        if (!isset($_FILES['keyfile']) || $_FILES['keyfile']['error'] !== UPLOAD_ERR_OK) {
            return ['error' => 'Keyfile upload failed or no file provided.'];
        }
        
        $uploaded_file = $_FILES['keyfile'];
        
        // Validate file size (8 MiB limit)
        if ($uploaded_file['size'] > 8388608) {
            return ['error' => 'Keyfile exceeds 8 MiB limit (Unraid standard).'];
        }
        
        // Create secure temporary file
        $temp_keyfile = "/tmp/luks_keyfile_" . uniqid() . ".key";
        if (!move_uploaded_file($uploaded_file['tmp_name'], $temp_keyfile)) {
            return ['error' => 'Failed to process keyfile upload.'];
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

// --- Build the Shell Command Arguments ---
$args = "";
$args .= " -d " . escapeshellarg($detail_level);

$command = $script_path . $args;

// --- Execute the Command using proc_open ---

// Define the process descriptors
$descriptorspec = array(
   0 => array("pipe", "r"),  // stdin
   1 => array("pipe", "w"),  // stdout
   2 => array("pipe", "w")   // stderr
);

// Pass the encryption key securely as an environment variable
$env = array(
    'PATH' => '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin'
);

if ($encryption_key['type'] === 'passphrase') {
    $env['LUKS_PASSPHRASE'] = $encryption_key['value'];
} else {
    $env['LUKS_KEYFILE'] = $encryption_key['value'];
}

// Start the process with the explicit environment
$process = proc_open($command, $descriptorspec, $pipes, null, $env);

if (is_resource($process)) {
    // We don't need to write to stdin, so close it immediately
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

    echo $output;
} else {
    echo "Error: Failed to execute the encryption analysis script (proc_open failed).";
    exit(1);
}

// Clean up temporary keyfile if one was created
if ($encryption_key['type'] === 'keyfile' && file_exists($encryption_key['value'])) {
    unlink($encryption_key['value']);
}
?>