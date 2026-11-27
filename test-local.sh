#!/bin/sh
set -eu

source_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
light="$source_dir/dist/LocalAgentLight.app/Contents/MacOS/LocalAgentLight"
output="$(/usr/bin/mktemp)"
runner=
cleanup() {
  if [ -n "$runner" ]; then
    kill -TERM "$runner" 2>/dev/null || :
    wait "$runner" 2>/dev/null || :
  fi
  /bin/rm -f "$output"
}
trap cleanup EXIT

wait_for() {
  attempts=0
  until /usr/bin/grep -Fqx "$1" "$output"; do
    if ! kill -0 "$runner" 2>/dev/null || [ "$attempts" -ge 120 ]; then
      /bin/cat "$output" >&2
      return 1
    fi
    attempts=$((attempts + 1))
    /bin/sleep 0.05
  done
}

"$light" run --dry-run >"$output" 2>&1 &
runner=$!
wait_for "Chế độ mô phỏng. Đang chờ hook cục bộ."

printf '%s\n' '{"prompt":"PRIVATE_TEST_SENTINEL","session_id":"fake"}' | "$light" hook claude working
wait_for "working"
"$light" hook codex idle
"$light" hook claude waiting
wait_for "waiting"
"$light" hook claude success
wait_for "success"
"$light" hook claude idle
wait_for "idle"

actual="$(/usr/bin/sed -n '2,$p' "$output")"
expected="$(printf '%s\n' working waiting success idle)"
[ "$actual" = "$expected" ]
printf '%s\n' 'Kiểm tra hook → socket Unix → trạng thái trên Terminal đã qua.'
