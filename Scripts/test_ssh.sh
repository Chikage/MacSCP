#!/bin/bash
# Starts a user-owned sshd on loopback only. Never changes Remote Login settings.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
mkdir -p "$ROOT/build"
FIXTURE=$(mktemp -d "$ROOT/build/ssh-test.XXXXXX")
SSHD_PID=""
cleanup() {
    if [[ -n "$SSHD_PID" ]]; then kill "$SSHD_PID" 2>/dev/null || true; wait "$SSHD_PID" 2>/dev/null || true; fi
    rm -rf "$FIXTURE"
}
trap cleanup EXIT
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
ssh-keygen -q -t ed25519 -N '' -f "$FIXTURE/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$FIXTURE/client_key"
cp "$FIXTURE/client_key.pub" "$FIXTURE/authorized_keys"
awk -v port="$PORT" '{printf "[127.0.0.1]:%s %s %s\n", port, $1, $2}' "$FIXTURE/host_key.pub" > "$FIXTURE/known_hosts"
awk -v port="$PORT" '{printf "[127.0.0.1]:%s %s %s\n", port, $1, $2}' "$FIXTURE/client_key.pub" > "$FIXTURE/wrong_hosts"
mkdir -p "$FIXTURE/remote" "$FIXTURE/local" "$FIXTURE/download"
cat > "$FIXTURE/sshd_config" <<CONFIG
Port $PORT
ListenAddress 127.0.0.1
HostKey "$FIXTURE/host_key"
PidFile "$FIXTURE/sshd.pid"
AuthorizedKeysFile "$FIXTURE/authorized_keys"
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers $(id -un)
Subsystem sftp /usr/libexec/sftp-server
LogLevel ERROR
CONFIG
/usr/sbin/sshd -D -e -f "$FIXTURE/sshd_config" > "$FIXTURE/sshd.log" 2>&1 &
SSHD_PID=$!
python3 - "$PORT" "$SSHD_PID" <<'PY'
import socket, sys, time, os
for _ in range(50):
    os.kill(int(sys.argv[2]), 0)
    try:
        with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.1):
            break
    except OSError:
        time.sleep(0.1)
else:
    raise SystemExit("Temporary sshd did not become ready")
PY
if [[ "${1:-}" == --serve ]]; then
    python3 - "$FIXTURE" "$PORT" <<'PY'
import json, os, pathlib, sys, uuid, getpass
root = pathlib.Path(sys.argv[1])
config = root / 'config'
config.mkdir()
(config / 'known_hosts').write_bytes((root / 'known_hosts').read_bytes())
sites = []
for mode in ['SFTP', 'SCP']:
    sites.append(dict(id=str(uuid.uuid4()), name='本机 ' + mode + ' 验证', host='127.0.0.1', port=int(sys.argv[2]),
                      username=getpass.getuser(), transferProtocol=mode, authentication='privateKey',
                      privateKeyPath=str(root / 'client_key'), remotePath=str(root / 'remote'), localPath=str(root / 'local')))
(config / 'sites.json').write_text(json.dumps(sites, ensure_ascii=False))
(root / 'local' / '传输验证.txt').write_text('MacSCP GUI upload and download verification.\n')
(root / 'local' / '资料').mkdir()
(root / 'local' / '资料' / 'README.txt').write_text('Nested directory fixture.\n')
print('UI fixture:', root, '\nPort:', sys.argv[2])
PY
    MACSCP_TEST_SUPPORT="$FIXTURE/config" "$ROOT/build/MacSCP.app/Contents/MacOS/MacSCP" > "$FIXTURE/app.log" 2>&1 &
    APP_PID=$!
    echo "Press Return to stop the fixture after closing the test app."
    read -r _
    kill "$APP_PID" 2>/dev/null || true
else
    MACSCP_SSH_FIXTURE="$FIXTURE" MACSCP_SSH_PORT="$PORT" swift test --arch arm64 -Xswiftc -warnings-as-errors
fi
