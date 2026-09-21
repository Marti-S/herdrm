#!/bin/bash
# Shared deadline for PR26 gates. Killing the process group also stops compiler
# and test-runner children; cleanup commands use a shorter explicit deadline.
bounded() {
  python3 - "${PR26_COMMAND_TIMEOUT:-900}" "$@" <<'PY'
import os, signal, subprocess, sys
seconds = float(sys.argv[1])
assert seconds > 0, 'Command deadline must be positive'
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    code = p.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    print(f'ERROR: command exceeded {seconds:g} seconds: {sys.argv[2:]}', file=sys.stderr, flush=True)
    os.killpg(p.pid, signal.SIGKILL)
    p.wait(timeout=10)
    sys.exit(124)
sys.exit(code if code >= 0 else 128 - code)
PY
}
