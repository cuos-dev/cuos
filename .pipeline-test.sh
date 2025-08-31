#!/bin/bash

status=0

while IFS= read -r -d '' file; do
    echo "Running: $file"
    if ! bash "$file"; then
        echo "❌ Failed: $file"
        status=1
    fi
done < <(find . -type f -name "*.test.sh" -print0)

exit "${status}"
