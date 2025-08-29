# ChatGPT Analyzer Buildkite Plugin [![Build status](https://badge.buildkite.com/d673030645c7f3e7e397affddd97cfe9f93a40547ed17b6dc5.svg)](https://buildkite.com/buildkite/plugins-template)

A Buildkite plugin that provides build or step level analysis using ChatGPT.  

## Requirements

### Tools
- **curl**: For API requests
- **jq**: For JSON processing
- **OpenAI API Key**: For sending ChatGPT prompts. Create an OpenAI platform account from the [OpenAI Platform](http://platform.openai.com/login), or log in to an existing one. Generate an OpenAI API Key from the OpenAI dashboard → View OpenAI Keys menu. 
     
 
## Examples

### Using environment variable set at upload time 

Add to your Buildkite environment variables the OpenAI API Key as `OPENAI_API_KEY` and Buildkite API Token as `BUILDKITE_API_TOKEN`. 

```
steps:
  - label: "🔍 Prompt ChatGPT to summarise test results"
    command: "npm test"
    plugins:
      - chatgpt-analyzer#v0.0.1: ~
```

### Using Buildkite secrets (recommended)

First, create .buildkite/hooks/pre-command and set the environment variables using the Buildkite secrets where they are stored. 

```
#!/bin/bash
export OPENAI_API_KEY=$(buildkite-agent secret get OPENAI_API_KEY) 
export BUILDKITE_API_TOKEN=$(buildkite-agent secret get BUILDKITE_API_TOKEN)    
```

Use the environment variables set in the plugin.

```
steps:
  - label: "🔍 Prompt ChatGPT to summarise build"
    command: echo "Summarise build"
    plugins:
      - chatgpt-analyzer#v0.0.1: ~
```


## Configuration


### Optional

#### `api_key` (string)

The environment variable that the OpenAI API key is stored in. Defaults to using `OPENAI_API_KEY`. The recommended approach for storing your API key is to use [Buildkite Secrets](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets).

The plugin will fail if no OpenAI key is set. 

#### `buildkite_api_token` (string)

The environment variable that the Buildkite API Token is stored in. Defaults to `BUILDKITE_API_TOKEN`. If the env var is not set, the plugin will show a warning and will default to using step level analysis. The Buildkite API token is used for fetching build information from the Buildkite API to use for build level analysis. The Buildkite API token should have at least `read_builds` and `read_build_logs` [token scopes](https://buildkite.com/docs/apis/managing-api-tokens#token-scopes), otherwise API calls will fail. 

#### `analysis_level` (string)

The level of analysis to perform on the logs. Options: `step`, `build`. If a `buildkite_api_token` is provided, this will fetch job logs and build information. Otherwise, available environment variables will be used.  Defaults to `step`.

#### `model` (string)

The ChatGPT model. Defaults to `GPT 5-nano`.

#### `custom_prompt` (string)

Additional context to include in ChatGPT's analysis.   

## Examples

## Provide Additional Context  

If you want to provide additional context or instructions to the default build summary, provide a `custom_prompt` parameter to the plugin. 

```yaml
steps:
  - label: "🔍 Prompt ChatGPT to focus on build performance"
    command: "echo template plugin with options"
    plugins:
      - chatgpt-analyzer#v0.0.1:
          api_key: "$OTHER_OPENAI_API_TOKEN"
          buildkite_api_token: "$OTHER_BUILDKITE_API_TOKEN"
          model: "gpt-5-nano"
          custom_prompt: "Focus on build performance and optimization opportunities"
        
```

## Compatibility

| Elastic Stack | Agent Stack K8s | Hosted (Mac) | Hosted (Linux) | Notes |
| :-----------: | :-------------: | :----------: | :------------: | :---- |
| ✅ | ✅ | ✅ | ✅ |   |

- ✅ Fully compatible assuming requirements are met

## Developing

Run tests with

```bash
docker run --rm -ti -v "${PWD}":/plugin buildkite/plugin-tester:latest
```

## 👩‍💻 Contributing

We welcome all contributions to improve this plugin! To contribute, please follow these guidelines:

1. Fork the repository
2. Create a feature branch
3. Make your changes and ensure that the tests pass.
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

By contributing, you agree to license your contributions under the LICENSE file of this repository.

## 📜 License

The package is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
