#!/bin/sh
# Compile-checks the extension with the AL compiler of the VS Code AL extension (no BC server needed).
cd "$(dirname "$0")/.."
ALC=$(ls -d "$USERPROFILE"/.vscode/extensions/ms-dynamics-smb.al-*/bin/alc.exe | tail -1)
OUT="${1:-$TEMP/galaga-compile.app}"
MSYS_NO_PATHCONV=1 "$ALC" /project:"$(cygpath -w "$PWD")" /packagecachepath:"$(cygpath -w "$PWD/.alpackages")" /out:"$(cygpath -w "$OUT")" /generatecode+ | grep -v '^$' | grep -v 'Microsoft (R)\|Copyright'
