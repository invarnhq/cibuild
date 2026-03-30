# cibuild

The fastest way to set up iOS and Android CI on GitHub - define pipelines in YAML, run locally or on GitHub Actions.

## Install

**Homebrew (recommended)**

```bash
brew tap invarnhq/cibuild
brew install cibuild
```

**curl**

```bash
curl -fsSL https://raw.githubusercontent.com/invarnhq/cibuild/main/install.sh | bash
```

**npm**

```bash
npm install -g @invarn/cibuild
```

All methods install two identical commands: `ci` and `cibuild`.

## Getting Started

### Option 1. Auto-create (recommended)

From your project root, let cibuild scan the project and generate a pipeline with recommended defaults:

```bash
ci init --create
```

This auto-detects the platform (iOS/Android), configures build settings, collects secrets from disk, and generates a ready-to-use GitHub Actions workflow — fully non-interactive, works with AI agents and scripts.

### Option 2. Interactive wizard

Walk through prompts to configure your pipeline step by step:

```bash
ci init
```

### Option 3. Import existing pipeline

If you already have a pipeline YAML file:

```bash
ci init --import path/to/pipeline.yml
```

All three methods scaffold the `.ci/pipelines/` directory, generate `.github/workflows/ci.yml`, validate dependencies, and set up `.gitignore`.

### Customize

cibuild works best when you start with `ci init --create` and build on top of the generated pipeline. The full pipeline format, step catalog, and customization rules are in the spec.

Tell your AI coding agent:

> Set up and customize CI/CD pipelines for this project using cibuild according to the following spec: https://github.com/invarnhq/cibuild/blob/main/SPEC.md

### Run

```bash
ci run                                         # Run the default pipeline
ci run .ci/pipelines/cibuild.yml -w release    # Run a specific workflow
```

## Commands

| Command | Description |
|---|---|
| `ci init` | Interactive setup wizard |
| `ci init --create` | Auto-create pipeline (non-interactive) |
| `ci init --import <path>` | Import YAML pipeline (non-interactive) |
| `ci build` | Generate a standard pipeline for the current project |
| `ci run <path> [-w <name>]` | Run pipeline locally (development mode) |
| `ci run <path> [-w <name>] --production` | Run on remote runner (production) |
| `ci run <path> [-w <name>] --validate-only` | Validate only, don't execute |
| `ci run <path> [-w <name>] --skip-validation` | Skip validation, run with interactive prompts |
| `ci validate <path> [-w <name>]` | Validate pipeline (alias for --validate-only) |
| `ci detect-platform <path> [-w <name>]` | Detect platform from YAML pipeline |
| `ci edit <path> [-w <name>]` | View pipeline and edit step inputs |
| `ci secrets add <var> <path> [-w <name>]` | Add a secret (prompted interactively) |
| `ci secrets add <var> <path> --file <file>` | Add a secret from a file |
| `ci secrets upload [--env <name>]` | Upload secrets to GitHub environment |
| `ci secrets sync-workflow <path>` | Sync secret mappings into workflow YAML |
| `ci --help` | Show help |

### Options

| Flag | Description |
|---|---|
| `-w, --workflow <name>` | Select a workflow (YAML pipelines only, defaults to first) |
| `--production` | Execute on remote runner after validation (vs local) |
| `--validate-only` | Run validation only, don't execute pipeline |
| `--skip-validation` | Skip pre-execution validation (for development) |

## Secrets

Secrets are stored locally in `.cibuild-secrets.json` and never committed.

```bash
ci secrets add KEYSTORE_PASSWORD pipeline.yml
ci secrets add KEYSTORE_BASE64 pipeline.yml --file release.keystore
ci secrets add SLACK_WEBHOOK pipeline.yml -w release
```

### Deploy to GitHub

Push all local secrets to a GitHub Environment in one command:

```bash
ci secrets upload
```

This uploads every secret to the `cibuild` environment on GitHub and automatically syncs the `env:` mappings in `.github/workflows/ci.yml`. Requires [GitHub CLI](https://cli.github.com/) (`gh auth login`).

## GitHub Actions

Use cibuild directly in your GitHub Actions workflows:

```yaml
name: CI
on: [push, pull_request]

jobs:
  build:
    runs-on: macos-latest
    environment: cibuild
    steps:
      - uses: actions/checkout@v4
      - uses: invarnhq/cibuild@v1
        with:
          workflow: release
```

### Action Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `pipeline` | No | Auto-discover | Path to pipeline YAML file |
| `workflow` | No | First workflow | Workflow name within the pipeline |
| `version` | No | `latest` | cibuild version to install |

The action automatically maps GitHub context to cibuild environment variables (`GIT_BRANCH`, `GIT_COMMIT`, `BUILD_NUMBER`, `BUILD_URL`). See [Secrets](#secrets) for setting up secret access in CI.

## Examples

| Project | Platform | Status |
|---|---|---|
| [CITestiOS](https://github.com/invarnhq/CITestiOS) | iOS | [![CI](https://github.com/invarnhq/CITestiOS/actions/workflows/ci.yml/badge.svg)](https://github.com/invarnhq/CITestiOS/actions/workflows/ci.yml) |
| [CITestAndroid](https://github.com/invarnhq/CITestAndroid) | Android | [![CI](https://github.com/invarnhq/CITestAndroid/actions/workflows/ci.yml/badge.svg)](https://github.com/invarnhq/CITestAndroid/actions/workflows/ci.yml) |

## Requirements

- macOS or Linux (Node.js 18+ for npm install)
- Android projects: JDK, Android SDK
- iOS projects: macOS with Xcode (CocoaPods optional)

Run `ci init` from your project root to check all dependencies automatically.
