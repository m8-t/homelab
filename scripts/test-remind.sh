#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/remind.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

run() {
  env -u REMIND_TEXT -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID -u REMIND_DRY_RUN \
    -u REMIND_ONESHOT_ID -u SCHEDULE_TOKEN -u CI_API_V4_URL -u CI_PROJECT_ID \
    "$@" bash "$script"
}

out=$(run REMIND_DRY_RUN=1 REMIND_TEXT="take pills")
rc=$?
if [ "$rc" -eq 0 ] && grep -qx "Reminder: take pills" <<<"$out" \
  && grep -qx "chat_id=257158750" <<<"$out"; then
  pass "dry run prints message and default chat id"
else
  fail "dry run prints message and default chat id (rc=$rc out=$out)"
fi

out=$(run REMIND_DRY_RUN=1 TELEGRAM_CHAT_ID=42 REMIND_TEXT="x")
if grep -qx "chat_id=42" <<<"$out"; then
  pass "chat id override"
else
  fail "chat id override (out=$out)"
fi

special='<b>bold</b> & "quoted" '"'single'"' _under_ Müller'
out=$(run REMIND_DRY_RUN=1 REMIND_TEXT="$special")
if grep -qxF "Reminder: ${special}" <<<"$out"; then
  pass "special characters unchanged"
else
  fail "special characters unchanged (out=$out)"
fi

if run REMIND_DRY_RUN=1 >/dev/null 2>&1; then
  fail "missing REMIND_TEXT must fail"
else
  pass "missing REMIND_TEXT fails"
fi

if run REMIND_DRY_RUN=1 REMIND_TEXT="" >/dev/null 2>&1; then
  fail "empty REMIND_TEXT must fail"
else
  pass "empty REMIND_TEXT fails"
fi

if run REMIND_TEXT="x" >/dev/null 2>&1; then
  fail "missing token must fail"
else
  pass "missing token fails"
fi

mkdir "$work/bin"
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "call" >>"$STUB_LOG.count"
printf '%s\n' "$@" >>"$STUB_LOG"
for a in "$@"; do
  if [ "$a" = "DELETE" ] && [ -n "${STUB_DELETE_RC:-}" ]; then exit "$STUB_DELETE_RC"; fi
done
exit "${STUB_RC:-0}"
EOF
chmod +x "$work/bin/curl"

export STUB_LOG="$work/args"
: >"$STUB_LOG"
out=$(env -u TELEGRAM_CHAT_ID -u REMIND_DRY_RUN \
  -u REMIND_ONESHOT_ID -u SCHEDULE_TOKEN -u CI_API_V4_URL -u CI_PROJECT_ID PATH="$work/bin:$PATH" \
  REMIND_TEXT="hello <b>" TELEGRAM_BOT_TOKEN="SECRETTOKEN" bash "$script")
rc=$?
expect() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
expect_not() {
  local name=$1
  shift
  if "$@"; then fail "$name"; else pass "$name"; fi
}
expect "send path exits 0" test "$rc" -eq 0
expect "curl called once" test "$(wc -l <"$STUB_LOG.count")" -eq 1
expect "url contains token path" \
  grep -qxF "https://api.telegram.org/botSECRETTOKEN/sendMessage" "$STUB_LOG"
expect "chat_id arg" grep -qxF "chat_id=257158750" "$STUB_LOG"
expect "urlencode flag" grep -qxF -- "--data-urlencode" "$STUB_LOG"
expect "urlencode text arg" grep -qxF "text=Reminder: hello <b>" "$STUB_LOG"
expect_not "no parse_mode" grep -q "parse_mode" "$STUB_LOG"
expect_not "token not echoed" grep -q "SECRETTOKEN" <<<"$out"

if env -u REMIND_ONESHOT_ID -u SCHEDULE_TOKEN -u CI_API_V4_URL -u CI_PROJECT_ID \
  PATH="$work/bin:$PATH" STUB_RC=22 REMIND_TEXT="x" TELEGRAM_BOT_TOKEN="t" \
  bash "$script" >/dev/null 2>&1; then
  fail "curl failure must propagate"
else
  pass "curl failure propagates"
fi

stub_run() {
  : >"$STUB_LOG"
  : >"$STUB_LOG.count"
  stub_out=$(run PATH="$work/bin:$PATH" "$@" 2>"$work/stderr")
  stub_rc=$?
}
calls() { wc -l <"$STUB_LOG.count"; }
oneshot=(REMIND_TEXT=x TELEGRAM_BOT_TOKEN=t REMIND_ONESHOT_ID=123 SCHEDULE_TOKEN=SCHEDTOK
  CI_API_V4_URL=https://gitlab.example/api/v4 CI_PROJECT_ID=81160351)

out=$(run REMIND_DRY_RUN=1 REMIND_TEXT=x REMIND_ONESHOT_ID=123)
rc=$?
expect "dry run oneshot prints delete_schedule" \
  test "$rc" -eq 0 -a "$(grep -cx 'delete_schedule=123' <<<"$out")" -eq 1

out=$(run REMIND_DRY_RUN=1 REMIND_TEXT=x)
expect_not "dry run without id has no delete_schedule" grep -q delete_schedule <<<"$out"

expect_not "dry run non-numeric id fails" \
  run REMIND_DRY_RUN=1 REMIND_TEXT=x REMIND_ONESHOT_ID=12x >/dev/null 2>&1

stub_run REMIND_TEXT=x TELEGRAM_BOT_TOKEN=t
expect "no id: rc 0" test "$stub_rc" -eq 0
expect "no id: one curl call" test "$(calls)" -eq 1
expect_not "no id: no DELETE" grep -qx DELETE "$STUB_LOG"

stub_run "${oneshot[@]}"
expect "oneshot: rc 0" test "$stub_rc" -eq 0
expect "oneshot: two curl calls" test "$(calls)" -eq 2
expect "oneshot: DELETE arg" grep -qx DELETE "$STUB_LOG"
expect "oneshot: token header" grep -qxF "PRIVATE-TOKEN: SCHEDTOK" "$STUB_LOG"
expect "oneshot: delete url" \
  grep -qxF "https://gitlab.example/api/v4/projects/81160351/pipeline_schedules/123" "$STUB_LOG"
expect "oneshot: deleted message" grep -qxF "Schedule 123 deleted" <<<"$stub_out"
expect_not "oneshot: token not echoed" grep -q SCHEDTOK <<<"$stub_out"

stub_run REMIND_TEXT=x TELEGRAM_BOT_TOKEN=t REMIND_ONESHOT_ID=123 \
  CI_API_V4_URL=https://gitlab.example/api/v4 CI_PROJECT_ID=81160351
expect "missing schedule token fails" test "$stub_rc" -ne 0
expect "missing schedule token: one curl call" test "$(calls)" -eq 1
expect_not "missing schedule token: no DELETE" grep -qx DELETE "$STUB_LOG"

stub_run "${oneshot[@]}" REMIND_ONESHOT_ID='12;rm'
expect "bad id fails" test "$stub_rc" -ne 0
expect "bad id: one curl call" test "$(calls)" -eq 1
expect_not "bad id: no DELETE" grep -qx DELETE "$STUB_LOG"

stub_run "${oneshot[@]}" STUB_RC=22
expect "telegram failure fails" test "$stub_rc" -ne 0
expect "telegram failure: one curl call" test "$(calls)" -eq 1

stub_run "${oneshot[@]}" STUB_DELETE_RC=22
expect "delete failure fails" test "$stub_rc" -ne 0
expect "delete failure: two curl calls" test "$(calls)" -eq 2

if [ "$fails" -ne 0 ]; then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all tests passed"
