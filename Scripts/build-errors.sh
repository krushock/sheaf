#!/bin/sh
# Prints one line per compiler error or warning from a build log on stdin.
sed 's/\x1b\[[0-9;]*m//g' | grep -E "^/.*(error|warning): |^[^|]*: (error|note): " | grep -v "^error: SwiftCompile\|^error: Build failed\|^error: fatalError" | sed 's/ \[#.*//' | sort -u | cut -c1-260 | head -${1:-40}
