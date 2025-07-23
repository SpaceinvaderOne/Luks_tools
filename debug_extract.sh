#!/bin/bash

extract_derived_slots() {
    local json_file="$1"
    local slots=()
    local in_unraid_token=false
    
    echo "DEBUG: Starting to parse $json_file"
    
    # Look for unraid-derived tokens and extract their keyslots
    while IFS= read -r line; do
        echo "DEBUG: Reading line: $line"
        
        # Check if we're entering an unraid-derived token
        if [[ "$line" =~ \"type\"[[:space:]]*:[[:space:]]*\"unraid-derived\" ]]; then
            echo "DEBUG: Found unraid-derived token"
            in_unraid_token=true
            continue
        fi
        
        # If we're in an unraid-derived token, look for keyslots line
        if [[ "$in_unraid_token" == true ]]; then
            echo "DEBUG: In unraid token, examining line for keyslots"
            # Handle keyslots on single line: "keyslots": ["3", "5"],
            if [[ "$line" =~ \"keyslots\".*\[(.*)\] ]]; then
                local keyslots_content="${BASH_REMATCH[1]}"
                echo "DEBUG: Found keyslots content: $keyslots_content"
                # Extract all numbers from the keyslots array
                while [[ "$keyslots_content" =~ \"([0-9]+)\" ]]; do
                    echo "DEBUG: Adding slot ${BASH_REMATCH[1]}"
                    slots+=("${BASH_REMATCH[1]}")
                    keyslots_content="${keyslots_content/${BASH_REMATCH[0]}/}"
                done
            elif [[ "$line" =~ ^\s*\}[,]?\s*$ ]]; then
                # End of this token object
                echo "DEBUG: End of token object"
                in_unraid_token=false
            fi
        fi
    done < "$json_file"
    
    printf '%s\n' "${slots[@]}"
}

# Test the function
echo "Testing extract_derived_slots function with debug:"
extract_derived_slots /tmp/test_tokens.json