<?php
header('Content-Type: text/plain');

// Get POST data
$passphrase = escapeshellarg($_POST['passphrase'] ?? '');
$backupHeaders = escapeshellarg($_POST['backupHeaders'] ?? 'yes');
$dryRun = escapeshellarg($_POST['dryRun'] ?? 'yes');

if (empty($passphrase)) {
    echo "Error: Passphrase is required.";
    exit(1);
}

// Construct and execute the bash command
$command = "/usr/local/emhttp/plugins/unraid.luks.tools/scripts/luks.sh" $passphrase $dryRun $backupHeaders 2>&1";
$output = shell_exec($command);

if ($output === null) {
    echo "Error: Failed to execute the script.";
    exit(1);
}

// Output the script result
echo $output;
?>
