<?php
// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');


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

// --- Build the Shell Command Safely ---

$command = $script_path . " -p " . escapeshellarg($passphrase);

// Conditionally add the other flags based on the user's selection.
if ($backup_headers_option === 'yes') {
    $command .= " -b";
}

if ($dry_run_option === 'yes') {
    $command .= " -d";
}

// Redirect standard error to standard output (2>&1) so we can capture all output
$command .= " 2>&1";

// --- Execute the Command ---

// Use shell_exec() to run the command and capture its output.
$output = shell_exec($command);

// --- Return the Output ---

// Check if the command failed to execute
if ($output === null) {
    echo "Error: Failed to execute the script. Check permissions and paths.";
    exit(1);
}

// Echo the output from the shell script back to the UI
echo $output;
?>
