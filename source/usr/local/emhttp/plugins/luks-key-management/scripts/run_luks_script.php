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

    echo $output;
} else {
    echo "Error: Failed to execute the script process (proc_open failed).";
    exit(1);
}
?>
