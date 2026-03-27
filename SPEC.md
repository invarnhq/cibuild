# cibuild Pipeline Specification

## 1. Overview

cibuild is a CLI tool for defining and running CI/CD pipelines locally and in CI environments.

- Pipelines are defined as YAML files in the `.ci/pipelines/` directory
- Run with: `ci run pipeline -p <path> -w <workflow>`
- Supports iOS (Xcode) and Android (Gradle) builds

## 2. Pipeline YAML Format

Full schema with annotations:

```yaml
format_version: '1'

meta:
  cibuild.io:
    stack: macos-ventura-xcode-15.1    # Platform stack
    machine_type: standard              # standard | performance

app:
  envs:
    - PROJECT_PATH: ./MyApp
    - BUILD_TYPE: Release

workflows:
  primary:
    envs:
      - SCHEME: MyApp
    steps:
      - git-clone@1.0.0:
          inputs:
            clone_depth: 1
      - xcodebuild@1.0.0:
          title: Build iOS App
          inputs:
            project_path: $PROJECT_PATH/MyApp.xcworkspace
            scheme: $SCHEME
          is_skippable: false
```

### Key Fields

| Field | Required | Description |
|---|---|---|
| `format_version` | Yes | Always `'1'` |
| `meta.cibuild.io.stack` | Yes | Build environment stack |
| `meta.cibuild.io.machine_type` | No | `standard` (default) or `performance` |
| `app.envs` | No | Global environment variables available to all workflows |
| `workflows.<name>.envs` | No | Workflow-scoped environment variables |
| `workflows.<name>.steps` | Yes | Ordered list of steps to execute |

### Step Fields

| Field | Required | Description |
|---|---|---|
| `title` | No | Display name for the step |
| `inputs` | No | Key-value map of step inputs |
| `is_skippable` | No | If `true`, step failure does not abort the pipeline |

## 3. Step Dependency Ordering

Steps produce outputs (environment variables, files) that downstream steps consume. The table below defines which steps must run before others. **Always respect this ordering when composing workflows.**

#### General Steps

| Step | Must run after | Reason |
|------|---------------|--------|
| `git-clone` | `activate-ssh-key` (if repo is private) | SSH key must be available before git operations |
| `cache-pull` | `git-clone` | Needs `CIBUILD_SOURCE_DIR` to resolve cache paths |
| `cache-push` | all build/test steps | Must run at end of workflow so caches include build outputs |
| `deploy-to-bitrise-io` | build/archive step that produces artifacts | Uploads `CIBUILD_IPA_PATH`, `CIBUILD_APK_PATH`, etc. |
| `slack` | all other steps (use `is_always_run: true`) | Notification sent after all work is done |
| `script` | depends on what the script does | No automatic dependencies |
| `file` | before the step that reads the written file | Writes secret files to disk at runtime |

#### iOS Steps

| Step | Must run after | Reason |
|------|---------------|--------|
| `cocoapods-install` | `git-clone` | Reads `Podfile` from repo |
| `carthage` | `git-clone` | Reads `Cartfile` from repo |
| `swiftlint` | `git-clone` | Reads Swift source files from repo |
| `certificate-installer` | — (no step deps) | Installs certs into macOS keychain; run before any signing step |
| `set-xcode-build-number` | `git-clone` | Modifies `Info.plist` in repo; run before `xcode-archive` |
| `set-ios-version` | `git-clone` | Modifies `Info.plist` in repo; run before `xcode-archive` |
| `xcodebuild` | `git-clone`, dependency step (`cocoapods-install` or `carthage` if used) | Needs source code and resolved dependencies |
| `xcode-test` | `git-clone`, dependency step if used | Runs `xcodebuild test` on source |
| `xcode-build-for-test` | `git-clone`, dependency step if used | Produces `.xctestrun` bundle |
| `xcode-test-without-building` | `xcode-build-for-test` | Consumes `CIBUILD_XCTESTRUN_PATH` and `CIBUILD_TEST_BUNDLE_DIR` |
| `xcode-build-for-simulator` | `git-clone`, dependency step if used | Produces `.app` for simulator |
| `xcode-archive` | `git-clone`, dependency step if used, `certificate-installer` (if manual signing), `set-xcode-build-number` (if versioning) | Produces `CIBUILD_IPA_PATH`, `CIBUILD_XCARCHIVE_PATH`, `CIBUILD_DSYM_PATH` |
| `export-xcarchive` | `xcode-archive` (or any step producing `.xcarchive`) | Consumes `CIBUILD_XCARCHIVE_PATH`, exports IPA |
| `ios-archive` | `xcodebuild` | Packages `.app` into IPA |
| `app-store-deploy` | `xcode-archive` | Uploads `CIBUILD_IPA_PATH` to App Store Connect |
| `ota-install` | `xcode-archive` or `deploy-to-bitrise-io` | Generates OTA manifest from IPA URL |
| `fastlane` | `git-clone`, dependency step if used | Runs a Fastlane lane that reads the project |

#### Android Steps

| Step | Must run after | Reason |
|------|---------------|--------|
| `set-java-version` | — (no step deps) | Sets `JAVA_HOME`; must run before any Gradle step |
| `install-missing-android-tools` | `git-clone` | Validates `ANDROID_HOME` and `gradlew`; run before Gradle steps |
| `change-android-versioncode-and-versionname` | `git-clone` | Modifies `build.gradle` in repo; run before `gradle-build` |
| `android-lint` | `git-clone`, `set-java-version` | Runs Gradle lint task |
| `detekt` | `git-clone`, `set-java-version` | Runs Gradle detekt task |
| `android-unit-test` | `git-clone`, `set-java-version` | Runs Gradle test task |
| `gradle-build` | `git-clone`, `set-java-version`, `change-android-versioncode-and-versionname` (if versioning), `install-missing-android-tools` (if needed) | Produces `CIBUILD_APK_PATH` or `CIBUILD_AAB_PATH` |
| `android-build` | `git-clone`, `set-java-version` | Same executor as `gradle-build` |
| `android-build-for-ui-testing` | `git-clone`, `set-java-version` | Produces app + test APKs for instrumented tests |
| `sign-apk` | `gradle-build` or `android-build` | Consumes `CIBUILD_APK_PATH`; produces `CIBUILD_SIGNED_APK_PATH` |
| `apk-info` | `gradle-build` or `android-build` | Reads APK metadata from build output |
| `google-play-deploy` | `gradle-build`, `sign-apk` (for release builds) | Uploads signed APK/AAB to Google Play |

#### Flutter Steps

| Step | Must run after | Reason |
|------|---------------|--------|
| `flutter-installer` | — (no step deps) | Installs Flutter SDK; must run before any Flutter step |
| `flutter-test` | `flutter-installer`, `git-clone` | Runs `flutter test` on project source |
| `flutter-build` | `flutter-installer`, `git-clone` | Runs `flutter build`; produces `CIBUILD_APK_PATH`, `CIBUILD_AAB_PATH`, `CIBUILD_APP_DIR_PATH` |

#### Release Steps

| Step | Must run after | Reason |
|------|---------------|--------|
| `generate-changelog` | `git-clone` | Reads git history to generate changelog; produces `CIBUILD_CHANGELOG` |
| `github-release` | `git-clone`, `generate-changelog` (if using changelog), build step (if attaching artifacts) | Creates GitHub release; consumes changelog and artifact paths |

#### Canonical Step Order

When composing a workflow, follow this general ordering:

1. `activate-ssh-key` (if private repo)
2. `git-clone`
3. `cache-pull`
4. Environment setup (`set-java-version`, `flutter-installer`)
5. Dependency installation (`cocoapods-install`, `carthage`, `install-missing-android-tools`)
6. Linting (`swiftlint`, `android-lint`, `detekt`)
7. Version management (`set-xcode-build-number`, `set-ios-version`, `change-android-versioncode-and-versionname`)
8. Code signing setup (`certificate-installer`, `file` for keystores)
9. Testing (`xcode-test`, `android-unit-test`, `flutter-test`)
10. Build / Archive (`xcode-archive`, `gradle-build`, `flutter-build`)
11. Signing (`sign-apk`)
12. Deployment (`app-store-deploy`, `google-play-deploy`, `github-release`)
13. Artifact upload (`deploy-to-bitrise-io`, `ota-install`)
14. `cache-push`
15. `slack` (with `is_always_run: true`)

## 4. Variable Syntax

| Syntax | Example | Description |
|---|---|---|
| `$VAR` | `$SCHEME` | Simple variable reference |
| `${VAR}` | `${SCHEME}` | Braced variable reference |
| `{{getenv "VAR"}}` | `{{getenv "SCHEME"}}` | Template function |
| `{{checksum "path"}}` | `{{checksum "Gemfile.lock"}}` | Content-based hash for cache keys |

## 5. Step Catalog

<!-- BEGIN STEP CATALOG -->

### activate-ssh-key@1.0.0
**Platform:** All

> Sets up an SSH key for git authentication. Reads the private key from the SSH_RSA_PRIVATE_KEY environment variable, writes it to disk, and configures the SSH client for common git hosting providers. Skipped in local mode.

**Agent Notes:** Sets up SSH key for git authentication. Reads SSH_RSA_PRIVATE_KEY env var, writes to ~/.ssh/, configures SSH client for github.com, gitlab.com, bitbucket.org. Skipped automatically in local mode. Use before git-clone if repo requires SSH auth.

**Requires:** commands: `ssh-agent`, `ssh-add`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| ssh_rsa_private_key | no | - | RSA private key content (reads SSH_RSA_PRIVATE_KEY env var if not set) |
| ssh_key_save_path | no | `~/.ssh/id_rsa` | Path where the SSH private key will be saved |

**Example:**
```yaml
- activate-ssh-key@1.0.0:
    inputs:
      ssh_rsa_private_key: "$SSH_RSA_PRIVATE_KEY"
```

---
### cache-pull@1.0.0
**Platform:** All

> Restores cached files from previous builds. Uses a cache key for content-based invalidation. Skipped in local mode.

**Agent Notes:** Restores cached files from previous builds. Skipped in local mode. Place early in workflow (after git-clone) to restore dependencies. Use the technology input for automatic configuration (cocoapods, carthage, spm, gradle, npm, yarn, dart). When technology is set, cache_key and cache_paths are ignored — the step auto-detects the lockfile and paths. For custom caching, set cache_key and cache_paths manually.

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| technology | no | - | Auto-configure cache for a technology: cocoapods, carthage, spm, gradle, npm, yarn, dart |
| cache_key | no | - | Key used to identify the cache entry (ignored when technology is set) |
| cache_paths | no | - | Paths to restore from cache (ignored when technology is set) |
| is_debug_mode | no | `false` | Enable verbose debug logging |

**Example:**
```yaml
- cache-pull@1.0.0:
    inputs:
      technology: cocoapods
```

---
### cache-push@1.0.0
**Platform:** All

> Saves files to cache for future builds. Supports glob patterns and path identifiers for derived data and build directories. Skipped in local mode.

**Agent Notes:** Saves files to cache for future builds. Skipped in local mode. Place at end of workflow after build succeeds. Use the technology input for automatic configuration (cocoapods, carthage, spm, gradle, npm, yarn, dart). When technology is set, cache_key and cache_paths are ignored. For custom caching, set cache_key and cache_paths manually. Supports path identifiers: "derived_data:pattern", "builds:pattern".

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| technology | no | - | Auto-configure cache for a technology: cocoapods, carthage, spm, gradle, npm, yarn, dart |
| cache_key | no | - | Key used to identify the cache entry (ignored when technology is set) |
| cache_paths | no | - | Paths to save to cache (ignored when technology is set, supports glob patterns) |
| is_debug_mode | no | `false` | Enable verbose debug logging |
| ignore_check_on_paths | no | `false` | Skip change detection and always push cache |

**Example:**
```yaml
- cache-push@1.0.0:
    inputs:
      technology: cocoapods
```

---
### deploy-to-bitrise-io@1.0.0
**Platform:** All

> Uploads build artifacts to S3 storage and exports an install page URL for downstream steps. Auto-detects artifacts directory if deploy_path is not set. Skipped in local mode.

**Agent Notes:** Uploads build artifacts to S3 storage. Auto-detects artifacts directory if deploy_path not set. Exports install page URL for downstream steps (e.g. slack notification). Skipped in local mode.

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| deploy_path | no | - | Path to the artifact file or directory to upload |
| notify_user_groups | no | - | User groups to notify (ignored) |

**Outputs:** `CIBUILD_PUBLIC_INSTALL_PAGE_URL`, `CI_INSTALL_PAGE_URL`

**Example:**
```yaml
- deploy-to-bitrise-io@1.0.0:
    inputs:
      deploy_path: "$CIBUILD_IPA_PATH"
```

---
### fastlane@1.0.0
**Platform:** All

> Runs a fastlane lane with Gemfile/Bundler detection. Automatically uses bundle exec when a Gemfile with the fastlane gem is detected. Optionally updates the fastlane gem before execution.

**Agent Notes:** Use after git-clone and any dependency installation steps. The lane input is required. If your Fastfile is not in the repo root, set work_dir to the parent directory of the fastlane directory.

**Requires:** steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| lane | yes | - | Fastlane lane to run |
| work_dir | no | - | Working directory (parent of fastlane directory) |
| update_fastlane | no | `true` | Update fastlane gem before run (true/false) |
| verbose_log | no | `no` | Enable verbose logging (yes/no) |
| enable_cache | no | `yes` | Enable collecting files to be included in build cache (yes/no) |

**Example:**
```yaml
- fastlane@1.0.0:
    inputs:
      lane: "ios release"
      work_dir: "./ios"
```

---
### file@1.0.0
**Platform:** All

> Writes a secret file (certificate, keystore, JSON key) to a target path at runtime. The file content is stored in .cibuild-secrets.json and base64-encoded into the generated script.

**Agent Notes:** Writes a secret file (certificate, keystore, JSON key) to a target path at runtime. Content is stored in .cibuild-secrets.json and base64-encoded into the generated script. Use for provisioning profiles, signing keys, service account files, etc.

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| target_path | yes | - | Destination path where the file will be written |
| var_name | yes | - | Environment variable name derived from the target filename |
| content | yes | - | File content (stored as a secret, base64-encoded at runtime) |

**Example:**
```yaml
- file@1.0.0:
    inputs:
      target_path: "$HOME/certs/distribution.p12"
      var_name: DISTRIBUTION_P12
      content: "$DISTRIBUTION_P12"
```

---
### flutter-build@1.0.0
**Platform:** All

> Builds a Flutter project for iOS, Android, or both. Supports APK, AAB, .app, and .xcarchive output types with configurable build params.

**Agent Notes:** Use after flutter-installer and git-clone. Set platform to ios, android, or both. For iOS, the build uses --no-codesign by default — use certificate-installer and xcode-archive for signed builds.

**Requires:** commands: `flutter` | steps: `flutter-installer`, `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_location | no | `.` | Root directory of the Flutter project |
| platform | no | `both` | Platform to build: ios | android | both |
| additional_build_params | no | - | Additional flutter build parameters |
| ios_output_type | no | `app` | iOS output type: app | archive |
| android_output_type | no | `apk` | Android output type: apk | appbundle |
| ios_additional_params | no | `--release` | Additional iOS build params |
| android_additional_params | no | `--release` | Additional Android build params |
| is_debug_mode | no | `false` | Enable debug mode for verbose logs (true/false) |

**Outputs:** `CIBUILD_APK_PATH`, `CIBUILD_AAB_PATH`, `CIBUILD_APP_DIR_PATH`

**Example:**
```yaml
- flutter-build@1.0.0:
    inputs:
      platform: "android"
      android_output_type: "appbundle"
```

---
### flutter-installer@1.0.0
**Platform:** All

> Installs or activates a Flutter SDK version. Clones the Flutter repo, switches to the requested channel or tag, runs flutter precache and flutter doctor.

**Agent Notes:** Use before flutter-build or flutter-test. Specify a channel (stable, beta, master) or a specific version tag (e.g. 3.16.0).

**Requires:** commands: `git`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| version | no | `stable` | Flutter SDK version or channel (stable, beta, master, or specific version) |
| installation_path | no | `$HOME/flutter` | Path to install the Flutter SDK |

**Outputs:** `CIBUILD_FLUTTER_SDK_PATH`

**Example:**
```yaml
- flutter-installer@1.0.0:
    inputs:
      version: "stable"
```

---
### flutter-test@1.0.0
**Platform:** All

> Runs flutter test with optional code coverage collection. Exports the coverage file path for downstream steps.

**Agent Notes:** Use after flutter-installer and git-clone. Enable coverage with generate_code_coverage_files to produce lcov.info.

**Requires:** commands: `flutter` | steps: `flutter-installer`, `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_location | no | `.` | Root directory of the Flutter project |
| additional_params | no | - | Additional flutter test parameters |
| generate_code_coverage_files | no | `false` | Enable coverage collection (true/false) |

**Outputs:** `CIBUILD_FLUTTER_COVERAGE_PATH`

**Example:**
```yaml
- flutter-test@1.0.0:
    inputs:
      generate_code_coverage_files: "true"
```

---
### generate-changelog@1.0.0
**Platform:** All

> Generates a changelog from git commit history since the last tag. Ignores merge commits. Falls back to all commits if no tags exist.

**Agent Notes:** Use after git-clone. The changelog is written to a file and exported as CIBUILD_CHANGELOG. Useful before github-release or deploy steps.

**Requires:** commands: `git` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| changelog_path | no | `./CHANGELOG.md` | Path to write the changelog file |
| working_dir | no | `.` | Working directory containing the git repo |

**Outputs:** `CIBUILD_CHANGELOG`

**Example:**
```yaml
- generate-changelog@1.0.0:
    inputs:
      changelog_path: "./artifacts/CHANGELOG.md"
```

---
### git-clone@1.0.0
**Platform:** All

> Detects the local git repository root and exports commit metadata as environment variables. Does not perform an actual clone — assumes the source code is already present on disk.

**Agent Notes:** Does NOT clone — assumes repo already present locally. Detects git root and exports commit metadata. Should always be the first step in any workflow. All subsequent steps depend on CIBUILD_SOURCE_DIR.

**Requires:** commands: `git`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| repository | no | `$GIT_REPOSITORY_URL` | Git repository URL (informational; no clone is performed) |
| branch | no | `$GIT_BRANCH or main` | Branch to check out or verify |
| clone_depth | no | `0` | Shallow clone depth (0 = full history) |
| clone_into_dir | no | `.` | Directory that contains the repository |

**Outputs:** `CIBUILD_SOURCE_DIR`, `GIT_CLONE_COMMIT_HASH`, `CIBUILD_GIT_COMMIT`, `GIT_CLONE_COMMIT_AUTHOR_NAME`, `GIT_CLONE_COMMIT_AUTHOR_EMAIL`, `GIT_CLONE_COMMIT_COMMITER_NAME`, `GIT_CLONE_COMMIT_COMMITER_EMAIL`, `GIT_CLONE_COMMIT_MESSAGE_SUBJECT`, `GIT_CLONE_COMMIT_MESSAGE_BODY`

**Example:**
```yaml
- git-clone@1.0.0:
    inputs:
      branch: main
      clone_into_dir: "."
```

---
### github-release@1.0.0
**Platform:** All

> Creates a GitHub release with optional artifact attachments using the gh CLI. Supports draft, pre-release, and auto-generated release notes.

**Agent Notes:** Use after generate-changelog or at the end of a release workflow. Requires GITHUB_TOKEN environment variable or api_token input. Skipped in local mode.

**Requires:** commands: `gh` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| repository_url | no | - | GitHub repository (owner/repo). Auto-detected if not set. |
| tag | yes | - | Release tag name |
| name | no | - | Release title (defaults to tag) |
| body | no | - | Release body / notes |
| changelog_path | no | - | Path to changelog file to use as body (alternative to body) |
| draft | no | `false` | Create as draft release (true/false) |
| pre_release | no | `false` | Mark as pre-release (true/false) |
| files_to_upload | no | - | File paths to attach as release assets (newline-separated) |
| api_token | no | `$GITHUB_TOKEN` | GitHub API token |

**Outputs:** `CIBUILD_RELEASE_URL`

**Example:**
```yaml
- github-release@1.0.0:
    inputs:
      tag: "v1.0.0"
      name: "Release 1.0.0"
      changelog_path: "./CHANGELOG.md"
      files_to_upload: |
        ./artifacts/app-release.apk
        ./artifacts/app-release.ipa
```

---
### script@1.0.0
**Platform:** All

> Executes an arbitrary script using the specified runner. Supports bash, python, ruby, node, or any interpreter available on the system.

**Agent Notes:** Execute arbitrary bash/python/ruby/node scripts. Use for custom build logic not covered by other steps. Set runner_bin to python/ruby/node for non-bash scripts.

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| content | yes | - | The script content to execute |
| working_dir | no | - | Working directory for script execution |
| runner_bin | no | `bash` | Interpreter binary to run the script |

**Example:**
```yaml
- script@1.0.0:
    inputs:
      content: |
        echo "Hello from CI"
        npm install
        npm test
```

---
### slack@1.0.0
**Platform:** All

> Sends a Slack notification via an incoming webhook. Supports custom message text, channel override, and color-coded attachments. Skipped in local mode.

**Agent Notes:** Sends Slack notification via webhook. Skipped in local mode. Typically the last step in a workflow (often with is_always_run: true). webhook_url and channel can be set via SLACK_WEBHOOK_URL and SLACK_CHANNEL env vars/secrets.

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| webhook_url | yes | - | Slack incoming webhook URL |
| channel | no | - | Slack channel to post to (overrides webhook default) |
| text | no | - | Plain text message content |
| message | no | - | Rich message content (attachment text) |
| color | no | `good` | Attachment sidebar color (good, warning, danger, or hex) |

**Example:**
```yaml
- slack@1.0.0:
    is_always_run: true
    inputs:
      webhook_url: "$SLACK_WEBHOOK_URL"
      channel: "#builds"
      text: "Build finished: $CIBUILD_BUILD_STATUS"
      color: "good"
```

---
### app-store-deploy@1.0.0
**Platform:** iOS

> Uploads an IPA to App Store Connect or TestFlight using fastlane deliver. Requires Apple API key credentials for authentication. Automatically skipped when running in local mode.

**Agent Notes:** Uploads IPA to App Store Connect / TestFlight using fastlane deliver. Requires Apple API key credentials (APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, APPLE_API_KEY_PATH as secrets). Use after xcode-archive. Skipped automatically in local mode since App Store uploads are not meaningful outside CI.

**Requires:** commands: `fastlane` | steps: `xcode-archive`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| ipa_path | no | `$CIBUILD_IPA_PATH` | Path to the IPA file to upload |
| api_key_id | no | - | App Store Connect API Key ID |
| api_issuer | no | - | App Store Connect API Issuer ID |
| api_key_path | no | - | Path to the .p8 private key file for App Store Connect API |
| team_id | no | - | Apple Developer team ID |
| app_id | no | - | App Store Connect app ID |
| bundle_id | no | - | App bundle identifier (e.g. com.example.MyApp) |
| platform | no | `ios` | Platform to upload for (ios, appletvos, osx) |
| skip_metadata | no | `yes` | Skip uploading metadata (yes/no) |
| skip_screenshots | no | `yes` | Skip uploading screenshots (yes/no) |
| submit_for_review | no | `no` | Automatically submit the build for review after upload (yes/no) |
| options | no | - | Additional options passed to fastlane deliver |
| verbose_log | no | `no` | Enable verbose logging for fastlane (yes/no) |

**Example:**
```yaml
- app-store-deploy@1.0.0:
    inputs:
      ipa_path: build/ipa/MyApp.ipa
      api_key_id: "ABC123"
      api_issuer: "def456-gh78-ij90"
      api_key_path: ./AuthKey.p8
      submit_for_review: "no"
```

---
### carthage@1.0.0
**Platform:** iOS

> Runs a Carthage command (bootstrap, update, or build) to download and build iOS/macOS dependencies. Supports GitHub access token to avoid rate limits and additional Carthage options.

**Agent Notes:** Use for managing Carthage dependencies. Place after git-clone. Prefer bootstrap over update for reproducible builds and caching. Pass --platform ios via carthage_options to speed up builds.

**Requires:** commands: `carthage` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| carthage_command | no | `bootstrap` | Carthage command to run (bootstrap, update, or build) |
| carthage_options | no | - | Additional options for the carthage command (e.g. --platform ios) |
| github_access_token | no | - | GitHub personal access token to avoid rate limiting |
| verbose | no | `false` | Enable verbose Carthage logging |

**Example:**
```yaml
- carthage@1.0.0:
    inputs:
      carthage_command: bootstrap
      carthage_options: "--platform ios --use-xcframeworks"
```

---
### certificate-installer@1.0.0
**Platform:** iOS

> Installs Apple code signing certificates (.p12) and provisioning profiles into the macOS keychain for Xcode builds. Supports multiple certificates and profiles via pipe-separated URLs. Handles both remote URLs and local file:// paths.

**Agent Notes:** Use before xcode-archive or any step that requires code signing. Maps from Bitrise certificate-and-profile-installer step. Requires certificate_url and keychain_password at minimum. Provisioning profiles are installed to ~/Library/MobileDevice/Provisioning Profiles/.

**Requires:** commands: `security`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| certificate_url | no | `$CIBUILD_CERTIFICATE_URL` | URL(s) to .p12 certificate files (pipe-separated). Supports file:// |
| certificate_passphrase | no | `$CIBUILD_CERTIFICATE_PASSPHRASE` | Certificate passphrase(s), pipe-separated to match certificate_url count |
| provisioning_profile_url | no | `$CIBUILD_PROVISION_URL` | URL(s) to provisioning profile files (pipe-separated). Supports file:// |
| keychain_path | no | `$HOME/Library/Keychains/login.keychain` | Path to the keychain to use |
| keychain_password | no | `$CIBUILD_KEYCHAIN_PASSWORD` | Password for the keychain |
| verbose | no | `false` | Enable verbose logging |

**Example:**
```yaml
- certificate-installer@1.0.0:
    inputs:
      certificate_url: "$CIBUILD_CERTIFICATE_URL"
      certificate_passphrase: "$CIBUILD_CERTIFICATE_PASSPHRASE"
      provisioning_profile_url: "$CIBUILD_PROVISION_URL"
      keychain_password: "$CIBUILD_KEYCHAIN_PASSWORD"
```

---
### cocoapods-install@1.0.0
**Platform:** iOS

> Runs CocoaPods pod install or pod update to install iOS/macOS dependencies. Auto-detects Gemfile and uses bundle exec when cocoapods gem is present. Determines working directory from source_root_path or CIBUILD_SOURCE_DIR.

**Agent Notes:** Use for installing CocoaPods dependencies. Place after git-clone. If the project uses a Gemfile with cocoapods, the step automatically runs bundle exec pod install. Use command: update to update all pods.

**Requires:** commands: `pod` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| command | no | `install` | CocoaPods command to run (install or update) |
| source_root_path | no | `$CIBUILD_SOURCE_DIR` | Directory containing the Podfile |
| podfile_path | no | - | Explicit path to Podfile (overrides source_root_path) |
| verbose | no | `false` | Enable verbose CocoaPods logging |

**Example:**
```yaml
- cocoapods-install@1.0.0:
    inputs:
      command: install
      source_root_path: "."
```

---
### export-xcarchive@1.0.0
**Platform:** iOS

> Exports an IPA from an existing .xcarchive file using xcodebuild -exportArchive. Supports development, app-store, ad-hoc, and enterprise distribution methods.

**Agent Notes:** Use after xcode-archive or any step that produces a .xcarchive. Allows creating multiple IPA exports from the same archive with different distribution methods. Automatic code signing is not supported — use certificate-installer before this step.

**Requires:** commands: `xcodebuild`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| archive_path | yes | `$CIBUILD_XCARCHIVE_PATH` | Path to .xcarchive file |
| product | no | `app` | Product to export: app | app-clip |
| distribution_method | no | `development` | Export method: development | app-store | ad-hoc | enterprise |
| compile_bitcode | no | `yes` | Recompile from bitcode for non-App Store (yes/no) |
| upload_bitcode | no | `yes` | Include bitcode for App Store (yes/no) |
| export_options_plist_content | no | - | Custom ExportOptions.plist content (overrides generated plist) |
| verbose_log | no | `no` | Enable verbose logging (yes/no) |

**Outputs:** `CIBUILD_IPA_PATH`, `CIBUILD_DSYM_PATH`

**Example:**
```yaml
- export-xcarchive@1.0.0:
    inputs:
      archive_path: "$CIBUILD_XCARCHIVE_PATH"
      distribution_method: "ad-hoc"
```

---
### ios-archive@1.0.0
**Platform:** iOS

> Creates an IPA file from a .app bundle by packaging it into the standard Payload/ directory structure and zipping the result. This is a lightweight archiving step that does not invoke xcodebuild archive or handle code signing and export options.

**Agent Notes:** Creates an IPA from a .app bundle by zipping into Payload/ structure. Use after the xcodebuild step that produces a .app in the build products directory. For the full archive+export flow with code signing and ExportOptions.plist generation, use xcode-archive instead.

**Requires:** commands: `zip`, `xcodebuild` | steps: `xcodebuild`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| app_path | yes | - | Path to the .app bundle to package into an IPA |
| output_path | no | `artifacts` | Directory where the IPA file will be written |
| output_name | no | - | Custom file name for the generated IPA (without extension) |

**Example:**
```yaml
- ios-archive@1.0.0:
    inputs:
      app_path: build/Build/Products/Release-iphoneos/MyApp.app
      output_path: artifacts
```

---
### ota-install@1.0.0
**Platform:** iOS

> Generates a manifest.plist and an optional QR code for over-the-air (OTA) iOS app installation via the itms-services:// protocol. The IPA and manifest must be hosted at user-provided HTTPS URLs.

**Agent Notes:** Generates manifest.plist and QR code for OTA distribution via itms-services://. The IPA and manifest must be hosted at user-provided HTTPS URLs. Use after xcode-archive. Optionally renders a QR code in the terminal if qrencode is installed. The generated manifest.plist references the ipa_url so the device can download and install the build directly.

**Requires:** steps: `xcode-archive`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| ipa_url | yes | - | Public HTTPS URL where the IPA will be hosted |
| manifest_url | no | - | Public HTTPS URL where the manifest.plist will be hosted; derived from ipa_url if omitted |
| bundle_id | yes | - | CFBundleIdentifier of the app (e.g. com.example.MyApp) |
| bundle_version | yes | - | CFBundleShortVersionString of the app (e.g. 1.0.0) |
| title | yes | - | Display title shown during OTA installation |
| ipa_path | no | - | Local path to the IPA file (used for metadata extraction) |
| output_dir | no | `.ci/artifacts` | Directory where manifest.plist and QR code image are written |

**Outputs:** `CIBUILD_PUBLIC_INSTALL_PAGE_QR_CODE_IMAGE_URL`

**Example:**
```yaml
- ota-install@1.0.0:
    inputs:
      ipa_url: "https://builds.example.com/MyApp-1.0.0.ipa"
      bundle_id: com.example.MyApp
      bundle_version: "1.0.0"
      title: "MyApp Beta"
```

---
### set-ios-version@1.0.0
**Platform:** iOS

> Directly edits an Info.plist file to set CFBundleVersion and/or CFBundleShortVersionString using PlistBuddy. Use when you need precise control over which Info.plist to modify.

**Agent Notes:** Use when you need to directly modify a specific Info.plist file. For project-level versioning via agvtool, prefer set-xcode-build-number. Requires info_plist_file path.

**Requires:** commands: `/usr/libexec/PlistBuddy` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| info_plist_file | yes | - | Path to the Info.plist file |
| bundle_version | no | - | CFBundleVersion (build number) to set |
| bundle_version_short | no | - | CFBundleShortVersionString (marketing version) to set |

**Outputs:** `CIBUILD_APP_VERSION`, `CIBUILD_APP_BUILD`

**Example:**
```yaml
- set-ios-version@1.0.0:
    inputs:
      info_plist_file: "MyApp/Info.plist"
      bundle_version: "42"
      bundle_version_short: "1.2.0"
```

---
### set-xcode-build-number@1.0.0
**Platform:** iOS

> Updates the Xcode project build number (CFBundleVersion or CURRENT_PROJECT_VERSION) and optionally the marketing version (CFBundleShortVersionString). Uses agvtool with PlistBuddy fallback.

**Agent Notes:** Use before xcode-archive or xcodebuild to set the build number. Supports build_version_offset for auto-incrementing. Defaults to using $CIBUILD_BUILD_NUMBER if build_version is not set.

**Requires:** commands: `xcodebuild` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_path | no | - | Path to .xcodeproj or .xcworkspace |
| scheme | no | - | Xcode scheme name |
| target | no | - | Xcode target name (optional) |
| build_version | no | `$CIBUILD_BUILD_NUMBER` | Build number to set (CFBundleVersion) |
| build_version_offset | no | - | Offset added to build_version |
| build_short_version_string | no | - | Marketing version (CFBundleShortVersionString) |

**Outputs:** `CIBUILD_BUNDLE_VERSION`

**Example:**
```yaml
- set-xcode-build-number@1.0.0:
    inputs:
      build_version: "$CIBUILD_BUILD_NUMBER"
      build_short_version_string: "2.1.0"
```

---
### swiftlint@1.0.0
**Platform:** iOS

> Runs SwiftLint on the project with configurable reporter, strict mode, and support for linting only changed files.

**Agent Notes:** Use after git-clone to lint Swift source files. Requires SwiftLint installed (brew install swiftlint). Supports .swiftlint.yml config.

**Requires:** commands: `swiftlint` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| linting_path | no | `.` | Path where SwiftLint should lint |
| lint_range | no | `all` | Range of linting: all | changed |
| lint_config_file | no | - | Path to .swiftlint.yml config |
| reporter | no | `xcode` | Reporter style (xcode, json, html, junit, csv, etc.) |
| strict | no | `no` | Use strict mode — warnings become errors (yes/no) |
| quiet | no | `no` | Suppress status logs (yes/no) |

**Outputs:** `CIBUILD_SWIFTLINT_REPORT`, `CIBUILD_SWIFTLINT_REPORT_PATH`

**Example:**
```yaml
- swiftlint@1.0.0:
    inputs:
      linting_path: "./Sources"
      reporter: "json"
      strict: "yes"
```

---
### xcode-archive@1.0.0
**Platform:** iOS

> Runs the full xcodebuild archive and export flow, producing a signed IPA, an xcarchive, and dSYM files. Handles ExportOptions.plist generation, code-signing configuration, and bitcode settings automatically.

**Agent Notes:** Full archive+export flow. Use after git-clone and dependency installation steps (cocoapods-install, spm-resolve, etc.). For App Store distribution, set distribution_method to app-store. The step auto-generates ExportOptions.plist unless export_options_plist_content is provided explicitly. Follow with app-store-deploy for App Store / TestFlight uploads, or ota-install for ad-hoc OTA distribution.

**Requires:** commands: `xcodebuild` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_path | yes | - | Path to the .xcodeproj or .xcworkspace file |
| scheme | yes | - | Xcode scheme to archive |
| configuration | no | `Release` | Build configuration (e.g. Debug, Release) |
| distribution_method | no | `development` | Export distribution method (development, ad-hoc, app-store, enterprise) |
| perform_clean_action | no | `no` | Whether to run xcodebuild clean before archiving |
| automatic_code_signing | no | `off` | Enable or disable automatic code signing (on/off) |
| compile_bitcode | no | `yes` | Whether to compile bitcode (yes/no) |
| upload_bitcode | no | `yes` | Whether to include bitcode in the exported archive (yes/no) |
| xcconfig_content | no | `COMPILER_INDEX_STORE_ENABLE = NO` | Extra xcconfig settings applied during archive |
| xcodebuild_options | no | - | Additional flags passed directly to xcodebuild |
| export_options_plist_content | no | - | Custom ExportOptions.plist XML content; overrides auto-generation |
| output_dir | no | `build/ipa` | Directory where the IPA, xcarchive, and dSYM are written |
| artifact_name | no | - | Custom base name for the exported artifacts |

**Outputs:** `CIBUILD_IPA_PATH`, `CIBUILD_XCARCHIVE_PATH`, `CIBUILD_DSYM_PATH`

**Example:**
```yaml
- xcode-archive@1.0.0:
    inputs:
      project_path: MyApp.xcworkspace
      scheme: MyApp
      distribution_method: app-store
      automatic_code_signing: "on"
      output_dir: build/ipa
```

---
### xcode-build-for-simulator@1.0.0
**Platform:** iOS

> Builds an iOS/tvOS/watchOS app for the simulator using xcodebuild. Produces a .app bundle that can be deployed to a simulator or uploaded to services like Appetize.io for browser-based testing.

**Agent Notes:** Use when you need a simulator .app build (not an IPA). Place after git-clone and dependency steps. Code signing is disabled by default (CODE_SIGNING_ALLOWED=NO). For device builds, use xcodebuild instead.

**Requires:** commands: `xcodebuild` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_path | yes | - | Path to .xcodeproj or .xcworkspace |
| scheme | yes | - | Xcode scheme name |
| configuration | no | - | Build configuration (e.g. Debug) |
| destination | no | `generic/platform=iOS Simulator` | Simulator destination specifier |
| perform_clean_action | no | `no` | Run clean before build (yes/no) |
| xcconfig_content | no | `CODE_SIGNING_ALLOWED=NO` | Extra xcconfig settings (default disables code signing) |
| xcodebuild_options | no | - | Additional xcodebuild flags |
| output_dir | no | `build` | Directory for build artifacts |

**Outputs:** `CIBUILD_APP_DIR_PATH`

**Example:**
```yaml
- xcode-build-for-simulator@1.0.0:
    inputs:
      project_path: MyApp.xcworkspace
      scheme: MyApp
      destination: "generic/platform=iOS Simulator"
```

---
### xcode-build-for-test@1.0.0
**Platform:** iOS

> Runs xcodebuild build-for-testing to compile the app and its tests without executing them. Produces an .xctestrun file that can be used by xcode-test-without-building to run tests separately, e.g. on a real device or via a third-party testing service.

**Agent Notes:** Use when you want to build tests separately from running them. Produces an .xctestrun file consumed by xcode-test-without-building. Place after git-clone and dependency steps. Set destination to generic/platform=iOS Simulator for simulator tests or generic/platform=iOS for device tests.

**Requires:** commands: `xcodebuild` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_path | yes | - | Path to .xcodeproj or .xcworkspace |
| scheme | yes | - | Xcode scheme name |
| configuration | no | `Debug` | Build configuration (e.g. Debug) |
| destination | no | `generic/platform=iOS Simulator` | Xcodebuild destination specifier |
| test_plan | no | - | Test Plan to build for (leave empty for all) |
| xcconfig_content | no | - | Extra xcconfig settings applied during the build |
| xcodebuild_options | no | - | Additional xcodebuild flags |
| output_dir | no | `build` | Directory for build artifacts |

**Outputs:** `CIBUILD_TEST_BUNDLE_PATH`, `CIBUILD_XCTESTRUN_FILE_PATH`

**Example:**
```yaml
- xcode-build-for-test@1.0.0:
    inputs:
      project_path: MyApp.xcworkspace
      scheme: MyApp
      configuration: Debug
      destination: "generic/platform=iOS Simulator"
```

---
### xcode-test@1.0.0
**Platform:** iOS

> Runs xcodebuild test to execute unit tests and UI tests for an Xcode project or workspace. Supports test plans, code coverage collection, and custom simulator destinations.

**Agent Notes:** Use for running unit and UI tests. Runs xcodebuild test. For simulator testing, specify destination with simulator details (platform, device name, OS version). Place after git-clone and any dependency-installation steps. This step does not produce build artifacts; use xcodebuild or xcode-archive for that purpose.

**Requires:** commands: `xcodebuild` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_path | yes | - | Path to the .xcodeproj or .xcworkspace file |
| scheme | yes | - | Xcode scheme whose tests should run |
| destination | no | `platform=iOS Simulator,name=iPhone 14,OS=latest` | Xcodebuild destination specifier for the test run |
| test_plan | no | - | Name of the Xcode test plan to execute |
| is_code_coverage_enabled | no | `false` | Whether to collect code coverage data during the test run |

**Example:**
```yaml
- xcode-test@1.0.0:
    inputs:
      project_path: MyApp.xcworkspace
      scheme: MyAppTests
      destination: "platform=iOS Simulator,name=iPhone 14,OS=latest"
      is_code_coverage_enabled: "true"
```

---
### xcode-test-without-building@1.0.0
**Platform:** iOS

> Runs xcodebuild test-without-building to execute pre-compiled tests from an .xctestrun file. Use after xcode-build-for-test to split build and test phases, enabling parallel test execution or testing on real devices.

**Agent Notes:** Use after xcode-build-for-test. Requires the .xctestrun file path (auto-populated from CIBUILD_XCTESTRUN_FILE_PATH). Supports test filtering via only_testing/skip_testing and test repetition modes.

**Requires:** commands: `xcodebuild` | steps: `xcode-build-for-test`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| xctestrun | no | `$CIBUILD_XCTESTRUN_FILE_PATH` | Path to .xctestrun file (defaults to $CIBUILD_XCTESTRUN_FILE_PATH) |
| destination | no | `platform=iOS Simulator,name=iPhone 15,OS=latest` | Device destination specifier |
| only_testing | no | - | Test identifiers to run (newline-separated) |
| skip_testing | no | - | Test identifiers to skip (newline-separated) |
| test_repetition_mode | no | `none` | Repeat mode: none | until_failure | retry_on_failure | up_until_maximum_repetitions |
| maximum_test_repetitions | no | `3` | Max repetitions when using a test repetition mode |
| xcodebuild_options | no | - | Additional xcodebuild flags |

**Outputs:** `CIBUILD_XCRESULT_PATH`

**Example:**
```yaml
- xcode-test-without-building@1.0.0:
    inputs:
      xctestrun: "$CIBUILD_XCTESTRUN_FILE_PATH"
      destination: "platform=iOS Simulator,name=iPhone 15,OS=latest"
```

---
### xcodebuild@1.0.0
**Platform:** iOS

> Runs xcodebuild to compile an Xcode project or workspace without producing an archive or exportable artifact. Useful for verifying that the project builds successfully, running incremental builds during development, or as a prerequisite step before ios-archive.

**Agent Notes:** Use for building without archiving. For creating a distributable IPA, use xcode-archive instead. Place after git-clone and any dependency-installation steps (e.g. cocoapods-install, spm-resolve). The step invokes xcodebuild build, so it does not produce an .xcarchive or IPA.

**Requires:** commands: `xcodebuild` | steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_path | yes | - | Path to the .xcodeproj or .xcworkspace file |
| scheme | yes | - | Xcode scheme to build |
| configuration | no | `Release` | Build configuration (e.g. Debug, Release) |
| destination | no | `generic/platform=iOS` | Xcodebuild destination specifier |
| xcconfig_content | no | - | Extra xccconfig settings applied during the build |
| output_dir | no | `build` | Directory where derived data / build products are written |
| is_clean_build | no | `false` | Whether to run a clean build (xcodebuild clean build) |

**Example:**
```yaml
- xcodebuild@1.0.0:
    inputs:
      project_path: MyApp.xcworkspace
      scheme: MyApp
      configuration: Release
      destination: "generic/platform=iOS"
```

---
### android-build@1.0.0
**Platform:** Android

> Alternative Android build step that accepts higher-level inputs (variant, module, build_type) instead of a direct gradle_task. Uses the same executor as gradle-build. Requires JAVA_HOME to be set.

**Agent Notes:** Alternative to gradle-build that accepts higher-level inputs (variant, module, build_type) instead of direct gradle_task. Same executor as gradle-build under the hood.

**Requires:** steps: `git-clone`, `set-java-version`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_location | no | `.` | Root directory of the Android project |
| variant | no | `release` | Build variant (e.g. release, debug) |
| module | no | `app` | Gradle module to build |
| build_type | no | `apk` | Output type: apk or aab |
| gradle_task | no | - | Custom Gradle task (overrides variant/build_type) |
| gradle_options | no | - | Additional Gradle command-line options |

**Outputs:** `CIBUILD_APK_PATH`, `CIBUILD_AAB_PATH`

**Example:**
```yaml
- android-build@1.0.0:
    inputs:
      project_location: "."
      variant: "release"
      module: "app"
      build_type: "apk"
```

---
### android-build-for-ui-testing@1.0.0
**Platform:** Android

> Builds both the app APK and the test APK for Android instrumented (UI) tests. Runs assembleVariant and assembleVariantAndroidTest gradle tasks.

**Agent Notes:** Use when you need both an app APK and a test APK for running instrumented tests (e.g. via Firebase Test Lab or a connected device). Place after set-java-version and git-clone.

**Requires:** steps: `git-clone`, `set-java-version`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_location | no | `.` | Root directory of the Android project |
| module | no | `app` | Module to build (e.g. app) |
| variant | no | `Debug` | Build variant (e.g. Debug, Release) |
| arguments | no | - | Additional Gradle arguments |

**Outputs:** `CIBUILD_APK_PATH`, `CIBUILD_TEST_APK_PATH`

**Example:**
```yaml
- android-build-for-ui-testing@1.0.0:
    inputs:
      module: app
      variant: Debug
```

---
### android-lint@1.0.0
**Platform:** Android

> Runs Android lint checks via Gradle. Useful for catching code quality issues, potential bugs, and style violations in Android projects.

**Agent Notes:** Runs Android lint checks via Gradle. Add to PR workflows for code quality.

**Requires:** commands: `java` | steps: `git-clone`, `set-java-version`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_location | no | `.` | Root directory of the Android project |
| module | no | `app` | Gradle module to lint |
| variant | no | `debug` | Build variant to lint (e.g. debug, release) |

**Example:**
```yaml
- android-lint@1.0.0:
    inputs:
      project_location: "."
      module: "app"
      variant: "debug"
```

---
### android-unit-test@1.0.0
**Platform:** Android

> Runs Android unit tests via Gradle. Supports filtering to run specific test classes or methods using Gradle test filter patterns.

**Agent Notes:** Runs Android unit tests via Gradle. Add to PR and primary workflows. test_filter accepts Gradle test filter pattern (e.g. "com.example.MyTest").

**Requires:** commands: `java` | steps: `git-clone`, `set-java-version`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_location | no | `.` | Root directory of the Android project |
| module | no | `app` | Gradle module to test |
| variant | no | `debug` | Build variant to test (e.g. debug, release) |
| test_filter | no | - | Gradle test filter pattern (e.g. com.example.MyTest) |

**Example:**
```yaml
- android-unit-test@1.0.0:
    inputs:
      project_location: "."
      module: "app"
      variant: "debug"
      test_filter: "com.example.MyTest"
```

---
### apk-info@1.0.0
**Platform:** Android

> Extracts APK metadata using aapt/aapt2. Exports package name, version code, version name, min SDK, and target SDK as environment variables. Auto-detects APK in build/outputs/apk/ if apk_path is not specified.

**Agent Notes:** Extracts APK metadata using aapt/aapt2. Auto-detects APK in build/outputs/apk/ if apk_path not specified. Use after gradle-build.

**Requires:** commands: `aapt or aapt2` | steps: `gradle-build`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| apk_path | no | - | Path to the APK file (auto-detected if not specified) |

**Outputs:** `APK_FILE_PATH`, `APK_PACKAGE_NAME`, `APK_VERSION_CODE`, `APK_VERSION_NAME`, `APK_MIN_SDK`, `APK_TARGET_SDK`

**Example:**
```yaml
- apk-info@1.0.0:
    inputs:
      apk_path: "./app/build/outputs/apk/release/app-release.apk"
```

---
### change-android-versioncode-and-versionname@1.0.0
**Platform:** Android

> Updates versionCode and versionName in build.gradle via sed before build. Supports Kotlin DSL (.kts) auto-detection. Can increment versionCode from the current value using version_code_offset.

**Agent Notes:** Updates versionCode/versionName in build.gradle via sed before build. Supports Kotlin DSL (.kts) auto-detection. version_code_offset can increment from current value. Place before gradle-build.

**Requires:** steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| build_gradle_path | yes | `$PROJECT_LOCATION/app/build.gradle` | Path to the build.gradle file |
| new_version_name | no | - | New version name to set (e.g. 1.2.3) |
| new_version_code | no | - | New version code to set (e.g. 42) |
| version_code_offset | no | - | Offset to add to the current version code |

**Outputs:** `ANDROID_VERSION_CODE`, `ANDROID_VERSION_NAME`

**Example:**
```yaml
- change-android-versioncode-and-versionname@1.0.0:
    inputs:
      build_gradle_path: "./app/build.gradle"
      new_version_name: "1.2.3"
      new_version_code: "42"
```

---
### detekt@1.0.0
**Platform:** Android

> Runs detekt Kotlin static analysis via the Gradle detekt task. Supports module-level and project-level analysis with additional Gradle arguments.

**Agent Notes:** Use after git-clone and set-java-version. Requires the detekt Gradle plugin configured in the project. Maps from Bitrise android-detekt step.

**Requires:** steps: `git-clone`, `set-java-version`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_location | no | `.` | Root directory of the Android project |
| module | no | - | Module to run detekt on (e.g. app) |
| report_path_pattern | no | `*/build/reports/detekt/detekt*.html` | Glob pattern to find report files |
| arguments | no | - | Additional Gradle arguments |

**Example:**
```yaml
- detekt@1.0.0:
    inputs:
      project_location: "."
      module: "app"
      arguments: "--stacktrace"
```

---
### google-play-deploy@1.0.0
**Platform:** Android

> Uploads APK/AAB to Google Play via fastlane supply. Requires a Google Play service account JSON key as a secret. Auto-detects AAB vs APK format. Skipped in local mode.

**Agent Notes:** Uploads APK/AAB to Google Play via fastlane supply. Requires service account JSON as secret. Auto-detects AAB vs APK. Use after gradle-build. Skipped in local mode.

**Requires:** commands: `fastlane` | steps: `gradle-build`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| artifact_type | no | `apk` | Artifact format to upload: 'apk' or 'aab' (Android App Bundle). Affects which gradle task is used (assemble vs bundle). |
| service_account_json_var | no | `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Env var name containing the service account JSON |
| service_account_json_key_path | no | - | Path to the service account JSON key file |
| package_name | yes | - | Android application package name (e.g. com.example.app) |
| app_path | no | - | Path to the APK or AAB file to upload |
| track | no | `alpha` | Google Play release track (e.g. alpha, beta, production) |
| user_fraction | no | - | Fraction of users for staged rollout (e.g. 0.1) |
| status | no | - | Release status (e.g. completed, draft, halted) |
| update_priority | no | `0` | In-app update priority (0-5) |
| whatsnews_dir | no | - | Path to directory with release notes (changelogs) |
| mapping_file | no | `$CIBUILD_MAPPING_PATH` | Path to the ProGuard/R8 mapping file |
| retry_without_sending_to_review | no | `false` | Retry upload without sending to review on failure |
| ack_bundle_installation_warning | no | `false` | Acknowledge AAB installation size warning |
| dry_run | no | `false` | Validate upload without actually publishing |
| verbose_log | no | `false` | Enable verbose fastlane logging |

**Example:**
```yaml
- google-play-deploy@1.0.0:
    inputs:
      package_name: "com.example.myapp"
      track: "alpha"
      service_account_json_var: "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"
```

---
### gradle-build@1.0.0
**Platform:** Android

> Builds an Android project with Gradle. Auto-detects and makes gradlew executable. Locates and exports APK/AAB paths after a successful build. Requires JAVA_HOME to be set.

**Agent Notes:** Builds Android project with Gradle. Auto-detects and makes gradlew executable. Locates and exports APK/AAB paths after build. Use set-java-version before this step.

**Requires:** steps: `git-clone`, `set-java-version`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| project_location | no | `.` | Root directory of the Android project |
| build_type | no | `Release` | Build type (e.g. Release, Debug) |
| gradle_task | no | `assembleRelease` | Gradle task to execute |
| gradle_options | no | - | Additional Gradle command-line options |

**Outputs:** `CIBUILD_APK_PATH`, `CIBUILD_AAB_PATH`

**Example:**
```yaml
- gradle-build@1.0.0:
    inputs:
      project_location: "."
      build_type: "Release"
      gradle_task: "assembleRelease"
```

---
### install-missing-android-tools@1.0.0
**Platform:** Android

> Verifies and auto-detects ANDROID_HOME, makes gradlew executable, and validates that Gradle works correctly. Ensures the Android build environment is properly configured.

**Agent Notes:** Verifies/auto-detects ANDROID_HOME, makes gradlew executable, validates Gradle works. Place after git-clone and set-java-version, before gradle-build.

**Requires:** steps: `git-clone`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| gradlew_path | no | `./gradlew` | Path to the Gradle wrapper script |

**Example:**
```yaml
- install-missing-android-tools@1.0.0:
    inputs:
      gradlew_path: "./gradlew"
```

---
### set-java-version@1.0.0
**Platform:** Android

> Sets JAVA_HOME for Android builds by detecting the installed Java version. Searches Homebrew, Android Studio JBR, java_home utility, and Linux paths to locate the correct JDK installation.

**Agent Notes:** Sets JAVA_HOME for Android builds. Searches Homebrew, Android Studio JBR, java_home utility, Linux paths. Must be placed before gradle-build or any Gradle-based step.

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| java_version | no | `17` | Java version to use (e.g. 11, 17, 21) |

**Outputs:** `JAVA_HOME`

**Example:**
```yaml
- set-java-version@1.0.0:
    inputs:
      java_version: "17"
```

---
### sign-apk@1.0.0
**Platform:** Android

> Signs APK or AAB files using apksigner or jarsigner with zipalign. Supports keystore from URL or local file path. Auto-detects signing tool if not specified.

**Agent Notes:** Use after gradle-build to sign the generated APK/AAB. Requires a keystore file and credentials. Set keystore_url, keystore_password, and keystore_alias inputs or env vars.

**Requires:** commands: `zipalign` | steps: `gradle-build`

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| android_app | no | `$CIBUILD_APK_PATH` | Path(s) to APK or AAB files (pipe-separated) |
| keystore_url | yes | - | Keystore file URL or local path (file://...) |
| keystore_password | yes | - | Keystore password |
| keystore_alias | yes | - | Key alias inside the keystore |
| private_key_password | no | - | Private key password (defaults to keystore_password) |
| page_align | no | `automatic` | Page alignment for .so files: automatic | true | false |
| signer_tool | no | `automatic` | Signing tool: automatic | apksigner | jarsigner |
| output_name | no | - | Custom output artifact name (without extension) |
| verbose_log | no | `false` | Enable verbose logging |

**Outputs:** `CIBUILD_SIGNED_APK_PATH`, `CIBUILD_SIGNED_AAB_PATH`

**Example:**
```yaml
- sign-apk@1.0.0:
    inputs:
      keystore_url: "file://./keystore.jks"
      keystore_password: "$KEYSTORE_PASSWORD"
      keystore_alias: "$KEYSTORE_ALIAS"
```

---
<!-- END STEP CATALOG -->

## 6. Common Patterns

### iOS CI Workflow

Full iOS pipeline with dependency caching, CocoaPods, testing, archiving, and deployment:

```yaml
format_version: '1'
meta:
  cibuild.io:
    stack: macos-ventura-xcode-15.1
    machine_type: standard
app:
  envs:
    - WORKSPACE_PATH: MyApp.xcworkspace
    - SCHEME: MyApp
workflows:
  primary:
    steps:
      - activate-ssh-key@1.0.0
      - git-clone@1.0.0
      - cache-pull@1.0.0:
          inputs:
            technology: cocoapods
      - cocoapods-install@1.0.0
      - xcode-test@1.0.0:
          inputs:
            project_path: $WORKSPACE_PATH
            scheme: $SCHEME
            destination: "platform=iOS Simulator,name=iPhone 15,OS=latest"
      - xcode-archive@1.0.0:
          inputs:
            project_path: $WORKSPACE_PATH
            scheme: $SCHEME
            distribution_method: app-store
      - app-store-deploy@1.0.0
      - cache-push@1.0.0:
          inputs:
            technology: cocoapods
      - slack@1.0.0:
          is_always_run: true
          inputs:
            webhook_url: "$SLACK_WEBHOOK_URL"
            channel: "#builds"
            text: "iOS build finished: $CIBUILD_BUILD_STATUS"
```

### iOS Pull Request Workflow

Lint, test, and build for review — with CocoaPods caching and QR code for testers:

```yaml
  pull-request:
    steps:
      - activate-ssh-key@1.0.0
      - git-clone@1.0.0
      - cache-pull@1.0.0:
          inputs:
            technology: cocoapods
      - cocoapods-install@1.0.0
      - swiftlint@1.0.0:
          is_skippable: true
          inputs:
            strict: "yes"
      - xcode-test@1.0.0:
          inputs:
            project_path: $WORKSPACE_PATH
            scheme: $SCHEME
            destination: "platform=iOS Simulator,name=iPhone 15,OS=latest"
            is_code_coverage_enabled: "true"
      - xcode-archive@1.0.0:
          inputs:
            project_path: $WORKSPACE_PATH
            scheme: $SCHEME
            distribution_method: development
      - deploy-to-bitrise-io@1.0.0
      - ota-install@1.0.0:
          inputs:
            ipa_url: "$CIBUILD_PUBLIC_INSTALL_PAGE_URL"
            bundle_id: com.example.MyApp
            bundle_version: "1.0.0"
            title: "MyApp PR Build"
      - cache-push@1.0.0:
          inputs:
            technology: cocoapods
```

### iOS Release Workflow

Version bump, code signing, archive, and App Store upload:

```yaml
  release:
    envs:
      - VERSION_NUMBER: "1.2.0"
    steps:
      - activate-ssh-key@1.0.0
      - git-clone@1.0.0
      - cocoapods-install@1.0.0
      - certificate-installer@1.0.0:
          inputs:
            certificate_url: "$DISTRIBUTION_CERTIFICATE_URL"
            certificate_passphrase: "$DISTRIBUTION_CERTIFICATE_PASSPHRASE"
            provisioning_profile_url: "$PROVISIONING_PROFILE_URL"
            keychain_password: "$KEYCHAIN_PASSWORD"
      - set-xcode-build-number@1.0.0:
          inputs:
            plist_path: MyApp/Info.plist
            bundle_version_short: "$VERSION_NUMBER"
            bundle_version: "$CIBUILD_BUILD_NUMBER"
      - xcode-archive@1.0.0:
          inputs:
            project_path: $WORKSPACE_PATH
            scheme: $SCHEME
            distribution_method: app-store
            automatic_code_signing: "off"
      - app-store-deploy@1.0.0:
          inputs:
            api_key_id: "$APPLE_API_KEY_ID"
            api_issuer: "$APPLE_API_ISSUER_ID"
            api_key_path: "$APPLE_API_KEY_PATH"
```

### iOS Parallel Test Execution

Build test bundle once, run on multiple simulators in parallel:

```yaml
  build-for-test:
    steps:
      - git-clone@1.0.0
      - cocoapods-install@1.0.0
      - xcode-build-for-test@1.0.0:
          inputs:
            project_path: $WORKSPACE_PATH
            scheme: $SCHEME
            destination: "generic/platform=iOS Simulator"

  test-iphone:
    steps:
      - xcode-test-without-building@1.0.0:
          inputs:
            xctestrun_path: "$CIBUILD_XCTESTRUN_PATH"
            destination: "platform=iOS Simulator,name=iPhone 15,OS=latest"

  test-ipad:
    steps:
      - xcode-test-without-building@1.0.0:
          inputs:
            xctestrun_path: "$CIBUILD_XCTESTRUN_PATH"
            destination: "platform=iOS Simulator,name=iPad Pro (12.9-inch),OS=latest"
```

### Android CI Workflow

Full Android pipeline with Gradle caching, lint, unit tests, and deployment:

```yaml
format_version: '1'
meta:
  cibuild.io:
    stack: linux-docker-android-22.04
app:
  envs:
    - PROJECT_LOCATION: .
    - MODULE: app
    - VARIANT: debug
workflows:
  primary:
    steps:
      - activate-ssh-key@1.0.0
      - git-clone@1.0.0
      - cache-pull@1.0.0:
          inputs:
            technology: gradle
      - set-java-version@1.0.0:
          inputs:
            java_version: "17"
      - install-missing-android-tools@1.0.0
      - android-unit-test@1.0.0:
          inputs:
            project_location: $PROJECT_LOCATION
            module: $MODULE
            variant: $VARIANT
      - android-lint@1.0.0:
          inputs:
            project_location: $PROJECT_LOCATION
            module: $MODULE
            variant: $VARIANT
      - gradle-build@1.0.0:
          inputs:
            project_location: $PROJECT_LOCATION
            gradle_task: assembleRelease
      - deploy-to-bitrise-io@1.0.0
      - cache-push@1.0.0:
          inputs:
            technology: gradle
      - slack@1.0.0:
          is_always_run: true
          inputs:
            webhook_url: "$SLACK_WEBHOOK_URL"
            channel: "#builds"
            text: "Android build finished: $CIBUILD_BUILD_STATUS"
```

### Android Pull Request Workflow

Lint, unit tests, and Detekt static analysis — with Gradle caching:

```yaml
  pull-request:
    steps:
      - git-clone@1.0.0
      - cache-pull@1.0.0:
          inputs:
            technology: gradle
      - set-java-version@1.0.0:
          inputs:
            java_version: "17"
      - android-lint@1.0.0:
          inputs:
            project_location: $PROJECT_LOCATION
            module: $MODULE
            variant: debug
      - detekt@1.0.0:
          is_skippable: true
          inputs:
            project_location: $PROJECT_LOCATION
      - android-unit-test@1.0.0:
          inputs:
            project_location: $PROJECT_LOCATION
            module: $MODULE
            variant: debug
      - cache-push@1.0.0:
          inputs:
            technology: gradle
```

### Android Release Workflow

Version bump, build AAB, sign, and deploy to Google Play:

```yaml
  release:
    envs:
      - VERSION_NAME: "1.2.0"
    steps:
      - activate-ssh-key@1.0.0
      - git-clone@1.0.0
      - set-java-version@1.0.0:
          inputs:
            java_version: "17"
      - change-android-versioncode-and-versionname@1.0.0:
          inputs:
            build_gradle_path: "$PROJECT_LOCATION/app/build.gradle"
            new_version_name: "$VERSION_NAME"
            new_version_code: "$CIBUILD_BUILD_NUMBER"
      - gradle-build@1.0.0:
          inputs:
            project_location: $PROJECT_LOCATION
            gradle_task: bundleRelease
      - sign-apk@1.0.0:
          inputs:
            keystore_url: "file://./release.keystore"
            keystore_password: "$KEYSTORE_PASSWORD"
            keystore_alias: "$KEYSTORE_ALIAS"
      - google-play-deploy@1.0.0:
          inputs:
            package_name: com.example.myapp
            track: production
            status: draft
```

### Android UI Testing

Build app and test APKs for instrumented testing:

```yaml
  ui-tests:
    steps:
      - git-clone@1.0.0
      - set-java-version@1.0.0:
          inputs:
            java_version: "17"
      - android-build-for-ui-testing@1.0.0:
          inputs:
            project_location: $PROJECT_LOCATION
            module: $MODULE
            variant: debug
```

### Flutter Build + Test + Release

Full Flutter pipeline: install SDK, test with coverage, build for both platforms, create GitHub release:

```yaml
format_version: '1'
meta:
  cibuild.io:
    stack: macos-ventura-xcode-15.1
app:
  envs:
    - FLUTTER_PROJECT: .
workflows:
  primary:
    steps:
      - git-clone@1.0.0
      - flutter-installer@1.0.0:
          inputs:
            version: stable
      - flutter-test@1.0.0:
          inputs:
            project_location: $FLUTTER_PROJECT
            generate_code_coverage_files: "true"
      - flutter-build@1.0.0:
          inputs:
            project_location: $FLUTTER_PROJECT
            platform: both
            android_output_type: appbundle
            ios_output_type: archive
      - generate-changelog@1.0.0:
          inputs:
            changelog_path: "./artifacts/CHANGELOG.md"
      - github-release@1.0.0:
          inputs:
            tag: "v1.0.0"
            name: "Release 1.0.0"
            changelog_path: "./artifacts/CHANGELOG.md"
            files_to_upload: |
              $CIBUILD_AAB_PATH
      - slack@1.0.0:
          is_always_run: true
          inputs:
            webhook_url: "$SLACK_WEBHOOK_URL"
            text: "Flutter build finished: $CIBUILD_BUILD_STATUS"
```

### Fastlane-Based iOS Workflow

Use Fastlane lanes for build and deployment:

```yaml
  fastlane-release:
    steps:
      - activate-ssh-key@1.0.0
      - git-clone@1.0.0
      - cache-pull@1.0.0:
          inputs:
            technology: cocoapods
      - cocoapods-install@1.0.0
      - fastlane@1.0.0:
          inputs:
            lane: "ios release"
            work_dir: "."
            verbose_log: "true"
      - cache-push@1.0.0:
          inputs:
            technology: cocoapods
```

### iOS Nightly Build

Dual-build: App Store release for TestFlight + development build for testers:

```yaml
  nightly:
    steps:
      - activate-ssh-key@1.0.0
      - git-clone@1.0.0
      - cocoapods-install@1.0.0
      - set-xcode-build-number@1.0.0:
          inputs:
            plist_path: MyApp/Info.plist
            bundle_version: "$CIBUILD_BUILD_NUMBER"
      - xcode-archive@1.0.0:
          title: "Archive for App Store"
          inputs:
            project_path: $WORKSPACE_PATH
            scheme: $SCHEME
            distribution_method: app-store
      - app-store-deploy@1.0.0
      - xcode-archive@1.0.0:
          title: "Archive for Testing"
          inputs:
            project_path: $WORKSPACE_PATH
            scheme: $SCHEME
            distribution_method: development
      - deploy-to-bitrise-io@1.0.0
      - ota-install@1.0.0:
          inputs:
            ipa_url: "$CIBUILD_PUBLIC_INSTALL_PAGE_URL"
            bundle_id: com.example.MyApp
            bundle_version: "1.0.0"
            title: "MyApp Nightly"
      - slack@1.0.0:
          is_always_run: true
          inputs:
            webhook_url: "$SLACK_WEBHOOK_URL"
            channel: "#nightly"
            text: "Nightly build ready"
```

### Android Nightly Build

Dual-build: AAB for internal Play Store track + APK for testers:

```yaml
  nightly:
    steps:
      - activate-ssh-key@1.0.0
      - git-clone@1.0.0
      - set-java-version@1.0.0:
          inputs:
            java_version: "17"
      - change-android-versioncode-and-versionname@1.0.0:
          inputs:
            build_gradle_path: "$PROJECT_LOCATION/app/build.gradle"
            new_version_name: "1.0.0"
            new_version_code: "$CIBUILD_BUILD_NUMBER"
      - gradle-build@1.0.0:
          title: "Build AAB for Play Store"
          inputs:
            project_location: $PROJECT_LOCATION
            gradle_task: bundleRelease
      - sign-apk@1.0.0:
          inputs:
            keystore_url: "file://./release.keystore"
            keystore_password: "$KEYSTORE_PASSWORD"
            keystore_alias: "$KEYSTORE_ALIAS"
      - google-play-deploy@1.0.0:
          inputs:
            package_name: com.example.myapp
            track: internal
      - gradle-build@1.0.0:
          title: "Build APK for Testing"
          inputs:
            project_location: $PROJECT_LOCATION
            gradle_task: assembleDebug
      - deploy-to-bitrise-io@1.0.0
      - slack@1.0.0:
          is_always_run: true
          inputs:
            webhook_url: "$SLACK_WEBHOOK_URL"
            channel: "#nightly"
            text: "Android nightly build ready"
```

## 7. Secrets

Set secrets via CLI: `ci secrets add <KEY>` (global) or `ci secrets add <KEY> -w <workflow>` (workflow-scoped).

File-based secrets (keystores, certificates, JSON keys) use the `file` step — content is base64-encoded in `.cibuild-secrets.json` and decoded at runtime.
