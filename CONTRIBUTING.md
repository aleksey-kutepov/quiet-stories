# Contributing

Quiet Stories is an independent SwiftUI/WKWebView browser for Instagram Stories and messages. Development uses Apple's frameworks and Xcode; no package installation or backend is required. See [README.md](README.md) for setup, simulator commands, and physical-device checks.

## Report a bug

Include the app revision if available, iOS and Xcode versions, device or simulator model, steps to reproduce, expected behavior, and what happened. For a layout issue, describe the affected screen and whether it recovers after refresh. Share a minimal synthetic HTML example when possible.

Do not post passwords, session cookies, authentication URLs, recovery codes, account names, private messages, or captured Instagram page content. Redact personal details from screenshots and logs. Read [SECURITY.md](SECURITY.md) before reporting a security-sensitive issue; keep sensitive reproduction details out of public reports.

## Propose a change

Use a branch or other checkout that suits your workflow. `sh scripts/open-main.sh` opens the project from that checkout despite its historical filename. The owner's optional `stories.requirePrimaryMain` Git setting is not required for contributions.

Keep pull requests focused. Explain the problem, the resulting behavior, and how you verified it. Add a local synthetic regression fixture when changing navigation, filtering, authentication, or session behavior. Avoid tests that require an Instagram account, credentials, live messages, or saved website data.

Run `sh scripts/test.sh` before submitting; use `STORIES_TEST_DESTINATION` if you need a particular simulator. Keep build products in the ignored `DerivedData/` directory; the test script saves result bundles under the ignored `artifacts/` directory. Note any relevant physical-device checks and any you could not perform. Passing local fixtures does not establish compatibility with Instagram's live pages.

Preserve the app's dependency-free design and fail-closed behavior: unsupported content stays hidden. New hosts or routes, authentication-page handling, bridge messages, network libraries, analytics, and session lifecycle changes need particular review. See [SECURITY.md](SECURITY.md) for the boundaries to preserve.

Use the ignored `Config/Local.xcconfig` for your development team and unique bundle identifier. Do not commit personal signing settings, certificates, credentials, generated artifacts, or account data.

Contributions are provided under the project's [MIT license](LICENSE). Include appropriate attribution and license notices for any third-party material you propose.
