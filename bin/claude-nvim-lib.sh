# bin/claude-nvim-lib.sh
# Shared by claude-nvim-bridge and claude-nvim-post-bridge (sourced, not run).
# Callers set LOG_TAG and PAYLOAD before using these helpers.

CLAUDE_NVIM_DEBUG_LOG="/tmp/claude-reviewer-debug.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [${LOG_TAG:-hook} pid=$$] $1" >> "$CLAUDE_NVIM_DEBUG_LOG"
}

# payload_get <python expression over the decoded payload `d`>
payload_get() {
  printf '%s' "$PAYLOAD" | python3 -c "import sys, json
d = json.load(sys.stdin)
v = $1
print('' if v is None else v)" 2>/dev/null
}

# Absolute, symlink-resolved path, even if the file doesn't exist yet
# (Write to a new file). BSD realpath on macOS has no --canonicalize-missing.
abs_path() {
  python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$1"
}

# find_nvim_socket <file_path> <claude_cwd>
# Sets SOCKET and SOCKET_SOURCE. Terminal-agnostic: none of these depend on
# which terminal (or multiplexer) launched Claude Code.
#   1. Claude is running inside a Neovim :terminal ($NVIM / $NVIM_LISTEN_ADDRESS)
#   2. Same CMUX workspace, when running inside CMUX (tighter than "same repo")
#   3. The nearest directory, walking up from the edited file and then from
#      Claude's cwd, that some Neovim registered as one of its tabs'
#      directories (or that tab's git root).
# Every candidate must point at a live socket; stale registrations left by a
# crashed Neovim are skipped rather than ending the search.
find_nvim_socket() {
  local file_path="$1" claude_cwd="$2"
  SOCKET=""
  SOCKET_SOURCE=""

  local var val
  for var in NVIM_LISTEN_ADDRESS NVIM; do
    val="${!var}"
    if [ -n "$val" ] && [ -S "$val" ]; then
      SOCKET="$val"
      SOCKET_SOURCE="\$$var"
      return 0
    fi
  done

  if [ -n "$CMUX_WORKSPACE_ID" ]; then
    local cmux_file="/tmp/claude-nvim-cmux-${CMUX_WORKSPACE_ID}.txt"
    if [ -f "$cmux_file" ]; then
      val=$(cat "$cmux_file")
      if [ -n "$val" ] && [ -S "$val" ]; then
        SOCKET="$val"
        SOCKET_SOURCE="cmux file $cmux_file"
        return 0
      fi
    fi
  fi

  local match
  match=$(python3 - "$file_path" "$claude_cwd" <<'PY'
import hashlib, os, stat, sys

def ancestors(p):
    out = []
    p = os.path.realpath(p)
    while True:
        out.append(p)
        parent = os.path.dirname(p)
        if parent == p:
            return out
        p = parent

file_path, cwd = sys.argv[1], sys.argv[2]
candidates = []
if file_path:
    candidates += ancestors(os.path.dirname(file_path))
if cwd:
    candidates += ancestors(cwd)

for d in dict.fromkeys(candidates):
    reg = "/tmp/claude-nvim-cwd-%s.txt" % hashlib.sha256(d.encode()).hexdigest()[:8]
    try:
        with open(reg) as f:
            sock = f.read().strip()
        if stat.S_ISSOCK(os.stat(sock).st_mode):
            print("%s\t%s" % (sock, d))
            break
    except OSError:
        continue
PY
)
  if [ -n "$match" ]; then
    SOCKET="${match%%$'\t'*}"
    SOCKET_SOURCE="dir registration ${match#*$'\t'}"
    return 0
  fi
  return 1
}
