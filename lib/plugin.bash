#!/bin/bash
set -euo pipefail

# Load log utility
# shellcheck disable=SC1091
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

  if ! command -v date &> /dev/null; then
    log_error "date command not found. Please make sure the environment PATH is able to locate the command or the agent has the proper permissions." >&2
    errors=$((errors + 1))
  fi  

  return ${errors}
}

function get_openai_api_key() { 
  local api_key=""
  api_key=$(plugin_read_config API_KEY "")  

  if [ -z "${api_key}" ]; then
      api_key="${OPENAI_API_KEY:-}"
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
  fi

  # Trim any whitespace that might be causing issues
  bk_token=$(echo "${bk_token}" | tr -d '[:space:]')
  echo "${bk_token}"
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
    /~~~ Running plugin chatgpt-analyzer post-command hook/,$d' "$job_logs_content" > "$job_logs_trimmed"
      tail -n "${max_lines}" "${job_logs_trimmed}" >> "${output_file}" 
      #cleanup other temp files
      rm -f "${job_logs_trimmed}"      
      rm -f "${job_logs_content}"
    fi

    #cleanup raw file
    rm -f "${job_logs_raw}" 
  fi
}

 
function get_build_environment_details() {
  local analysis_level="$1"

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

  if [ "${analysis_level}" == "step" ] && [ -n "${BUILDKITE_JOB_ID}" ]; then
    # add step information from environment variables
    build_info="${build_info}
Job: ${BUILDKITE_LABEL:-Unknown}
Command: ${BUILDKITE_COMMAND:-Unknown}
Command Exit status: ${BUILDKITE_COMMAND_EXIT_STATUS:-0}" 
  fi

  echo "${build_info}"
}

function get_build_summary() {
  local bk_api_token="$1"
  local analysis_level="$2"
  local compare_builds="${3:-false}"
  local comparison_range="${4:-5}"  

  local build_info
  build_info=$(get_build_environment_details "${analysis_level}")

  local current_build_time="0"
  local current_time_note=""

  # prepare retrieving build or job logs
  local default_max_lines=1000  
  local log_file="/tmp/buildkite_logs_${BUILDKITE_BUILD_ID}.txt" 
  if ! touch "${log_file}" 2>/dev/null; then
    log_error "Could not create log file: ${log_file}"
    return 1
  fi   

 
  if [ "${analysis_level}" == "step" ] && [ -n "${BUILDKITE_JOB_ID}" ]; then  
    # Get job logs
    get_job_logs "${bk_api_token}" "${BUILDKITE_JOB_ID}" "${log_file}" "${default_max_lines}"
    
  else
    # Generate build-level information
    local build_details_file="/tmp/build_details_${BUILDKITE_BUILD_ID}.json"
    local build_url="https://api.buildkite.com/v2/organizations/${BUILDKITE_ORGANIZATION_SLUG}/pipelines/${BUILDKITE_PIPELINE_SLUG}/builds/${BUILDKITE_BUILD_NUMBER}"

    if curl -s -f -H "Authorization: Bearer ${bk_api_token}" "${build_url}" > "${build_details_file}" 2>/dev/null; then

      local started_at finished_at
      started_at=$(jq -r '.started_at // empty' "${build_details_file}" 2>/dev/null)
      finished_at=$(jq -r '.finished_at // empty' "${build_details_file}" 2>/dev/null)
      build_info="${build_info}
Build Started At: ${started_at}
Build Finished At: ${finished_at}"


      #check and calculate build time if build has finished
      if [ -n "${started_at}" ] && [ -n "${finished_at}" ] && [ "${finished_at}" != "null" ]; then
        local start_epoch finish_epoch
        start_epoch=$(get_epoch_time "${started_at}")
        finish_epoch=$(get_epoch_time "${finished_at}")
        if [ -n "${start_epoch}" ] && [ -n "${finish_epoch}" ]; then
          current_build_time=$((finish_epoch - start_epoch))
          build_info="${build_info}
  Build Duration: ${current_build_time}s"
        fi
      elif [ -n "${started_at}" ] && { [ -z "${finished_at}" ] || [ "${finished_at}" = "null" ]; }; then
        # build is still running, compute partial running time
        current_time_note="Note: Build is still running. This is the partial build duration."
        local start_epoch now_epoch
        start_epoch=$(get_epoch_time "${started_at}")
        now_epoch=$(date +%s)

        if [ -n "${start_epoch}" ] && [ -n "${now_epoch}" ]; then
          current_build_time=$((now_epoch - start_epoch))
          build_info="${build_info}
  Build Duration: ${current_build_time}s"
        fi
      fi 

      # Get and combine build job logs
      job_ids=$(jq -r '.jobs[].id // empty' "${build_details_file}" 2>/dev/null)
      if [ -n "${job_ids}" ]; then
        # Create a combined job log files
        : > "${log_file}"

        for job_id in ${job_ids}; do
          local job_name
          local job_state
          local exit_status

          job_name=$(jq -r --arg job_id "${job_id}" '.jobs[] | select(.id == $job_id) | .name // empty' "${build_details_file}")
          echo -e "\n===JOB:  ${job_name} (${job_id})===\n"  >> "${log_file}"
          
          job_state=$(jq -r --arg job_id "${job_id}" '.jobs[] | select(.id == $job_id) | .state // empty' "${build_details_file}")
          exit_status=$(jq -r --arg job_id "${job_id}" '.jobs[] | select(.id == $job_id) | .exit_status // empty' "${build_details_file}")
          echo "Job State: ${job_state}
Exit Status: ${exit_status}" >> "${log_file}"
          
          get_job_logs "${bk_api_token}" "${job_id}" "${log_file}" 1000
        done
      fi

     # fetch all job logs that have ran/finished
    rm -f "${build_details_file}"
    fi
  fi 
  
  local logs
  if ! logs=$(< "${log_file}"); then
    echo "Error: Failed to read log file: ${log_file}" >&2
    return 1
  fi

  # Construct build summary
  local build_summary
  build_summary="The following is the summary of the Buildkite  ${analysis_level}. Analysis is requested according to the system instructions provided.
  
  Build Information:
${build_info}"

  # check if logs are empty
  if [ -z "${logs}" ]; then
    # Default analysis using environment variables
    build_summary="${build_summary} 

Warning: Detailed logs could not be retrieved. This may be due to:
- Missing BUILDKITE_API_TOKEN environment variable
- Insufficient permissions to access logs

To improve log analysis, ensure that the BUILDKITE_API_TOKEN is set with appropriate permissions.
"
    echo "${build_summary}"
    return
  fi

  # build time comparison if enabled
  local build_history_analysis
  build_history_analysis=""
  if [ "${compare_builds}" == "true" ] && [ -n "${current_build_time}" ]; then
    local build_analysis_file="/tmp/build_time_analysis_${BUILDKITE_BUILD_ID}.txt" 
    if create_buildlevel_comparison "${bk_api_token}" "${comparison_range}" "${current_build_time}" "${current_time_note}" "${build_analysis_file}"; then
      build_history_analysis="$(< "${build_analysis_file}")"
    fi
    rm -f "${build_analysis_file}"
  fi 

  # Add build history time analysis if available
  if [ -n "${build_history_analysis}" ]; then
    build_summary="${build_summary}

${build_history_analysis}"
  fi  

  # append the job logs to the summary
  build_summary="${build_summary}
  
Build Logs (from multiple jobs):
\`\`\`
${logs}
\`\`\`"  

  # Clean up
  rm -f "${log_file}"
  echo "${build_summary}"
}
 
function create_buildlevel_comparison() {
  local bk_api_token="$1" 
  local comparison_range="${2:-5}"
  local current_build_time="$3"
  local current_build_note="$4"
  local build_analysis_file="$5"

  local page_count=$((comparison_range + 10))
  local past_dates 
  if [[ "$(uname)" == "Darwin" || "$(uname)" == *"BSD"* ]]; then
    past_dates=$(date -v-30d '+%Y-%m-%d')
  else
    past_dates=$(date -d '30 days ago' '+%Y-%m-%d')
  fi

 
  local builds_url
  local build_history_file

  builds_url="https://api.buildkite.com/v2/organizations/${BUILDKITE_ORGANIZATION_SLUG}/pipelines/${BUILDKITE_PIPELINE_SLUG}/builds?per_page=${page_count}&finished_from=${past_dates}"
  build_history_file="/tmp/build_history_${BUILDKITE_BUILD_ID}.json"

  #filter builds from the same branch if set
  if [ -n "${BUILDKITE_BRANCH}" ]; then
    builds_url="${builds_url}&branch=${BUILDKITE_BRANCH}"
  fi

  # Exclude current build and only include finished builds
  if curl -s -f -H "Authorization: Bearer ${bk_api_token}" "${builds_url}" > "${build_history_file}" 2>/dev/null; then
    # Successfully retrieved build history
      local filtered_builds
      filtered_builds=$(jq --arg current_build "${BUILDKITE_BUILD_NUMBER}" '
        [.[] | select(.number != ($current_build | tonumber) and (.state != "running" and .state != "scheduled" and .state != "creating" and .state != "canceling" and .state != "failing" and .state != "blocked"))]
        | sort_by(.number)
        | reverse
        | .[:'"${comparison_range}"']' "${build_history_file}" 2>/dev/null)

      if [ -n "${filtered_builds}" ] && [ "${filtered_builds}" != "[]" ]; then
        echo "${filtered_builds}" > "${build_history_file}"
      fi
  fi


  if [ ! -f "${build_history_file}" ]; then
    # file not found, exit
    return 1
  fi

  { 
    echo "Build Time Comparison Analysis"
    echo "Current Build: #${BUILDKITE_BUILD_NUMBER}, Duration: ${current_build_time}s"
    # Add timing note if build is still running
    if [ -n "${current_build_note}" ]; then
      echo "${current_build_note}"
    fi
    echo ""
    echo "Recent Build History:"
    # Format build information
   jq -r '.[] | " Build #\(.number): \((.finished_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - (.started_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601))s (\(.state)) - \(.message // "No message" | .[0:60])"' "${build_history_file}" 2>/dev/null

    echo "Build Time Statistics:"

    # Calculate average, min, max for builds
    local times
    times=$(jq -r '.[] | (.finished_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - (.started_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)' "${build_history_file}" 2>/dev/null)


    if [ -n "${times}" ]; then
      local avg min max count
      avg=$(echo "${times}" | awk '{sum+=$1} END {printf "%.0f", sum/NR}')
      min=$(echo "${times}" | sort -n | head -1)
      max=$(echo "${times}" | sort -n | tail -1)
      count=$(echo "${times}" | wc -l)

      echo "- Average: ${avg}s (over ${count} builds)"
      echo "- Fastest: ${min}s"
      echo "- Slowest: ${max}s"
      echo "- Current vs Average: $((current_build_time - avg))s difference"

      # Trend analysis
      if [ "${current_build_time}" -gt $((avg + 60)) ]; then
        echo "- Trend: ⚠️  Current build is significantly slower than average"
      elif [ "${current_build_time}" -gt "${avg}" ]; then
        echo "- Trend: 📈 Current build is slower than average"
      elif [ "${current_build_time}" -lt $((avg - 60)) ]; then
        echo "- Trend: ⚡ Current build is significantly faster than average"
      else
        echo "- Trend: ✅ Current build time is normal"
      fi
    fi
    echo -e "\n---\n"
  } > "${build_analysis_file}"

  #cleanup temp file
  rm -f "${build_history_file}" 

  if [ -s "${build_analysis_file}" ]; then
    return 0
  fi
 
  return 1
} 


function get_epoch_time() {
    local datetime="$1"    
    local stripped_datetime="${datetime%.???Z}"

    local epoch_time
    if [[ "$(uname)" == "Darwin" || "$(uname)" == *"BSD"* ]]; then
        epoch_time=$(date -jf "%Y-%m-%dT%H:%M:%S" "$stripped_datetime" +%s 2>/dev/null || echo "")
    else
        epoch_time=$(date -d "${datetime}" +%s 2>/dev/null || echo "")
    fi
    
    echo "${epoch_time}"
}

function extract_api_response() {
  local response_file="$1"
  
  # Check if response file exists and is not empty
  if [ ! -f "${response_file}" ] || [ ! -s "${response_file}" ]; then
    echo "Error: API Response file not found or empty."
    return 1
  fi
  
  # Read response content from file
  local response
  response=$(cat "${response_file}")
  
  # Check if the response contains an error
  if echo "${response}" | jq -e '.error' > /dev/null 2>&1; then
    echo "Error: $(echo "${response}" | jq -r '.error.message')"
    return 1
  fi
  
  # Check if the response contains choices
  if ! echo "${response}" | jq -e '.choices' > /dev/null 2>&1; then
    echo "No choices found in the response from OpenAI API."
    return 1
  fi
  
  # Check if the response contains a message
  if ! echo "${response}" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    echo "No message content found in the response from OpenAI API."
    return 1
  fi
  
  # Check if content is not null or empty
  local content
  content=$(echo "${response}" | jq -r '.choices[0].message.content')
  if [ -z "$content" ] || [ "$content" = "null" ]; then
    echo "The API's message content is empty or null."
    return 1
  fi
  
  # Output the extracted content
  echo "$content"
  return 0
}

function call_openai_api() {
  local api_secret_key="$1"
  local model="$2"
  local system_prompt="$3"
  local user_content="$4" 
   
  local user_content_file="/tmp/chatgpt_analyzer_content_${BUILDKITE_BUILD_ID}.txt"
  local payload_file="/tmp/chatgpt_analyzer_payload_${BUILDKITE_BUILD_ID}.json"

  # Write user content to temporary file
  printf '%s' "$user_content" > "$user_content_file"

  # Prepare the payload using file input for user_content and arg for system_prompt
  jq -n \
    --arg model "$model" \
    --arg system_prompt "$system_prompt" \
    --rawfile user_content "$user_content_file" \
     '{
        model: $model,
        messages: [
          { role: "system", content: $system_prompt },
          { role: "user", content: $user_content }
        ]
      }' > "$payload_file"

  # Clean up temporary files
  rm -f "$user_content_file"

  # create a debug file to log curl request and response details
  local debug_file="/tmp/chatgpt_analyzer_debug_${BUILDKITE_BUILD_ID}.log"
  local response_file="/tmp/chatgpt_analyzer_response_${BUILDKITE_BUILD_ID}.json" 

  # Initialize debug file
  {
    echo "OpenAI API Debug Log"
    echo "Timestamp: $(date)"
    echo "Model: ${model}"
    echo "Payload file: ${payload_file}"
    echo "Response file: ${response_file}"
  } > "${debug_file}" 

  # check if response file already exists locally and is not empty, return it directly
  if [ -f "$response_file" ] && [ -s "$response_file" ]; then
    echo "${response_file}"  
    return 0
  fi
 
  # Call the OpenAI API and store response to file 
  local http_code 
  http_code=$(curl -sS -o "$response_file" -w "%{http_code}" \
    -X POST "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer ${api_secret_key}" \
    -H "Content-Type: application/json" \
    -d "@${payload_file}" \
    -o "${response_file}" 2>> "${debug_file}")

  if [ -n "${http_code}" ] && [ "${http_code}" -ne 200 ]; then
    echo "OpenAI API call failed with HTTP code: ${http_code}" >&2 
    # extract error message from response if available
    if [ -s "${response_file}" ]; then
      local error_message
      error_message=$(jq -r '.error.message // empty' "${response_file}" 2>/dev/null)
      if [ -n "${error_message}" ]; then
        echo "Error message from OpenAI API: ${error_message}" >&2
        echo "Response content: $(cat "${response_file}")" >> "${debug_file}"
      fi
    fi
    return 1
  fi

  
  #clean up payload file
  rm -f "${payload_file}"
  # Return the response file path
  if [ ! -s "${response_file}" ]; then
    echo "Error: OpenAI API response is empty." >&2
    echo "Errror: Unable to retrieve valid response from OpenAI API." >> "${debug_file}"
    return 1
  fi
  echo "${response_file}"  

}

function analyse_build() {
  local api_secret_key="$1"
  local build_summary="$2"
  local model="$3"
  local custom_prompt="$4"  
  local analysis_level="$5"
  local compare_builds="${6:-false}"


  if [ -z "${build_summary}" ]; then
    log_error "Failed to generate build or step level information for analysis."
    return 1
  fi

  #setup the system prompt
  local system_prompt
  system_prompt=$(build_system_prompt "${analysis_level}" "${custom_prompt}" "${compare_builds}")

  # Call the OpenAI API
  local response_file
  response_file=$(call_openai_api "${api_secret_key}"  "${model}" "${system_prompt}" "${build_summary}")

  log_section "ChatGPT Analysis Result" 
  local api_content
  if api_content=$(extract_api_response "${response_file}"); then
 
    # Extract and display the response content
    local response_content
    response_content=$(cat "${response_file}")
    total_tokens=$(echo "${response_content}" | jq -r '.usage.total_tokens')
    echo "Summary:"
    echo "  Total tokens used: ${total_tokens}"

    content_response="${api_content//$'\n'/$'\n'  }"
    content_response="  ${content_response}"
    if [ -n "${content_response}" ]; then
      annotation_file="/tmp/chatgpt_analysis.md"
      annotation_title="ChatGPT Analyzer Plugin: Step Level Analysis"
      if [ "${analysis_level}" == "build" ]; then
        annotation_title="ChatGPT Analyzer Plugin: Build Level Analysis"
      fi

      # create annotation file
      {
        echo "### ${annotation_title}"
        echo "---"
        echo "${content_response}"
        echo "---"
      } > "${annotation_file}"

      # Check if the annotation file was created successfully
      if [ -f "${annotation_file}" ]; then 
        if [ "${analysis_level}" == "build" ]; then
          buildkite-agent annotate --style "info" --context "chatgpt-analysis-${BUILDKITE_BUILD_ID}"  < "${annotation_file}"
        else
          buildkite-agent annotate --style "info" --context "chatgpt-analysis-${BUILDKITE_JOB_ID}"  < "${annotation_file}"
        fi
        echo "Annotation created successfully. ✅" 
        rm -f "${annotation_file}"
      else
        echo -e "ChatGPT analysis in Job ${BUILDKITE_JOB_ID} (${BUILDKITE_LABEL}) failed to generate an annotation file." | buildkite-agent annotate --style "error" --context "chatgpt-analysis-${BUILDKITE_JOB_ID}"
        echo "ChatGPT Analysis failed. Annotation file generation failed. ❌"
      fi
    else
      echo -e "ChatGPT analysis in Job ${BUILDKITE_JOB_ID} (${BUILDKITE_LABEL}) failed to generate content." | buildkite-agent annotate --style "error" --context "chatgpt-analysis-${BUILDKITE_JOB_ID}"
      echo "ChatGPT Analysis failed. API content response does not look valid. ❌"
    fi
  else
    echo -e "ChatGPT analysis in Job ${BUILDKITE_JOB_ID} (${BUILDKITE_LABEL}) failed to send summary to ChatGPT for analysis. Check logs for details." | buildkite-agent annotate --style "error" --context "chatgpt-analysis-${BUILDKITE_JOB_ID}"
    echo "ChatGPT Analysis failed. No valid response received from OpenAI API. ❌"
  fi

  # Clean up response file
  rm -f "${response_file}"
  
  return 0
}

function build_system_prompt() {
  local analysis_level="$1"
  local custom_prompt="$2"
  local compare_builds="${3:-false}"

  local system_prompt
  system_prompt="You are an expert software engineer and DevOps specialist specialising in Buildkite."
   
  if [ -n "${custom_prompt}" ]; then
      system_prompt="${custom_prompt}"
  else 
      system_prompt="${system_prompt} Please provide a detailed analysis of the ${analysis_level} information provided." 
      if [ "${analysis_level}" = "build" ]; then
        system_prompt="${system_prompt} Focus on the following aspects:
1. **Analysis**: What happened in this build? Any notable issues or warnings across jobs?
2. **Key Points**: Important information across all jobs and their significance."
        if [ "${compare_builds}" = "true" ]; then
          system_prompt="${system_prompt} 
3. **Build Time Comparison**: Analyze the build time trends compared to recent builds. Identify patterns or anomalies in build duration."
        fi
      else
        system_prompt="${system_prompt} Focus on the following aspects:
1. **Analysis**: What happened in this job? $([ "${BUILDKITE_COMMAND_EXIT_STATUS:-0}" -ne 0 ] && echo "Why did this job fail?" || echo "Any notable issues or warnings in this job?")
2. **Key Points**: Important information in this job."
        if [ "${compare_builds}" = "true" ]; then
          system_prompt="${system_prompt} 
3. **Job's Run Time Comparison**: Analyze the job's run time trends compared to recent builds. Identify patterns or anomalies in job duration."
        fi
      fi
  fi
  echo "${system_prompt}

If no errors are found, just confirm the build succeeded.
Do not include speculative or unrelated information."

}