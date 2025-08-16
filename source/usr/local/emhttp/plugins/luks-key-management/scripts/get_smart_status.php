<?php
// Include Unraid's webGUI session handling for CSRF validation
$docroot = $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
require_once "$docroot/webGui/include/Wrappers.php";

// Set content type to JSON
header('Content-Type: application/json');

// Define the absolute path to the event management script
$script_path = "/usr/local/emhttp/plugins/luks-key-management/scripts/manage_events.sh";

// Function to execute command and get result
function executeCommand($action) {
    global $script_path;
    
    $command = array($script_path, $action);
    
    $descriptorspec = array(
        0 => array("pipe", "r"),  // stdin
        1 => array("pipe", "w"),  // stdout
        2 => array("pipe", "w"),  // stderr
    );
    
    $process = proc_open($command, $descriptorspec, $pipes);
    
    if (is_resource($process)) {
        fclose($pipes[0]);
        
        $output = trim(stream_get_contents($pipes[1]));
        $errors = trim(stream_get_contents($pipes[2]));
        
        fclose($pipes[1]);
        fclose($pipes[2]);
        
        $return_code = proc_close($process);
        
        if ($return_code === 0) {
            return $output;
        } else {
            return false;
        }
    }
    
    return false;
}

// Get all status information
$status = array();

// Get system state
$system_state = executeCommand('system_state');
$status['system_state'] = $system_state ?: 'unknown';

// Get auto-unlock enabled status
$auto_unlock_status = executeCommand('get_status');
$status['auto_unlock_enabled'] = ($auto_unlock_status === 'enabled');

// Get hardware fingerprint
$hardware_fingerprint = executeCommand('hardware_fingerprint');
$status['hardware_fingerprint'] = $hardware_fingerprint ?: 'unknown';

// Get unlockable devices
$unlockable_devices = executeCommand('unlockable_devices');
$status['unlockable_devices'] = $unlockable_devices ?: 'none';

// Check if keys exist
$keys_exist = executeCommand('check_keys_exist');
$status['keys_exist'] = ($keys_exist === 'true');

// Test if keys work
$keys_work = executeCommand('test_keys_work');
$status['keys_work'] = ($keys_work === 'true');

// Add timestamp
$status['timestamp'] = date('Y-m-d H:i:s');

// Return JSON response
echo json_encode($status, JSON_PRETTY_PRINT);
?>