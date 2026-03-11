#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

API_BASE_URL="https://api.cloudways.com/api/v2"

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
}

parse_token() {
  local body="$1"
  jq -r '.access_token // empty' <<<"$body"
}

extract_error() {
  local body="$1"
  jq -r '.message // .error // .errors[0].message // empty' <<<"$body" 2>/dev/null || true
}

is_json() {
  local body="$1"
  jq -e . >/dev/null 2>&1 <<<"$body"
}

is_truthy() {
  local value="$1"
  case "${value,,}" in
    1|true|yes|completed|done|success) return 0 ;;
    *) return 1 ;;
  esac
}

poll_operation_until_complete() {
  local access_token="$1"
  local operation_id="$2"
  local max_attempts="${3:-30}"
  local sleep_seconds="${4:-2}"
  local poll_body_file="$5"

  local attempt=1
  local poll_http_code=""
  local poll_response=""
  local completion_value=""
  local status_value=""
  local api_error=""

  declare -a operation_candidates=(
    "https://api.cloudways.com/api/v2/operation/${operation_id}"
    "https://api.cloudways.com/api/v1/operation/${operation_id}"
  )

  while [[ "$attempt" -le "$max_attempts" ]]; do
    for operation_url in "${operation_candidates[@]}"; do
      poll_http_code="$(curl -sS -o "$poll_body_file" -w "%{http_code}" \
        -X GET "$operation_url" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer ${access_token}")"
      poll_response="$(<"$poll_body_file")"

      if [[ ! "$poll_http_code" =~ ^2 ]] || ! is_json "$poll_response"; then
        continue
      fi

      completion_value="$(jq -r '.operation.is_completed // .is_completed // empty' <<<"$poll_response" 2>/dev/null || true)"
      status_value="$(jq -r '.operation.status // .status // empty' <<<"$poll_response" 2>/dev/null || true)"
      api_error="$(extract_error "$poll_response")"

      if [[ -n "$api_error" && "$api_error" != "null" ]]; then
        echo "Operation API error: $api_error" >&2
      fi

      if is_truthy "$completion_value" || is_truthy "$status_value"; then
        echo "$poll_response"
        return 0
      fi
    done

    sleep "$sleep_seconds"
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for operation_id=${operation_id} to complete." >&2
  if [[ -n "${poll_response:-}" ]]; then
    echo "Last operation response:" >&2
    echo "$poll_response" >&2
  fi
  return 1
}

request_token_json() {
  local token_url="$1"
  local email="$2"
  local api_key="$3"
  local body_file="$4"

  curl -sS -o "$body_file" -w "%{http_code}" \
    -X POST "$token_url" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${email}\",\"api_key\":\"${api_key}\"}"
}

request_token_form() {
  local token_url="$1"
  local email="$2"
  local api_key="$3"
  local body_file="$4"

  curl -sS -o "$body_file" -w "%{http_code}" \
    -X POST "$token_url" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "email=${email}" \
    --data-urlencode "api_key=${api_key}"
}

main() {
  require_command curl
  require_command jq

  read -r -p "Enter your Cloudways email: " EMAIL
  read -r -s -p "Enter your Cloudways API key: " API_KEY
  echo

  if [[ -z "$EMAIL" || -z "$API_KEY" ]]; then
    echo "Error: email and API key are required." >&2
    exit 1
  fi

  echo "Generating access token..."
  token_body_file="$(mktemp)"
  monitor_body_file="$(mktemp)"
  operation_body_file="$(mktemp)"
  trap 'rm -f "$token_body_file" "$monitor_body_file" "$operation_body_file"' EXIT

  access_token=""
  http_code=""
  token_response=""

  # Cloudways auth can exist on different paths between API versions/accounts.
  declare -a token_candidates=(
    "https://api.cloudways.com/api/v2/oauth/token|json"
    "https://api.cloudways.com/api/v2/oauth/token|form"
    "https://api.cloudways.com/api/v2/oauth/access_token|form"
    "https://api.cloudways.com/api/v2/oauth/access_token|json"
    "https://api.cloudways.com/api/v1/oauth/access_token|form"
    "https://api.cloudways.com/api/v1/oauth/access_token|json"
  )

  for candidate in "${token_candidates[@]}"; do
    IFS='|' read -r token_url token_format <<<"$candidate"
    if [[ "$token_format" == "json" ]]; then
      http_code="$(request_token_json "$token_url" "$EMAIL" "$API_KEY" "$token_body_file")"
    else
      http_code="$(request_token_form "$token_url" "$EMAIL" "$API_KEY" "$token_body_file")"
    fi
    token_response="$(<"$token_body_file")"
    access_token="$(parse_token "$token_response")"
    if [[ -n "$access_token" ]]; then
      break
    fi
  done

  if [[ -z "$access_token" ]]; then
    echo "Error fetching access token (HTTP $http_code)." >&2
    api_error="$(extract_error "$token_response")"
    if [[ -n "$api_error" ]]; then
      echo "API error: $api_error" >&2
    fi
    echo "Raw response:" >&2
    echo "$token_response" >&2
    exit 1
  fi

  echo "Access token acquired successfully."

  read -r -p "Enter Server ID: " SERVER_ID
  if [[ -z "$SERVER_ID" ]]; then
    echo "Error: Server ID is required." >&2
    exit 1
  fi

  echo "Select monitoring type:"
  echo "1) Bandwidth (bw)"
  echo "2) Database (db)"
  read -r -p "Enter 1 or 2 [default: 1]: " TYPE_CHOICE

  case "$TYPE_CHOICE" in
    ""|1) TYPE="bw" ;;
    2) TYPE="db" ;;
    bw|db) TYPE="$TYPE_CHOICE" ;;
    *)
      echo "Invalid choice. Use 1 (bw) or 2 (db)." >&2
      exit 1
      ;;
  esac

  echo
  echo "Fetching monitoring summary for Server ID: $SERVER_ID (type=$TYPE)..."
  echo

  monitor_http_code=""
  monitor_response=""
  selected_monitor_url=""
  declare -a monitor_candidates=(
    "https://api.cloudways.com/api/v2/server/monitor/${SERVER_ID}?type=${TYPE}"
    "https://api.cloudways.com/api/v1/server/monitor/${SERVER_ID}?type=${TYPE}"
  )

  for monitor_url in "${monitor_candidates[@]}"; do
    monitor_http_code="$(curl -sS -o "$monitor_body_file" -w "%{http_code}" \
      -X GET "$monitor_url" \
      -H "Accept: application/json" \
      -H "Authorization: Bearer ${access_token}")"
    monitor_response="$(<"$monitor_body_file")"
    if [[ "$monitor_http_code" =~ ^2 ]] && is_json "$monitor_response"; then
      # Guard against generic placeholder responses from the API root.
      if [[ "$(extract_error "$monitor_response")" == "You have reached Cloudways API." ]]; then
        continue
      fi
      selected_monitor_url="$monitor_url"
      break
    fi
  done

  if [[ ! "$monitor_http_code" =~ ^2 ]] || [[ -z "$selected_monitor_url" ]]; then
    echo "Monitoring request failed (HTTP $monitor_http_code)." >&2
    api_error="$(extract_error "$monitor_response")"
    if [[ -n "$api_error" ]]; then
      echo "API error: $api_error" >&2
    fi
    echo "Raw response:" >&2
    echo "$monitor_response" >&2
    exit 1
  fi

  operation_id="$(jq -r '.operation_id // .operation.id // empty' <<<"$monitor_response" 2>/dev/null || true)"
  if [[ -n "$operation_id" ]]; then
    echo "Operation queued (operation_id=${operation_id}). Waiting for completion..."
    poll_result="$(poll_operation_until_complete "$access_token" "$operation_id" 45 2 "$operation_body_file")"
    # If operation endpoint returns monitor payload details, prefer that.
    if is_json "$poll_result"; then
      maybe_result_data="$(jq -c '.result // .data // empty' <<<"$poll_result" 2>/dev/null || true)"
      if [[ -n "$maybe_result_data" && "$maybe_result_data" != "null" ]]; then
        jq . <<<"$maybe_result_data"
        exit 0
      fi
    fi
  fi

  jq . <<<"$monitor_response"
}

main "$@"
