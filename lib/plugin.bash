#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.bash" 

PLUGIN_PREFIX="CHATGPT_ANALYZER"

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

function validate_required_tools() { 
  local errors=0

  # Check if required tools are installed
  if ! command -v jq &> /dev/null; then
    log_error "jq is not installed. Please install jq to parse JSON responses." >&2
    errors=$((errors + 1))
  fi

  if ! command -v curl &> /dev/null; then
    log_error "curl is not installed. Please install curl to make API requests." >&2
    errors=$((errors + 1))
  fi

  return ${errors}
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

function validate_bk_token() {
  local bk_api_token="$1" 

  # Check if the BK API token is valid
  if [ -z "${bk_api_token}" ]; then
    # the token is not set, so we assume it is not required
    return 0
  fi

  #validate token scope
  log_info "Validating Buildkite API token scope..."
  response=$(curl -sS -H "Authorization: Bearer ${bk_api_token}" \
    -X GET "https://api.buildkite.com/v2/access-token")
  
  #check if response is 200
  if [ $? -ne 0 ]; then
    log_error " Invalid Buildkite API token." 
    return 1
  fi

  #check if response is empty
  if [ -z "${response}" ]; then
    log_error "Failed to validate the Buildkite API token provided."
    return 1
  fi

  if ! echo "${response}" | jq -e '.scopes' > /dev/null; then
    log_error "Failed to validate the scope of the Buildkite API token provided."
    return 1
  fi 

  scopes=$(echo "${response}" | jq -r '.scopes[]')   
  
  # Check if token has required read scopes
  if [[ ! "${scopes}" =~ read_builds ]] || [[ ! "${scopes}" =~ read_build_logs ]]; then
    log_error "The Buildkite API token does not have the required 'read_builds' and 'read_build_logs' scopes."
    echo "Current scopes: ${scopes}"
    return 1
  fi
  
  return 0
}

function get_job_logs() {
  local bk_api_token="$1"
  local job_id=$2
  local output_file=$3
  local max_lines=$4

  local job_logs_raw="/tmp/job_${job_id}.raw"
  local job_url="https://api.buildkite.com/v2/organizations/${BUILDKITE_ORGANIZATION_SLUG}/pipelines/${BUILDKITE_PIPELINE_SLUG}/builds/${BUILDKITE_BUILD_NUMBER}/jobs/${job_id}/log"

  if curl -s -f -H "Authorization: Bearer ${bk_api_token}" "${job_url}" > "${job_logs_raw}" 2>/dev/null; then
    local job_logs_content="/tmp/job_${job_id}.content"
    local job_logs_trimmed="/tmp/job_${job_id}.trimmed"
    jq -r '.content //empty' "$job_logs_raw" > "$job_logs_content"
    if [ ! -s "$job_logs_content" ]; then
      tail -n "${max_lines}" "${job_logs_raw}" >> "${output_file}" 
    else
      #trim extra characters and truncate any logs for this plugin 
      sed -E '
    s/_bk;t=[0-9]+//g
    s/\\u001B_bk;t=[0-9]+\\u0007//g
    s/\\u001B\[[0-9;]*m//g
    s/\[[0-9;]*m//g
    s/\\r\\n/\n/g
    s/\\r/\n/g
    s/\\n/\n/g
    /~~~ Running plugin chatgpt-prompter post-command hook/,$d' "$job_logs_content" > "$job_logs_trimmed"
      tail -n "${max_lines}" "${job_logs_trimmed}" >> "${output_file}" 
      #cleanup other temp files
      rm -f "${job_logs_trimmed}"      
      rm -f "${job_logs_content}"
    fi

    #cleanup raw file
    rm -f "${job_logs_raw}"
  else
    echo "Could not fetch logs for this job." >> "${output_file}"
  fi
}

function analyse_build_info() {
  local bk_api_token="$1"
  local analysis_level="$2"

  local build_info="Build: ${BUILDKITE_PIPELINE_SLUG} #${BUILDKITE_BUILD_NUMBER}
Build Label: ${BUILDKITE_MESSAGE:-Unknown}
Build URL: ${BUILDKITE_BUILD_URL:-Unknown}
Build Source: ${BUILDKITE_SOURCE:-Unknown}"  

  if [ "${BUILDKITE_SOURCE}" == "trigger_job" ]; then
    build_info="${build_info}
Triggered from pipeline: ${BUILDKITE_TRIGGERED_FROM_BUILD_PIPELINE_SLUG:-Unknown}
Triggered from build: ${BUILDKITE_TRIGGERED_FROM_BUILD_NUMBER:-Unknown}"
  fi

  if [ "${BUILDKITE_PULL_REQUEST}" == true ]; then
    build_info="${build_info}
Pull Request: ${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-Unknown}
Pull Request URL: ${BUILDKITE_PULL_REQUEST_URL:-Unknown}"
  fi

  # Check if Buildkite API token is provided
  local log_file="/tmp/buildlog_${BUILDKITE_BUILD_ID}.txt"

  if ! touch "${log_file}" 2>/dev/null; then
    log_error "Could not create log file: ${log_file}"
    return 1
  fi

  local default_max_lines=1000
  if [ -n "${bk_api_token}" ]; then  
    if [ "${analysis_level}" == "step" ] && [ -n "${BUILDKITE_JOB_ID}" ]; then
      # Generate step-level build information
      get_job_logs "${bk_api_token}" "${BUILDKITE_JOB_ID}" "${log_file}" "${default_max_lines}"

      build_info="${build_info}
Job: ${BUILDKITE_LABEL:-Unknown}
Command: ${BUILDKITE_COMMAND:-Unknown}
Command Exit status: ${BUILDKITE_COMMAND_EXIT_STATUS:-0}"   
      
    else
      # Generate build-level information
      local build_details_file="/tmp/build_${BUILDKITE_BUILD_ID}.json"
      local build_url="https://api.buildkite.com/v2/organizations/${BUILDKITE_ORGANIZATION_SLUG}/pipelines/${BUILDKITE_PIPELINE_SLUG}/builds/${BUILDKITE_BUILD_NUMBER}"

      if curl -s -f -H "Authorization: Bearer ${bk_api_token}" "${build_url}" > "${build_details_file}" 2>/dev/null; then
          local started_at finished_at
          started_at=$(jq -r '.started_at // empty' "${build_details_file}" 2>/dev/null)
          finished_at=$(jq -r '.finished_at // empty' "${build_details_file}" 2>/dev/null)
          build_info="${build_info}
Build Started At: ${started_at}
Build Finished At: ${finished_at}"
 
          job_ids=$(jq -r '.jobs[].id // empty' "${build_details_file}" 2>/dev/null)
          if [ -n "${job_ids}" ]; then
            # Create a combined job log files
            : > "${log_file}"

            for job_id in ${job_ids}; do
              local job_name=$(jq -r --arg job_id "${job_id}" '.jobs[] | select(.id == $job_id) | .name // empty' "${build_details_file}")
              echo -e "\n===JOB:  ${job_name} (${job_id})===\n"  >> "${log_file}"

              local job_state=$(jq -r --arg job_id "${job_id}" '.jobs[] | select(.id == $job_id) | .state // empty' "${build_details_file}")
              local exit_status=$(jq -r --arg job_id "${job_id}" '.jobs[] | select(.id == $job_id) | .exit_status // empty' "${build_details_file}")
              echo "Job State: ${job_state}
Exit Status: ${exit_status}" >> "${log_file}"
              get_job_logs "${bk_api_token}" "${job_id}" "${log_file}" 1000
            done
          fi

          # fetch all job logs that have ran/finished
      rm -f "${build_details_file}"
      fi
    fi 
  fi

  local logs
  if ! logs=$(< "${log_file}"); then
    echo "Error: Failed to read log file: ${log_file}" >&2
    return 1
  fi

  # Construct prompt
  local base_prompt
  if [ "${analysis_level}" = "build" ]; then
    base_prompt="Analysis Level: Build Level (multiple jobs)
Build Information:
${build_info}

Build Logs (from multiple jobs):
\`\`\`
${logs}
\`\`\`

Please provide:
1. **Analysis**: What happened in this build? $([ "${BUILDKITE_COMMAND_EXIT_STATUS:-0}" -ne 0 ] && echo "Why did any jobs fail?" || echo "Any notable issues or warnings across jobs?")
2. **Key Points**: Important information across all jobs and their significance
3. **Trends**: Any patterns or trends observed in the logs (e.g., recurring errors, performance issues, etc.)

Focus on being practical and actionable. "

  else
    base_prompt="Analysis Level: Step Level (current job)
Step Information:
${build_info}

Build Logs:
\`\`\`
${logs}
\`\`\`
"  
  fi

  # Clean up
  rm -f "${log_file}"
  echo "${base_prompt}"
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

function validate_and_process_response() {
  local response="$1"
  
  # Check if response is empty
  if [ -z "${response}" ]; then
    log_error "No response received from OpenAI API."
    return 1
  fi
  
  # Check if the response contains an error
  if echo "${response}" | jq -e '.error' > /dev/null; then
    log_error "$(echo "${response}" | jq -r '.error.message')"
    return 1
  fi
  
  # Check if the response contains choices
  if ! echo "${response}" | jq -e '.choices' > /dev/null; then
    log_error "No choices found in the response from OpenAI API."
    return 1
  fi
  
  # Check if the response contains a message
  if ! echo "${response}" | jq -e '.choices[0].message.content' > /dev/null; then
    log_error "No message content found in the response from OpenAI API."
    return 1
  fi
  
  return 0
}

function call_openapi_chatgpt() {
  local api_secret_key="$1"
  local payload="$2"

  # Call the OpenAI API
  response=$(curl -sS -X POST "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer ${api_secret_key}" \
    -H "Content-Type: application/json" \
    -d "${payload}")
  
  echo "${response}"
}

function send_prompt() {
  local api_secret_key="$1"
  local base_prompt="$2"
  local model="$3"
  local user_prompt="$4" 
  local analysis_level="$5"

  local content=${base_prompt}
  if [ -z "${content}" ]; then
    log_error "Failed to generate build or step level information for analysis."
    return 1
  fi

  local prompt_payload
  prompt_payload=$(format_payload "${model}" "${user_prompt}" "${content}") 

  # Call the OpenAI API
  local response
  response=$(call_openapi_chatgpt "${api_secret_key}"  "${prompt_payload}")
  # Debug response format
  # local response
  # response=$(cat /Users/lizjr/Dev/lzr/chatgpt_response.txt) 

  log_info "ChatGPT Analysis Result"
  # Validate and process the response
  if ! validate_and_process_response "${response}"; then
    return 1
  fi

  # Extract and display the response content
  total_tokens=$(echo "${response}" | jq -r '.usage.total_tokens')
  echo "Summary:"
  echo "  Total tokens used: ${total_tokens}"

 
  content_response=$(echo "${response}" | jq -r '.choices[0].message.content' | sed 's/^/  /')  

  if [ -n "${content_response}" ]; then 
    annotation_file="/tmp/chatgpt_analysis.md"
    annotation_title="ChatGPT Step Level Analysis"
    if [ ${analysis_level} == "build" ]; then
      annotation_title="ChatGPT Build Level Analysis"
    fi

    # create annotation file
    {
      echo "# ${annotation_title}"
      echo "---"
      printf "%s\n" "${content_response}"
      echo "---"
    } > "${annotation_file}"

    # Check if the annotation file was created successfully
    if [ -f "${annotation_file}" ]; then
      echo "Annotating build with ChatGPT analysis ..."
      if [ ${analysis_level} == "build" ]; then
        buildkite-agent annotate --style "info" --context "chatgpt-analysis-${BUILDKITE_BUILD_ID}"  < "${annotation_file}"
      else
        buildkite-agent annotate --style "info" --context "chatgpt-analysis-${BUILDKITE_JOB_ID}"  < "${annotation_file}"
      fi
      echo "✅ Annotation created successfully."
      rm -f "${annotation_file}"
    else
      echo -e "ChatGPT analysis in Job ${BUILDKITE_JOB_ID} (${BUILDKITE_LABEL}) failed to generate an annotation file." | buildkite-agent annotate --style "error" --context "chatgpt-analysis-${BUILDKITE_JOB_ID}"
    fi
  else
    echo -e "ChatGPT analysis in Job ${BUILDKITE_JOB_ID} (${BUILDKITE_LABEL}) failed to generate content." | buildkite-agent annotate --style "error" --context "chatgpt-analysis-${BUILDKITE_JOB_ID}"
  fi

  return 0
}