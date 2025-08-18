#!/bin/bash
set -euo pipefail

# Load shared utilities 
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.bash" 
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validation.bash" 

PLUGIN_PREFIX="CHATGPT_ANALYSER"

# Reads either a value or a list from the given env prefix
function prefix_read_list() {
  local prefix="$1"
  local parameter="${prefix}_0"

  if [ -n "${!parameter:-}" ]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [ -n "${!parameter:-}" ]; do
      echo "${!parameter}"
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  elif [ -n "${!prefix:-}" ]; then
    echo "${!prefix}"
  fi
}

# Reads either a value or a list from plugin config
function plugin_read_list() {
  prefix_read_list "BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
}


# Reads either a value or a list from plugin config into a global result array
# Returns success if values were read
function prefix_read_list_into_result() {
  local prefix="$1"
  local parameter="${prefix}_0"
  result=()

  if [ -n "${!parameter:-}" ]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [ -n "${!parameter:-}" ]; do
      result+=("${!parameter}")
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  elif [ -n "${!prefix:-}" ]; then
    result+=("${!prefix}")
  fi

  [ ${#result[@]} -gt 0 ] || return 1
}

# Reads either a value or a list from plugin config
function plugin_read_list_into_result() {
  prefix_read_list_into_result "BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
}

# Reads a single value
function plugin_read_config() {
  local var="BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
  local default="${2:-}"
  echo "${!var:-$default}"
}


function get_openai_api_key() { 
  local api_key=""

  api_key=$(plugin_read_config API_KEY "")  
  if [ -z "${api_key}" ]; then
      api_key="${OPENAI_API_KEY:-}"
    else
      api_key="${api_key}"
  fi

  # Trim any whitespace that might be causing issues
  api_key=$(echo "$api_key" | tr -d '[:space:]')
  echo "${api_key}"
}

function get_bk_api_token() {
  local bk_token=""

  bk_token=$(plugin_read_config BUILDKITE_API_TOKEN "")
  if [ -z "${bk_token}" ]; then
    # the token is not set, so we assume it is not required
    bk_token="${BUILDKITE_API_TOKEN:-}"
  else
    bk_token="${bk_token}"
  fi
  # Trim any whitespace that might be causing issues
  bk_token=$(echo "$bk_token" | tr -d '[:space:]')
  echo "${bk_token}"
}

function get_current_build_information() {  
  local bk_api_token="$1" 

  # Fetch build information from Buildkite API
  response=$(curl -s -f -X GET "https://api.buildkite.com/v2/organizations/${BUILDKITE_ORGANIZATION_SLUG}/pipelines/${BUILDKITE_PIPELINE_SLUG}/builds/${BUILDKITE_BUILD_NUMBER}" \
    -H "Authorization: Bearer ${bk_api_token}" \
    -H "Content-Type: application/json" 2>/dev/null) 

  # Check if curl failed
  if [ $? -ne 0 ]; then
    echo ""
    return
  fi
  echo "${response}"
}
 
function ping_payload() { 
  local model="$1" 

  # Prepare the payload
  local payload=$(jq -n \
    --arg model "$model" \
    '{
      model: $model,
      messages: [
        { role: "user", content: "ping" }
      ],
      max_tokens: 1,
      temperature: 0.0
    }')

  echo "$payload"
}

function call_openapi_chatgpt() {
  local api_secret_key="$1"
  local payload="$2"

  # Call the OpenAI API
  response=$(curl -sS -X POST "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer ${api_secret_key}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  echo "$response" 
}

function format_payload() {
  local model="$1"
  local custom_prompt="$2"
  local user_content="$3"
  local base_prompt="You are an expert software engineer and DevOps specialist specialising in Buildkite. Please provide a detailed analysis of the build information provided."

  local payload
  # check if user prompt is not empty, append to default prompt "you are an expert."  
  if [ -n "${custom_prompt}" ]; then
      base_prompt="${base_prompt} ${custom_prompt}"
  fi 

  # Prepare the payload with prompt
  payload=$(jq -n \
    --arg model "$model" \
    --arg system_prompt "$base_prompt" \
    --arg user_content "$user_content" \
     '{
      model: $model,
      messages: [
        { role: "system", content: $system_prompt },
        { role: "user", content: $user_content }
      ]
    }') 

    echo "$payload"
}

function get_user_content() {
  local bk_api_token="$1"

 local content=""
  # Check if Buildkite API token is provided
  if [ -z "${bk_api_token}" ]; then
    # Default to a step level or command step to be passed for prompt analysis
    content=$(echo "Generating content from current step information ...")
  else
    # Get current build information from Buildkite API
    content=$(get_current_build_information "${bk_api_token}")   
  fi 
  echo "${content}"
}

function generate_build_info() {
  local bk_api_token="$1"
  local analysis_level="$2"

  local build_info="Build: ${BUILDKITE_PIPELINE_SLUG} #${BUILDKITE_BUILD_NUMBER}
Build Label: ${BUILDKITE_MESSAGE:-Unknown}
Build URL: ${BUILDKITE_BUILD_URL:-Unknown}"  

  log_section "Build Information"
  # Check if Buildkite API token is provided
  if [ -z "${bk_api_token}" ]; then
    # Default to a step level or command step to be passed for prompt analysis
    echo "Generating content from current step information ..."
    build_info="${build_info}
Job: ${BUILDKITE_LABEL:-Unknown}
Command: ${BUILDKITE_COMMAND:-Unknown}
Command Exit status: ${BUILDKITE_COMMAND_EXIT_STATUS:-0}
Build Source: ${BUILDKITE_SOURCE:-Unknown}"

    if [ "${BUILDKITE_SOURCE}" == "trigger_job" ]; then
      build_info="${build_info}
Triggered from pipeline: ${BUILDKITE_TRIGGERED_FROM_BUILD_PIPELINE_SLUG:-Unknown}
Triggered from build: ${BUILDKITE_TRIGGERED_FROM_BUILD_NUMBER:-Unknown}"
    fi
  fi

  if [ "${analysis_level}" == "step" ]; then
    # Generate step-level build information
    echo "Generating step-level build information ..."
  else
    # Generate build-level information
    echo "Generating build-level information ..."
  fi
  echo "${build_info}"
}

function send_analysis() {
  local api_secret_key="$1"
  local model="$2"
  local user_prompt="$3"
  local buildkite_api_token="$4"
  
  local content=$(get_user_content "${buildkite_api_token}")
  if [ -z "${content}" ]; then
    log_error "Failed to generate build or step level information for analysis."
    return 1
  fi

  local prompt_payload
  #check if user_prompt is equal to "ping"
  if [ "${user_prompt}" == "ping" ]; then
    prompt_payload=$(ping_payload "${model}")
  else
    prompt_payload=$(format_payload "${model}" "${user_prompt}" "${content}")
  fi
  # Call the OpenAI API
  response=$(call_openapi_chatgpt "${api_secret_key}"  "${prompt_payload}")
  
  # Validate and process the response
  if ! validate_and_process_response "${response}"; then
    return 1
  fi

  # Extract and display the response content
  total_tokens=$(echo "${response}" | jq -r '.usage.total_tokens')
  log_info "Summary:"
  log_info "  Total tokens used: ${total_tokens}"

  ## annotate the response into the Build
  if [ "${user_prompt}" == "ping" ]; then 
    log_info "# ChatGPT Annotation Plugin 
        ✅ Verified OpenAI token. Successfully pinged ChatGPT with model: ${model}"  \
        | buildkite-agent annotate  --style "info" --context "chatgpt-analyse"     

    return 0
  fi

  ## Generate a more elaborate annotation
  content_response=$(echo "${response}" | jq -r '.choices[0].message.content' | sed 's/^/  /') 
    echo -e "### ChatGPT Annotation Plugin"  | buildkite-agent annotate  --style "info" --context "chatgpt-analyse"    
    echo -e "${content_response}"  | buildkite-agent annotate  --style "info" --context "chatgpt-analyse" --append

  log_success "ChatGPT analysis completed successfully."
  return 0
}