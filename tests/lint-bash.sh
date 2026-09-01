#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${REPO_ROOT}"

declare -A seen=()
while IFS= read -r -d '' file; do
  seen["${file}"]=1
done < <(git ls-files -z --cached --others --exclude-standard -- '*.sh' '*.bash' '*bashrc')
while IFS= read -r -d '' file; do
  seen["${file}"]=1
done < <(git grep -Ilz -e '^#!.*bash' -- . || true)

mapfile -d '' bash_files < <(
  for file in "${!seen[@]}"; do
    [[ -f ${file} ]] && printf '%s\0' "${file}"
  done | sort -z
)
(( ${#bash_files[@]} )) || { printf 'No Bash files discovered.\n' >&2; exit 1; }

printf 'Discovered %s Bash files:\n' "${#bash_files[@]}"
printf '  %s\n' "${bash_files[@]}"

for file in "${bash_files[@]}"; do
  bash -n -- "${file}"
done
shellcheck -S warning -- "${bash_files[@]}"
printf 'Bash syntax and ShellCheck: PASS\n'
