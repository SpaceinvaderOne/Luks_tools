#!/bin/bash

extract_derived_slots() {
    local json_file="$1"
    
    # Use awk to properly parse the JSON structure
    awk '
    BEGIN { in_unraid_token = 0; collecting_slots = 0 }
    
    # Found unraid-derived token
    /"type"[[:space:]]*:[[:space:]]*"unraid-derived"/ {
        in_unraid_token = 1
        next
    }
    
    # If we are in an unraid-derived token
    in_unraid_token == 1 {
        # Look for keyslots line
        if (/"keyslots"[[:space:]]*:[[:space:]]*\[/) {
            # Extract slots from current line if they are all on one line
            if (/\]/) {
                # Single line format: "keyslots": ["3", "5"],
                gsub(/.*"keyslots"[^[]*\[/, "")
                gsub(/\].*/, "")
                gsub(/"/, "")
                gsub(/[[:space:]]/, "")
                split($0, slots, ",")
                for (i in slots) {
                    if (slots[i] ~ /^[0-9]+$/) print slots[i]
                }
            } else {
                collecting_slots = 1
            }
            next
        }
        
        # If collecting multi-line slots
        if (collecting_slots == 1) {
            if (/\]/) {
                collecting_slots = 0
            } else if (/"[0-9]+"/) {
                gsub(/"/, "")
                gsub(/[^0-9]/, "")
                if ($0 ~ /^[0-9]+$/) print $0
            }
            next
        }
        
        # End of token (closing brace with optional comma)
        if (/^[[:space:]]*}[[:space:]]*,?[[:space:]]*$/) {
            in_unraid_token = 0
            next
        }
    }
    ' "$json_file"
}

# Test the function
echo "Testing awk-based extract_derived_slots function:"
extract_derived_slots /tmp/test_tokens.json