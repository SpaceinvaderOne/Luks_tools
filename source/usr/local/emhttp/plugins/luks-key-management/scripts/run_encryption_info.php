<?php
// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Define the absolute path to the encryption info viewer script
$script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/luks_info_viewer.sh";

// --- Get POST data from the UI ---
$passphrase = $_POST['passphrase'] ?? '';
$detail_level = $_POST['detailLevel'] ?? 'simple';

// --- Validate Inputs ---
if (empty($passphrase)) {
    echo "Error: Passphrase is required for encryption analysis.";
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

// Pass the passphrase securely as an environment variable
$env = array(
    'LUKS_PASSPHRASE' => $passphrase,
    'PATH' => '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin'
);

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
?>