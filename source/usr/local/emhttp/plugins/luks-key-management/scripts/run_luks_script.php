<?php
// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Define the absolute path to your main LUKS management script
// IMPORTANT: Update this path to match your plugin's structure.
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

// --- Build the Shell Command Arguments (Password is now sent via stdin) ---
$args = "";
if ($backup_headers_option === 'yes') {
    $args .= " -b";
}
if ($dry_run_option === 'yes') {
    $args .= " -d";
}

$command = $script_path . $args;

// --- Execute the Command using proc_open for secure password handling ---

// Define the process descriptors
$descriptorspec = array(
   0 => array("pipe", "r"),  // stdin is a pipe that we can write to
   1 => array("pipe", "w"),  // stdout is a pipe that we can read from
   2 => array("pipe", "w")   // stderr is a pipe that we can read from
);

// Start the process
$process = proc_open($command, $descriptorspec, $pipes);

if (is_resource($process)) {
    // Write the raw passphrase to the script's standard input
    fwrite($pipes[0], $passphrase);
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
    echo "Error: Failed to execute the script process.";
    exit(1);
}
?>
