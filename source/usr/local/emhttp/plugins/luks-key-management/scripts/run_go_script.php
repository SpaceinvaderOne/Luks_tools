<?php
// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Define the absolute path to your 'go file' management script
// IMPORTANT: Update this path to match your plugin's structure.
$script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/write_go.sh";

// --- Get POST data from the UI ---
$action = $_POST['action'] ?? 'add'; // Default to 'add' if nothing is received

// --- Build the Shell Command ---
$command = $script_path;

// If the user selected 'remove', add the -r flag to the command.
if ($action === 'remove') {
    $command .= " -r";
}

// Redirect standard error to standard output (2>&1) so we can capture all output
$command .= " 2>&1";

// --- Execute the Command ---
$output = shell_exec($command);

// --- Return the Output ---
if ($output === null) {
    echo "Error: Failed to execute the script. Check permissions and paths.";
    exit(1);
}

echo $output;
?>
