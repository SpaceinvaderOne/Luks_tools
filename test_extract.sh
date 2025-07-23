#!/bin/bash

# Source the updated function from luks_management.sh
extract_derived_slots() {
    local json_file="$1"
    local slots=()
    local in_unraid_token=false
    
    # Look for unraid-derived tokens and extract their keyslots
    while IFS= read -r line; do
        # Check if we're entering an unraid-derived token
        if [[ "$line" =~ \"type\"[[:space:]]*:[[:space:]]*\"unraid-derived\" ]]; then
            in_unraid_token=true
            continue
        fi
        
        # If we're in an unraid-derived token, look for keyslots line
        if [[ "$in_unraid_token" == true ]]; then
            # Handle keyslots on single line: "keyslots": ["3", "5"],
            if [[ "$line" =~ \"keyslots\".*\[(.*)\] ]]; then
                local keyslots_content="${BASH_REMATCH[1]}"
                # Extract all numbers from the keyslots array
                while [[ "$keyslots_content" =~ \"([0-9]+)\" ]]; do
                    slots+=("${BASH_REMATCH[1]}")
                    keyslots_content="${keyslots_content/${BASH_REMATCH[0]}/}"
                done
            # Handle multi-line keyslots format
            elif [[ "$line" =~ \"keyslots\"[[:space:]]*:[[:space:]]*\[ ]]; then
                # Continue reading lines until we find the closing bracket
                while IFS= read -r keyslot_line; do
                    if [[ "$keyslot_line" =~ \"([0-9]+)\" ]]; then
                        slots+=("${BASH_REMATCH[1]}")
                    elif [[ "$keyslot_line" =~ \] ]]; then
                        break
                    fi
                done
            elif [[ "$line" =~ ^\s*\}[,]?\s*$ ]]; then
                # End of this token object
                in_unraid_token=false
            fi
        fi
    done < "$json_file"
    
    printf '%s\n' "${slots[@]}"
}

# Test the function
echo "Testing extract_derived_slots function:"
extract_derived_slots /tmp/test_tokens.json