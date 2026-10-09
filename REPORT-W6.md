# W6 Report

Files: `scripts/lint-qml.sh`, `.github/workflows/lint.yml`, `.qml-lint-allowlist`, README `## Development` line.

Verified locally: `scripts/lint-qml.sh` exits 1 on qmllint failure and prints failing file names; allowlist substring matching works; `deno test --allow-read tests/model.test.js` passes.

Note: local qmllint 1.0 exits 255 silently on Panel.qml (Quickshell root type); allowlist left empty per brief.

Workflow YAML:

```yaml
name: lint

on:
  push:
    branches: [main, "main/*"]
  pull_request:
    branches: [main, "main/*"]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install qmllint (Qt6)
        run: |
          sudo apt-get update
          sudo apt-get install -y qt6-declarative-dev

      - name: Lint QML
        run: scripts/lint-qml.sh

      - name: Setup Deno
        uses: denoland/setup-deno@v2
        with:
          deno-version: v2.x

      - name: Run model tests
        run: deno test --allow-read tests/model.test.js
```

W6 DONE