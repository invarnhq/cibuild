# cibuild

Lightweight CI/CD pipeline runner for Android and iOS projects. Define your pipelines in YAML or TypeScript and run them locally or dispatch to a remote runner — no CI server required.

---

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

Both methods install two identical commands: `ci` and `cibuild`.

---

## Quick Start

```bash
# From the root of your Android or iOS project:
ci init              # Check dependencies and set up your pipeline
ci run pipeline.yml  # Run on remote runner
ci run pipeline.yml --local  # Run locally for development
```

---

## Commands

| Command | Description |
|---|---|
| `ci init` | Check dependencies and set up your pipeline interactively |
| `ci run <path> [-w <name>]` | Run pipeline on remote runner (production) |
| `ci run <path> [-w <name>] --local` | Run pipeline locally (development) |
| `ci edit <path> [-w <name>]` | Inspect and edit step inputs interactively |
| `ci secrets add <var> <path>` | Store a secret (prompted interactively) |
| `ci secrets add <var> <path> --file <file>` | Store a secret from a file |
| `ci detect-platform <path> [-w <name>]` | Detect platform from a YAML pipeline |
| `ci --help` | Show help |

### Options

| Flag | Description |
|---|---|
| `-w, --workflow <name>` | Select a workflow (YAML pipelines only, defaults to first) |
| `--local` | Run pipeline locally instead of on a remote runner |
| `--skip-validation` | Skip pre-execution validation |

---

## Pipeline Format

### YAML

```yaml
# android-build.yml
workflows:
  release:
    steps:
      - script:
          inputs:
            - content: ./gradlew assembleRelease
```

Run it:

```bash
ci run android-build.yml -w release
```

**Supported extensions:** `.yml`, `.yaml`

---

## Secrets

Secrets are stored locally in `~/.cibuild-secrets.json` and never committed.

```bash
# Store a secret interactively
ci secrets add KEYSTORE_PASSWORD android-build.yml

# Store a secret from a file (e.g. a base64-encoded keystore)
ci secrets add KEYSTORE_BASE64 android-build.yml --file release.keystore

# Store a secret scoped to a specific workflow
ci secrets add SLACK_WEBHOOK android-build.yml -w release
```

---

## Requirements

- macOS (arm64 or x64)
- Android projects: JDK, Android SDK
- iOS projects: Xcode (CocoaPods optional)

Run `ci init` from your project root to check all dependencies automatically.

---

## Examples

```bash
ci run ios-build.yml -w pull-request
ci run ios-build.yml -w pull-request --local
ci run ios-build.yml -w release
ci edit android-build.yml -w debug
```
