#!/bin/bash
# Forwards Claude Code hook events to amux via Unix socket
# Extracts rich context from the hook JSON payload for agent state tracking.

PANE_ID="$AMUX_PANE_ID"
TAB_ID="$AMUX_TAB_ID"
SOCKET="$AMUX_SOCKET_PATH"

[ -z "$PANE_ID" ] || [ -z "$SOCKET" ] && exit 0
[ ! -S "$SOCKET" ] && exit 0

# Read stdin (hook JSON data from Claude Code)
STDIN_DATA=""
if [ ! -t 0 ]; then
    STDIN_DATA=$(cat)
fi

[ -z "$STDIN_DATA" ] && exit 0

# Pipe JSON through stdin to python3 -- never interpolate into the script,
# because the payload contains quotes and special characters that break shell strings.
echo "$STDIN_DATA" | python3 -c "
import socket, json, sys, os

raw = json.load(sys.stdin)

event = raw.get('hook_event_name', '')
if not event:
    sys.exit(0)

data = {}

if event == 'Notification':
    data['message'] = raw.get('message', '')

if event in ('PreToolUse', 'PostToolUse', 'PermissionRequest'):
    data['toolName'] = raw.get('tool_name', '')
    tool_input = raw.get('tool_input', {})
    if isinstance(tool_input, dict):
        data['toolCommand'] = tool_input.get('command', '')
        data['toolFilePath'] = tool_input.get('file_path', '')

if event == 'Stop':
    data['stopReason'] = raw.get('stop_reason', '')

data['sessionId'] = raw.get('session_id', '')

pane_id = os.environ.get('AMUX_PANE_ID', '')
tab_id = os.environ.get('AMUX_TAB_ID', '') or None
sock_path = os.environ.get('AMUX_SOCKET_PATH', '')

if not pane_id or not sock_path:
    sys.exit(0)

payload = json.dumps({
    'paneId': pane_id,
    'tabId': tab_id,
    'event': event,
    'data': data
})

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect(sock_path)
    sock.sendall(payload.encode())
except Exception:
    pass
finally:
    sock.close()
" 2>/dev/null

exit 0
