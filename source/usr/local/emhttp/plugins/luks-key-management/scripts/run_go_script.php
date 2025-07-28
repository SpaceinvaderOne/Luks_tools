<?php
// Include Unraid's webGUI session handling for CSRF validation (using official pattern)
$docroot = $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
require_once "$docroot/webGui/include/Wrappers.php";

// Set the content type to plain text to ensure the output is displayed correctly
header('Content-Type: text/plain');

// Display clean process header
echo "================================================\n";
echo "        GO FILE CONFIGURATION PROCESS\n";
echo "================================================\n\n";

// Define the absolute path to your 'go file' management script
// IMPORTANT: Update this path to match your plugin's structure.
$script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/write_go.sh";

// --- Get POST data from the UI ---
$action = $_POST['action'] ?? 'add'; // Default to 'add' if nothing is received

// --- Build the Shell Command ---
$command = array($script_path);

// If the user selected 'remove', add the -r flag to the command.
if ($action === 'remove') {
    $command[] = "-r";
}

// --- Execute the Command using proc_open ---
$descriptorspec = array(
    0 => array("pipe", "r"),  // stdin
    1 => array("pipe", "w"),  // stdout
    2 => array("pipe", "w"),  // stderr
);

$process = proc_open($command, $descriptorspec, $pipes);

if (is_resource($process)) {
    // Close stdin as we don't need to send input
    fclose($pipes[0]);
    
    // Read stdout and stderr
    $output = stream_get_contents($pipes[1]);
    $errors = stream_get_contents($pipes[2]);
    
    // Close pipes
    fclose($pipes[1]);
    fclose($pipes[2]);
    
    // Wait for the process to terminate and get return code
    $return_code = proc_close($process);
    
    // Combine output and errors if needed
    if (!empty($errors)) {
        $output .= "\n--- SCRIPT ERRORS ---\n" . $errors;
    }
    
    echo $output;
    
    // Add clean completion footer
    echo "\n================================================\n";
    echo "           PROCESS COMPLETE ✅\n"; 
    echo "================================================\n";
} else {
    echo "Error: Failed to execute the script. Check permissions and paths.";
    exit(1);
}
?>
