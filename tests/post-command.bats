#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PLUGIN_CHATGPT_ANALYZER_API_KEY='test0aou'
  export BUILDKITE_PLUGIN_CHATGPT_ANALYZER_BUILDKITE_API_TOKEN='test-bk-token'
  export BUILDKITE_ORGANIZATION_SLUG="testorg"
  export BUILDKITE_PIPELINE_SLUG="test-pipeline"
  export BUILDKITE_BUILD_NUMBER="1"
  export BUILDKITE_BUILD_ID="123-test-build-id"
  export BUILDKITE_JOB_ID="456-job-id"
  export BUILDKITE_SOURCE="ui"
  export BUILDKITE_PULL_REQUEST="false"
  export BUILDKITE_LABEL="Test Job 456"

  # create a mock response file for curl to use
  mkdir -p /tmp
  printf '{"choices":[{"message":{"role": "assistant", "content": "Here is a practical Analysis for this Build \nMock Analysis Result"}}]}' > "/tmp/chatgpt_analyzer_response_${BUILDKITE_BUILD_ID}.json"

  # Mock tools with simpler stubs
  stub curl \
    "* : echo '200'"
  stub jq \
    "* : echo 'Mock analysis result'"
  stub buildkite-agent \
    "annotate --style * --context * : echo 'Annotation created'"

}

teardown() {
  # Remove the mock response file
  rm -f "/tmp/chatgpt_analyzer_response_${BUILDKITE_BUILD_ID:-123-test-build-id}.json"

  # Only unstub if they were actually stubbed
  unstub curl || true
  unstub jq || true
  unstub buildkite-agent || true

}

@test "Missing OpenAI API Key fails" {
  unset BUILDKITE_PLUGIN_CHATGPT_ANALYZER_API_KEY

  run "$PWD"/hooks/post-command

  assert_success
  assert_output --partial 'ChatGPT Analyzer Plugin'
  assert_output --partial 'OpenAI API Key not found' 
}

@test "Minimal Configuration" {
  run "$PWD"/hooks/post-command

  assert_success
  assert_output --partial 'ChatGPT Analyzer Plugin'
  assert_output --partial 'OpenAI API Key found'
  assert_output --partial 'Loading Plugin with configurations:'
  assert_output --partial '-----------------------------------'
  assert_output --partial 'Using Model: gpt-5-nano'
  assert_output --partial 'Analysis Level: step' 
  assert_output --partial 'Build Comparison: Disabled'
  assert_output --partial '-----------------------------------'
  assert_output --partial 'Build Summary generated'
  assert_output --partial 'ChatGPT Analysis complete'
}

@test "Specify new values for Optional Configuration" {
  export BUILDKITE_PLUGIN_CHATGPT_ANALYZER_ANALYSIS_LEVEL='build'
  export BUILDKITE_PLUGIN_CHATGPT_ANALYZER_MODEL='gpt-5'
  export BUILDKITE_PLUGIN_CHATGPT_ANALYZER_CUSTOM_PROMPT='Custom prompt. This is an additional Custom Prompt '
  export BUILDKITE_PLUGIN_CHATGPT_ANALYZER_COMPARE_BUILDS='true'
  export BUILDKITE_PLUGIN_CHATGPT_ANALYZER_BUILD_COMPARISON_RANGE=10

  run "$PWD"/hooks/post-command

  assert_success
  assert_output --partial 'ChatGPT Analyzer Plugin'
  assert_output --partial 'Loading Plugin with configurations:'
  assert_output --partial '-----------------------------------'
  assert_output --partial 'Using Model: gpt-5'
  assert_output --partial 'Analysis Level: build'
  assert_output --partial 'Using Custom Prompt: Custom prompt. This is an additional Custom Prompt '
  assert_output --partial 'Build Comparison: ENABLED. Comparing with last 10 builds.'
  assert_output --partial '-----------------------------------'
  assert_output --partial 'Build Summary generated'
  assert_output --partial 'ChatGPT Analysis complete'
}

@test "Plugin runs with environment variable data" {
  unset BUILDKITE_PLUGIN_CHATGPT_ANALYZER_BUILDKITE_API_TOKEN
  export BUILDKITE_SOURCE='ui' 
  export BUILDKITE_COMMAND='echo "Hello, World!"'
  export BUILDKITE_COMMAND_EXIT_STATUS='0'

  run "$PWD"/hooks/post-command

  assert_success 
  assert_output --partial 'ChatGPT Analyzer Plugin'
  assert_output --partial 'Build Summary generated'
  assert_output --partial 'ChatGPT Analysis complete'
}

@test "Plugin handles invalid API Token" {
  export BUILDKITE_PLUGIN_YOUR_CHATGPT_ANALYSER_BUILDKITE_API_TOKEN='invalid_token' 
  export BUILDKITE_SOURCE='ui' 
  export BUILDKITE_COMMAND='echo "Hello, World!"'
  export BUILDKITE_COMMAND_EXIT_STATUS='0'

  run "$PWD"/hooks/post-command

  assert_success 
  assert_output --partial 'ChatGPT Analyzer Plugin' 
  assert_output --partial 'Build Summary generated'
  assert_output --partial 'No valid response received from OpenAI API'
  assert_output --partial 'ChatGPT Analysis complete'
}



 