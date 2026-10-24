#!/bin/sh
# Runs the Linux binaries in Docker: the e2e suite against the fake portals, the password
# fallback without a keyring, and a TLS check against the real LMS and Qalam with fake
# credentials (in an image with no CA certificates, so only the embedded one anchors).
# Usage: tests/linux.sh   (after ./build.sh)
cd "$(dirname "$0")/.." || exit 1
status=0
for arch in arm64 x64; do
  platform=linux/$([ $arch = x64 ] && echo amd64 || echo arm64)
  echo "== $arch ($platform)"
  docker run --rm --platform "$platform" -v "$PWD:/src:ro" python:3.12-slim sh -c "
    cp /src/dist/nust-linux-$arch /usr/local/bin/nust && cd /src &&
    uname -m && ls /etc/ssl/certs 2>/dev/null | head -1; echo 'certs dir above (empty = none)' &&
    python3 -I tests/e2e.py /usr/local/bin/nust 2>&1 | grep -E '^(FAIL|SKIP)|passed' &&
    export NUST_STATE_DIR=/tmp/s NUST_USERNAME=probe NUST_PASSWORD=probe &&
    nust login </dev/null; echo \"real-server login exit=\$? (1 = both rejected the fake login)\"" || status=1
done
echo "== keyring fallback (no secret-tool)"
docker run --rm --platform linux/arm64 -v "$PWD:/src:ro" python:3.12-slim sh -c "
  cd /src && python3 -I - <<'EOF'
import sys; sys.path.insert(0, 'tests'); sys.argv = ['x']
import e2e, shutil
shutil.copy('/src/dist/nust-linux-arm64', '/tmp/nust')
e2e.BIN = __import__('pathlib').Path('/tmp/nust')
m, q = e2e.Moodle(), e2e.Qalam()
ls, qs = e2e.serve(e2e.MoodleHandler, m), e2e.serve(e2e.QalamHandler, q)
e = e2e.Env(ls.server_port, qs.server_port); del e.env['NUST_PASSWORD_STORE']
print(e.run('login', env={'NUST_USERNAME': e2e.USER, 'NUST_PASSWORD': e2e.PASSWORD})[1])
m.tokens.clear(); rc, out, err = e.run('lms', 'courses'); print('renew rc', rc, err.strip())
print(e.run('status')[1])
EOF" || status=1
exit $status
