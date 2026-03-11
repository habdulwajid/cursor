#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

API_BASE_URL="https://api.cloudways.com/api/v2"
TOKEN_URL="${API_BASE_URL}/oauth/token"

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

request_token_json() {
  local email="$1"
  local api_key="$2"
  local body_file="$3"

  curl -sS -o "$body_file" -w "%{http_code}" \
    -X POST "$TOKEN_URL" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${email}\",\"api_key\":\"${api_key}\"}"
}

request_token_form() {
  local email="$1"
  local api_key="$2"
  local body_file="$3"

  curl -sS -o "$body_file" -w "%{http_code}" \
    -X POST "$TOKEN_URL" \
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
  trap 'rm -f "$token_body_file" "$monitor_body_file"' EXIT

  http_code="$(request_token_json "$EMAIL" "$API_KEY" "$token_body_file")"
  token_response="$(<"$token_body_file")"
  access_token="$(parse_token "$token_response")"

  # Fallback to form-encoded payload in case account/API expects that format.
  if [[ -z "$access_token" ]]; then
    http_code="$(request_token_form "$EMAIL" "$API_KEY" "$token_body_file")"
    token_response="$(<"$token_body_file")"
    access_token="$(parse_token "$token_response")"
  fi

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

  monitor_url="${API_BASE_URL}/server/monitor/${SERVER_ID}?type=${TYPE}"
  monitor_http_code="$(curl -sS -o "$monitor_body_file" -w "%{http_code}" \
    -X GET "$monitor_url" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${access_token}")"
  monitor_response="$(<"$monitor_body_file")"

  if [[ ! "$monitor_http_code" =~ ^2 ]]; then
    echo "Monitoring request failed (HTTP $monitor_http_code)." >&2
    api_error="$(extract_error "$monitor_response")"
    if [[ -n "$api_error" ]]; then
      echo "API error: $api_error" >&2
    fi
    echo "Raw response:" >&2
    echo "$monitor_response" >&2
    exit 1
  fi

  if jq -e . >/dev/null 2>&1 <<<"$monitor_response"; then
    jq . <<<"$monitor_response"
  else
    echo "$monitor_response"
  fi
}

main "$@"
