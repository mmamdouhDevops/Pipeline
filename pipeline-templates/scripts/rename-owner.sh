#!/usr/bin/env bash
# =============================================================================================
#  rename-owner.sh – point every `uses:` reference at YOUR copy of the templates repository.
#    scripts/rename-owner.sh <new-owner>[/<repo-name>] [--ref v1] [--dir .]
#  Run it in this repo (and in consumer repos you copied the examples into), then commit and re-tag v1.
# =============================================================================================
set -euo pipefail
[[ $# -ge 1 ]] || { sed -n '2,6p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }
NEW="$1"; shift; REF=""; DIR="."
while [[ $# -gt 0 ]]; do case "$1" in --ref) REF="$2"; shift 2;; --dir) DIR="$2"; shift 2;; *) exit 1;; esac; done
[[ "$NEW" == */* ]] || NEW="$NEW/pipeline-templates"
OLD="mmamdouhDevops/pipeline-templates"
mapfile -t files < <(grep -rlF --include='*.yml' --include='*.yaml' --include='*.md' "$OLD" "$DIR" || true)
for f in "${files[@]}"; do
  sed -i "s#${OLD}/#${NEW}/#g; s#${OLD}\b#${NEW}#g" "$f"
  [[ -n "$REF" ]] && sed -i -E "s#(${NEW}/[^@ ]+)@v[0-9]+#\1@${REF}#g" "$f"
  echo "updated $f"
done
echo "${#files[@]} file(s) now reference $NEW${REF:+@$REF}"
