#!/usr/bin/env bash
# Install memo from the bind-mounted checkout into the container's system python.
#
# The image bakes only the heavy stack (torch, transformers, TensorRT, Edge-LLM);
# memo is never copied in. This installs, in order:
#   1. memo's light runtime deps (src/memo/memo_deployment/requirements.txt),
#      constrained to the image's frozen versions so none of the heavy stack moves
#   2. external/pymlg, if its submodule is checked out
#   3. memo itself, editable and without deps -- its full dependency list
#      targets the research machines (pycolmap, decord, ...) and has no aarch64
#      wheels for some of them
#
# /etc/profile.d/zz-memo.sh runs this with --if-needed on every login shell; it
# returns immediately once this container is set up, and redoes the work when
# requirements.txt or pymlg changes. Run it by hand to force a reinstall.
#
# The container runs as the host user, not root; the system site-packages belong to root, so the installs go
# through the image's passwordless sudo. Nothing is written into the bind-mounted checkout (pymlg builds from a
# copy, memo's editable install only adds a .pth to site-packages), so no root-owned files appear on the host.
set -euo pipefail

WS="${ROS_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MEMO="$WS/src/memo"
REQS="$MEMO/memo_deployment/requirements.txt"
PYMLG="$MEMO/external/pymlg"
CONSTRAINTS=/etc/memo/constraints.txt
# Container-local, so a fresh (--rm) container installs again.
STAMP=/var/tmp/memo-setup.stamp

if [ ! -f "$MEMO/pyproject.toml" ]; then
  echo "setup_memo: no memo checkout at $MEMO; skipping." >&2
  exit 0
fi

key="$(cat "$REQS" "$MEMO/pyproject.toml" 2>/dev/null; git -C "$PYMLG" rev-parse HEAD 2>/dev/null || true)"
key="$(printf '%s' "$key" | sha256sum | cut -d' ' -f1)"

# Several shells start at once under tmux; only one installs.
exec 9>"$STAMP.lock"
flock 9

if [ "${1:-}" = "--if-needed" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$key" ]; then
  exit 0
fi

echo "setup_memo: installing memo from $MEMO into /usr/bin/python3 ..."
as_root=()
[ "$(id -u)" -ne 0 ] && as_root=(sudo -n env HOME=/root UV_CACHE_DIR=/root/.cache/uv)
uv_pip() {
  "${as_root[@]}" uv pip install --quiet --system --break-system-packages --python /usr/bin/python3 "$@"
}
constraints=()
[ -f "$CONSTRAINTS" ] && constraints=(--constraint "$CONSTRAINTS")

if ! {
  uv_pip "${constraints[@]}" -r "$REQS" &&
  if [ -f "$PYMLG/setup.py" ] || [ -f "$PYMLG/pyproject.toml" ]; then
    # Built from a copy: its setup.py writes egg-info into the source tree.
    tmp="$(mktemp -d)" &&
    cp -r "$PYMLG/." "$tmp" && rm -rf "$tmp/.git" &&
    uv_pip --no-deps "$tmp" &&
    "${as_root[@]}" rm -rf "$tmp"  # the build (as root) left root-owned files in the copy
  else
    echo "setup_memo: $PYMLG is empty; memo.geometry.transforms will not import." >&2
    echo "            git -C $MEMO submodule update --init external/pymlg" >&2
  fi &&
  uv_pip --no-deps --editable "$MEMO"
}; then
  echo "setup_memo: install failed; rerun $0 once the cause is fixed." >&2
  exit 1
fi

echo "$key" > "$STAMP"
echo "setup_memo: done."
