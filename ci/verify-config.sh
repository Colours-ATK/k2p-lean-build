#!/usr/bin/env bash
set -euo pipefail
seed=$1
actual=$2
failed=0
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    CONFIG_*=y)
      if ! grep -Fxq -- "$line" "$actual"; then
        printf 'Missing required setting: %s\n' "$line" >&2
        failed=1
      fi
      ;;
    '# CONFIG_'*' is not set')
      symbol=${line#\# }
      symbol=${symbol% is not set}
      if grep -Eq "^${symbol}=(y|m)$" "$actual"; then
        printf 'Forbidden setting enabled: %s\n' "$symbol" >&2
        failed=1
      fi
      ;;
  esac
done < "$seed"
exit "$failed"
