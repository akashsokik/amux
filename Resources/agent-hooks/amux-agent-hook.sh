#!/bin/bash
# Forwards Claude Code hook events to amux via Unix socket

EVENT="$1"
PANE_ID="$AMUX_PANE_ID"
SOCKET="$AMUX_SOCKET_PATH"

[ -z "$PANE_ID" ] || [ -z "$SOCKET" ] || [ -z "$EVENT" ] && exit 0
[ ! -S "$SOCKET" ] && exit 0

# Read stdin (hook JSON data from Claude Code)
STDIN_DATA=""
if [ ! -t 0 ]; then
    STDIN_DATA=$(cat)
fi

# Extract message from notification events
MESSAGE=""
if [ "$EVENT" = "notification" ] && [ -n "$STDIN_DATA" ]; then
    MESSAGE=$(echo "$STDIN_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null || echo "")
fi

# Send JSON payload via Unix socket using python3 (always available on macOS)
python3 -c "
import socket, json, sys
payload = json.dumps({
    'paneId': '$PANE_ID',
    'event': '$EVENT',
    'data': {'message': '''$MESSAGE'''}
})
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect('$SOCKET')
    sock.sendall(payload.encode())
except Exception:
    pass
finally:
    sock.close()
" 2>/dev/null

exit 0
