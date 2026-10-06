#!/bin/zsh
# Re-links the upstream macshot sources (everything except its menu-bar
# AppDelegate and main.swift) into the Studio target, then applies the small
# compatibility patches in patches/. Run again after `git pull` in macshot.
set -euo pipefail
HERE=${0:A:h}
UPSTREAM=${${MACSHOT_SRC:-$HERE/../macshot/macshot}:A}
DEST=$HERE/Sources/MacshotStudio/Upstream

[[ -f $UPSTREAM/AppDelegate.swift ]] || { echo "macshot sources not found at $UPSTREAM (set MACSHOT_SRC)"; exit 1; }

rm -rf "${DEST:?}" && mkdir -p "$DEST"
cd "$UPSTREAM"
for f in **/*.swift; do
  [[ $f == AppDelegate.swift || $f == main.swift ]] && continue
  mkdir -p "$DEST/${f:h}"
  ln -s "$UPSTREAM/$f" "$DEST/$f"
done
echo "Linked $(find "$DEST" -name '*.swift' | wc -l | tr -d ' ') files from $UPSTREAM"

# Patched files become real copies so the upstream checkout stays untouched.
for p in $HERE/patches/*.patch(N); do
  target=$(sed -n 's|^+++ b/\([^[:space:]]*\).*|\1|p' "$p" | head -1)
  rm "$DEST/$target" && cp "$UPSTREAM/$target" "$DEST/$target"
  if patch -s -p1 -d "$DEST" < "$p"; then
    echo "Applied ${p:t}"
  else
    echo "warning: ${p:t} no longer applies (upstream may have fixed it); using upstream file"
    cp "$UPSTREAM/$target" "$DEST/$target"
    rm -f "$DEST/$target.orig" "$DEST/$target.rej"
  fi
done
