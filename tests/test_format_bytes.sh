#!/usr/bin/env bash

# Source the main script to get the format_bytes function
# We use a dummy directory and mock variables to prevent any execution if sourceability guard fails
TARGET_DIR="/tmp"
source "./media-scrubber.sh"

failed_tests=0
total_tests=0

assert_format_bytes() {
    local bytes=$1
    local expected=$2
    local actual
    actual=$(format_bytes "$bytes")
    ((total_tests++))
    if [[ "$actual" == "$expected" ]]; then
        echo "✅ PASS: format_bytes $bytes -> $actual"
    else
        echo "❌ FAIL: format_bytes $bytes -> expected '$expected', got '$actual'"
        ((failed_tests++))
    fi
}

echo "Running tests for format_bytes..."

# Test cases
assert_format_bytes "0" "0.00 B"
assert_format_bytes "512" "512.00 B"
assert_format_bytes "1023" "1023.00 B"
assert_format_bytes "1024" "1.00 KB"
assert_format_bytes "1536" "1.50 KB"
assert_format_bytes "1048575" "1024.00 KB"
assert_format_bytes "1048576" "1.00 MB"
assert_format_bytes "1073741824" "1.00 GB"
assert_format_bytes "1099511627776" "1.00 TB"
assert_format_bytes "1125899906842624" "1024.00 TB"

echo "------------------------------------------------"
echo "Tests completed: $total_tests, Failed: $failed_tests"

if [[ $failed_tests -gt 0 ]]; then
    exit 1
else
    exit 0
fi
