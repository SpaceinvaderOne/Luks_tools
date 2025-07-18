<?php
// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Define the absolute path to your main LUKS management script
$script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/luks_management.sh";

// --- Get POST data from the UI ---
$passphrase = $_POST['passphrase'] ?? '';
$backup_headers_option = $_POST['backupHeaders'] ?? 'no';
$dry_run_option = $_POST['dryRun'] ?? 'yes';

// --- Validate Inputs ---
if (empty($passphrase)) {
    echo "Error: Passphrase is required.";
    exit(1);
}

// --- Build the Shell Command Arguments ---
$args = "";
if ($backup_headers_option === 'yes' || $backup_headers_option === 'download') {
    $args .= " -b";
}
if ($dry_run_option === 'yes') {
    $args .= " -d";
}
// Pass the backup option to the script so it knows where to save
if ($backup_headers_option === 'download') {
    $args .= " --download-mode";
}

$command = $script_path . $args;

// --- Execute the Command using proc_open ---

// Define the process descriptors
$descriptorspec = array(
   0 => array("pipe", "r"),  // stdin
   1 => array("pipe", "w"),  // stdout
   2 => array("pipe", "w")   // stderr
);

// THE FIX: Pass the passphrase securely as an environment variable.
// We also explicitly provide a standard PATH to ensure the script can find system commands.
$env = array(
    'LUKS_PASSPHRASE' => $passphrase,
    'PATH' => '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin'
);

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
?>
