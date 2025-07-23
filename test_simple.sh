#!/bin/bash

# Simple test - just extract slots from unraid-derived tokens by looking between the right boundaries
extract_derived_slots() {
    local json_file="$1"
    
    # Use grep and sed to extract slots from unraid-derived tokens
    grep -A 10 '"type".*"unraid-derived"' "$json_file" | \
    grep '"keyslots"' | \
    sed -E 's/.*"keyslots"[^[]*\[([^]]*)\].*/\1/' | \
    grep -oE '"[0-9]+"' | \
    sed 's/"//g'
}

# Test the function
echo "Testing simple extract_derived_slots function:"
extract_derived_slots /tmp/test_tokens.json