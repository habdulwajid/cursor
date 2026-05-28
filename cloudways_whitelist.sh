#!/usr/bin/env bash

# =============================================================================
# Cloudways API - SSH/SFTP IP Whitelisting Script (robust version)
# =============================================================================

set -u
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

API_V1="https://api.cloudways.com/api/v1"
API_V2="https://api.cloudways.com/api/v2"

HTTP_BODY=""
HTTP_CODE=""

print_header() {
  echo -e "${CYAN}================================================${NC}"
  echo -e "${CYAN}  Cloudways SSH/SFTP IP Whitelisting Script${NC}"
  echo -e "${CYAN}================================================${NC}"
  echo ""
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}[!] Required command not found: ${cmd}${NC}"
    exit 1
  fi
}

http_request() {
  local method="$1"
  local url="$2"
  shift 2

  local raw
  raw=$(curl --silent --show-error -w $'\n__HTTP_CODE__%{http_code}' -X "$method" "$@" "$url")

  HTTP_CODE="${raw##*__HTTP_CODE__}"
  HTTP_BODY="${raw%__HTTP_CODE__*}"
  HTTP_BODY="${HTTP_BODY%$'\n'}"
}

json_get_error() {
  if ! jq -e . >/dev/null 2>&1 <<<"$1"; then
    echo "Non-JSON response"
    return
  fi

  jq -r '
    if type == "object" then
      (
        .error
        // .error_description
        // .message
        // .errors
        // ""
      ) | if type == "string" then . else tostring end
    else
      ""
    end
  ' <<<"$1"
}

extract_ip_list() {
  # Cloudways GET whitelist responses differ by endpoint version. This parser
  # pulls IPv4/CIDR-like strings from known keys and nested structures.
  jq -r '
    def is_ipv4_or_cidr:
      test("^([0-9]{1,3}\\.){3}[0-9]{1,3}(\\/(3[0-2]|[12]?[0-9]))?$");

    [
      (.sftp // empty)[],
      (.ip_list // empty)[],
      (.data.ip_list // empty)[],
      (.data.sftp // empty)[],
      (.whitelisted.sftp // empty)[],
      (.whitelisted // empty)[],
      (.. | objects | .ip? // empty),
      (.. | objects | .ip_address? // empty),
      (.. | objects | .address? // empty),
      (.. | strings | select(is_ipv4_or_cidr))
    ]
    | flatten
    | map(select(type == "string"))
    | map(gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0))
    | unique
    | .[]
  ' <<<"$1" 2>/dev/null
}

is_success_response() {
  local body="$1"
  local code="$2"

  [[ "$code" =~ ^2 ]] || return 1

  if jq -e . >/dev/null 2>&1 <<<"$body"; then
    local err
    err="$(json_get_error "$body")"
    [[ -z "$err" ]] || return 1
  fi

  return 0
}

update_whitelist() {
  local server_id="$1"
  shift
  local ips=("$@")

  local -a base_params
  local -a ip_array_params
  local -a ips_array_params
  local ip_csv
  local ip

  base_params=(
    -H 'Content-Type: application/x-www-form-urlencoded'
    -H 'Accept: application/json'
    -H "Authorization: Bearer ${ACCESS_TOKEN}"
    -d "server_id=${server_id}"
    -d 'tab=sftp'
    -d 'type=sftp'
  )

  ip_array_params=()
  ips_array_params=()
  for ip in "${ips[@]}"; do
    ip_array_params+=(-d "ip[]=${ip}")
    ips_array_params+=(-d "ips[]=${ip}")
  done
  ip_csv=$(IFS=,; echo "${ips[*]}")

  # Attempt 1: documented shape used by many examples.
  http_request POST "${API_V1}/security/whitelisted" \
    "${base_params[@]}" \
    -d 'ipPolicy=allow_all' \
    "${ip_array_params[@]}"
  if is_success_response "$HTTP_BODY" "$HTTP_CODE"; then
    return 0
  fi

  # Attempt 2: snake_case policy and comma-separated ip key.
  http_request POST "${API_V1}/security/whitelisted" \
    "${base_params[@]}" \
    -d 'ip_policy=allow_all' \
    -d "ip=${ip_csv}"
  if is_success_response "$HTTP_BODY" "$HTTP_CODE"; then
    return 0
  fi

  # Attempt 3: some wrappers send ips[] with snake_case policy.
  http_request POST "${API_V1}/security/whitelisted" \
    "${base_params[@]}" \
    -d 'ip_policy=allow_all' \
    "${ips_array_params[@]}"
  if is_success_response "$HTTP_BODY" "$HTTP_CODE"; then
    return 0
  fi

  return 1
}

print_header
require_cmd curl
require_cmd jq

# ── Step 1: Credentials ──────────────────────────────────────────────────────
read -r -p "Enter client's Cloudways Email : " email
read -r -p "Enter client's API Key         : " api_key
echo ""

# ── Step 2: OAuth token ──────────────────────────────────────────────────────
echo -e "${YELLOW}[*] Obtaining access token...${NC}"

http_request POST "${API_V1}/oauth/access_token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'Accept: application/json' \
  --data-urlencode "email=${email}" \
  --data-urlencode "api_key=${api_key}"

ACCESS_TOKEN="$(jq -r '.access_token // empty' <<<"$HTTP_BODY" 2>/dev/null)"

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo -e "${RED}[!] Failed to get access token. Check credentials.${NC}"
  echo "HTTP: ${HTTP_CODE}"
  echo "Response: $HTTP_BODY"
  exit 1
fi
echo -e "${GREEN}[✓] Access token obtained.${NC}"
echo ""

# ── Step 3: Fetch servers ────────────────────────────────────────────────────
echo -e "${YELLOW}[*] Fetching server list...${NC}"

http_request GET "${API_V2}/server" \
  -H 'Accept: application/json' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}"

if ! jq -e . >/dev/null 2>&1 <<<"$HTTP_BODY"; then
  echo -e "${RED}[!] Failed to fetch server list (non-JSON response).${NC}"
  echo "HTTP: ${HTTP_CODE}"
  echo "$HTTP_BODY"
  exit 1
fi

SERVER_LIST=$(
  jq -r '
    (
      .servers
      // .data
      // .items
      // []
    )[]
    | [
        (.id // ""),
        (.public_ip // .ip // ""),
        (.label // .name // "n/a"),
        (.cloud // "n/a"),
        (.region // .location // "n/a"),
        (.instance_type // .instance // .size // "n/a")
      ]
    | @tsv
  ' <<<"$HTTP_BODY"
)

SERVER_COUNT="$(jq -r '(.servers // .data // .items // []) | length' <<<"$HTTP_BODY")"

if [[ -z "$SERVER_COUNT" || "$SERVER_COUNT" == "null" || "$SERVER_COUNT" -eq 0 ]]; then
  echo -e "${RED}[!] No servers found or failed to fetch list.${NC}"
  echo "$HTTP_BODY"
  exit 1
fi

echo -e "${GREEN}[✓] Found ${SERVER_COUNT} server(s):${NC}"
echo ""
printf "%-5s %-12s %-18s %-28s %-10s %-14s\n" "No." "Server ID" "Public IP" "Label" "Cloud" "Instance"
printf '%s\n' "$(printf '─%.0s' {1..92})"

INDEX=1
while IFS=$'\t' read -r id public_ip label cloud _region instance; do
  printf "%-5s %-12s %-18s %-28s %-10s %-14s\n" \
    "$INDEX" "$id" "$public_ip" "$label" "$cloud" "$instance"
  INDEX=$((INDEX + 1))
done <<<"$SERVER_LIST"
echo ""

# ── Step 4: IP to whitelist ──────────────────────────────────────────────────
read -r -p "Enter IP address to whitelist (e.g. 203.0.113.10 or 1.2.3.0/24): " WHITELIST_IP
if [[ -z "${WHITELIST_IP// }" ]]; then
  echo -e "${RED}[!] No IP entered. Exiting.${NC}"
  exit 1
fi

IP_VALID="$(jq -nr --arg ip "$WHITELIST_IP" '$ip | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}(\\/(3[0-2]|[12]?[0-9]))?$")')"
if [[ "$IP_VALID" != "true" ]]; then
  echo -e "${RED}[!] Invalid IPv4 or CIDR format: ${WHITELIST_IP}${NC}"
  exit 1
fi

echo ""
echo -e "${CYAN}Ready to whitelist [${WHITELIST_IP}] on ALL ${SERVER_COUNT} server(s).${NC}"
read -r -p "Proceed? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo -e "${YELLOW}[!] Aborted.${NC}"
  exit 0
fi
echo ""

# ── Step 5: Loop — GET existing, merge, POST full list ──────────────────────
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

while IFS=$'\t' read -r server_id public_ip server_label _cloud _region _instance; do
  echo -e "${YELLOW}[→] ${server_label} (ID: ${server_id} | IP: ${public_ip})${NC}"

  http_request GET "${API_V1}/security/whitelisted?server_id=${server_id}" \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer ${ACCESS_TOKEN}"

  if ! jq -e . >/dev/null 2>&1 <<<"$HTTP_BODY"; then
    echo -e "  ${RED}[✗] Failed to fetch current whitelist (HTTP ${HTTP_CODE}).${NC}"
    echo -e "      ${HTTP_BODY:0:220}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  mapfile -t EXISTING_IPS < <(extract_ip_list "$HTTP_BODY")
  EXISTING_COUNT="${#EXISTING_IPS[@]}"

  ALREADY_PRESENT=0
  for ip in "${EXISTING_IPS[@]}"; do
    if [[ "$ip" == "$WHITELIST_IP" ]]; then
      ALREADY_PRESENT=1
      break
    fi
  done

  if [[ "$ALREADY_PRESENT" -eq 1 ]]; then
    echo -e "  ${CYAN}[i] Already whitelisted — skipping. (Current: ${EXISTING_COUNT} IP(s))${NC}"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  MERGED_IPS=("${EXISTING_IPS[@]}" "$WHITELIST_IP")
  echo -e "  ${CYAN}[i] Current whitelist: ${EXISTING_COUNT} IP(s) — merging and reposting...${NC}"

  if update_whitelist "$server_id" "${MERGED_IPS[@]}"; then
    TOTAL="${#MERGED_IPS[@]}"
    echo -e "  ${GREEN}[✓] Success — whitelist now has ${TOTAL} IP(s).${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    ERR_MSG="$(json_get_error "$HTTP_BODY")"
    [[ -z "$ERR_MSG" ]] && ERR_MSG="$HTTP_BODY"
    echo -e "  ${RED}[✗] Failed (HTTP ${HTTP_CODE}): ${ERR_MSG}${NC}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done <<<"$SERVER_LIST"

# ── Step 6: Summary ──────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}  Summary${NC}"
echo -e "${CYAN}================================================${NC}"
echo -e "  IP Whitelisted    : ${WHITELIST_IP}"
echo -e "  Total Servers     : ${SERVER_COUNT}"
echo -e "  ${GREEN}Succeeded         : ${SUCCESS_COUNT}${NC}"
[[ "$SKIP_COUNT" -gt 0 ]] && echo -e "  ${CYAN}Already present   : ${SKIP_COUNT}${NC}"
[[ "$FAIL_COUNT" -gt 0 ]] && echo -e "  ${RED}Failed            : ${FAIL_COUNT}${NC}"
echo ""
