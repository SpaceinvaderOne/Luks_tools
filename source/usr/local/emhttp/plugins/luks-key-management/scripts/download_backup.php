<?php
// Security check - only allow access from local server
if (!in_array($_SERVER['REMOTE_ADDR'], ['127.0.0.1', '::1', $_SERVER['SERVER_ADDR']])) {
    http_response_code(403);
    exit('Access denied');
}

// Get the backup file path from POST data
$backup_file = $_POST['backup_file'] ?? '';

// Validate the file path for security
if (empty($backup_file) || !file_exists($backup_file)) {
    http_response_code(404);
    exit('Backup file not found');
}

// Ensure the file is within the expected backup directory
$backup_dir = '/boot/config/luksheaders/';
$real_path = realpath($backup_file);
$real_backup_dir = realpath($backup_dir);

if (!$real_path || !$real_backup_dir || strpos($real_path, $real_backup_dir) !== 0) {
    http_response_code(403);
    exit('Invalid file path');
}

// Ensure it's a zip file
if (pathinfo($backup_file, PATHINFO_EXTENSION) !== 'zip') {
    http_response_code(400);
    exit('Invalid file type');
}

// Get file size and name
$file_size = filesize($backup_file);
$file_name = basename($backup_file);

// Set headers for file download
header('Content-Type: application/zip');
header('Content-Disposition: attachment; filename="' . $file_name . '"');
header('Content-Length: ' . $file_size);
header('Cache-Control: no-cache, must-revalidate');
header('Pragma: no-cache');
header('Expires: 0');

// Output the file
if ($file_size > 0) {
    $handle = fopen($backup_file, 'rb');
    if ($handle) {
        while (!feof($handle)) {
            echo fread($handle, 8192);
            flush();
        }
        fclose($handle);
    } else {
        http_response_code(500);
        exit('Error reading file');
    }
} else {
    http_response_code(500);
    exit('Empty file');
}

// Optionally delete the file after download (uncomment if desired)
// unlink($backup_file);
?>