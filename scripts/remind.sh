#!/usr/bin/env bash
set -euo pipefail

if [ -z "${REMIND_TEXT:-}" ]; then
  echo "REMIND_TEXT is missing or empty" >&2
  exit 1
fi

chat_id="${TELEGRAM_CHAT_ID:-257158750}"
msg="Reminder: ${REMIND_TEXT}"

if [ "${REMIND_DRY_RUN:-}" = "1" ]; then
  echo "chat_id=${chat_id}"
  echo "${msg}"
  if [ -n "${REMIND_ONESHOT_ID:-}" ]; then
    if ! [[ "${REMIND_ONESHOT_ID}" =~ ^[0-9]+$ ]]; then
      echo "REMIND_ONESHOT_ID is not numeric; schedule not deleted" >&2
      exit 1
    fi
    echo "delete_schedule=${REMIND_ONESHOT_ID}"
  fi
  exit 0
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "TELEGRAM_BOT_TOKEN is missing or empty" >&2
  exit 1
fi

curl -sf --max-time 30 --retry 3 -X POST \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${chat_id}" \
  --data-urlencode "text=${msg}" > /dev/null
echo "Reminder sent"

if [ -n "${REMIND_ONESHOT_ID:-}" ]; then
  if ! [[ "${REMIND_ONESHOT_ID}" =~ ^[0-9]+$ ]]; then
    echo "REMIND_ONESHOT_ID is not numeric; schedule not deleted" >&2
    exit 1
  fi
  if [ -z "${SCHEDULE_TOKEN:-}" ]; then
    echo "SCHEDULE_TOKEN is missing or empty; schedule ${REMIND_ONESHOT_ID} not deleted" >&2
    exit 1
  fi
  if [ -z "${CI_API_V4_URL:-}" ] || [ -z "${CI_PROJECT_ID:-}" ]; then
    echo "CI_API_V4_URL or CI_PROJECT_ID is missing or empty; schedule ${REMIND_ONESHOT_ID} not deleted" >&2
    exit 1
  fi
  curl -sf --max-time 30 --retry 3 -X DELETE \
    -H "PRIVATE-TOKEN: ${SCHEDULE_TOKEN}" \
    "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipeline_schedules/${REMIND_ONESHOT_ID}" > /dev/null
  echo "Schedule ${REMIND_ONESHOT_ID} deleted"
fi
