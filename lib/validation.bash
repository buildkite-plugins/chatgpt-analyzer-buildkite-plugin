#!/bin/bash
set -euo pipefail

function validate_required_tools() { 
  local errors=0

  # Check if required tools are installed
  if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Please install jq to parse JSON responses." >&2
    errors=$((errors + 1))
  fi

  if ! command -v curl &> /dev/null; then
    echo "curl is not installed. Please install curl to make API requests." >&2
    errors=$((errors + 1))
  fi

  return ${errors}
}

function validate_bk_token() {
  local bk_api_token="$1" 

  # Check if the BK API token is valid
  if [ -z "${bk_api_token}" ]; then
    # the token is not set, so we assume it is not required
    return 0
  fi

  #validate token scope
  response=$(curl -H "Authorization: Bearer ${bk_api_token}" \
    -X GET "https://api.buildkite.com/v2/access-token")
  
  #check if response is 200
  if [ $? -ne 0 ]; then
    echo "❌ Error: Invalid Buildkite API token." 
    return 1
  fi

  #check if response is empty
  if [ -z "${response}" ]; then
    echo "❌ Error: Failed to validate the Buildkite API token provided."
    return 1
  fi

  if ! echo "${response}" | jq -e '.scopes' > /dev/null; then
    echo "❌ Error: Failed to validate the scope of the Buildkite API token provided."
    return 1
  fi 

  scopes=$(echo "${response}" | jq -r '.scopes[]')   
  
  # Check if token has required read scopes
  if [[ ! "${scopes}" =~ read_builds ]] || [[ ! "${scopes}" =~ read_build_logs ]]; then
    echo "❌ Error: The Buildkite API token does not have the required 'read_builds' and 'read_build_logs' scopes."
    echo "Current scopes: ${scopes}"
    return 1
  fi
  
  echo "✅ Buildkite API token is valid."
  return 0
}

function validate_and_process_response() {
  local response="$1"
  
  # Check if response is empty
  if [ -z "${response}" ]; then
    echo "❌ Error: No response received from OpenAI API."
    return 1
  fi
  
  # Check if the response contains an error
  if echo "${response}" | jq -e '.error' > /dev/null; then
    echo "❌ Error: $(echo "${response}" | jq -r '.error.message')"
    return 1
  fi
  
  # Check if the response contains choices
  if ! echo "${response}" | jq -e '.choices' > /dev/null; then
    echo "❌ Error: No choices found in the response from OpenAI API."
    return 1
  fi
  
  # Check if the response contains a message
  if ! echo "${response}" | jq -e '.choices[0].message.content' > /dev/null; then
    echo "❌ Error: No message content found in the response from OpenAI API."
    return 1
  fi
  
  return 0
}
