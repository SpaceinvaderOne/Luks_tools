<?php
// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Define paths
$info_script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/luks_info_viewer.sh";
$download_temp_dir = "/tmp/luksheaders";
$plugin_download_dir = "/usr/local/emhttp/plugins/luks-key-management/downloads";

// --- Get POST data from the UI ---
$passphrase = $_POST['passphrase'] ?? '';
$detail_level = $_POST['detailLevel'] ?? 'detailed';

// --- Validate Inputs ---
if (empty($passphrase)) {
    echo "Error: Passphrase is required for encryption analysis download.";
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
    'LUKS_PASSPHRASE' => $passphrase,
    'PATH' => '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin'
);

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

// Create encrypted ZIP archive
$zip_command = "cd " . escapeshellarg($download_temp_dir) . " && echo " . escapeshellarg($passphrase) . " | zip -e --password-from-stdin " . escapeshellarg($zip_filename) . " " . escapeshellarg($analysis_filename) . " 2>&1";

$zip_output = shell_exec($zip_command);
$zip_exit_code = 0;
exec("cd " . escapeshellarg($download_temp_dir) . " && echo " . escapeshellarg($passphrase) . " | zip -e --password-from-stdin " . escapeshellarg($zip_filename) . " " . escapeshellarg($analysis_filename), $zip_result, $zip_exit_code);

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
} else {
    echo "Warning: Could not create download link.\n";
}
?>