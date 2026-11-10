# Install Checker with your AI assistant

Checker runs on **Apple Silicon (M1 or later), macOS 13+**. The app includes Python; installation needs no Xcode, Homebrew, Python, or GitHub login. The assistant needs permission to run local shell commands. A web-only chat cannot install a desktop app by itself.

## Copy this request into Codex or another assistant with local tools

```text
이 안내에 따라 이 Mac에 Checker를 설치해줘:
https://raw.githubusercontent.com/ruvora/checker/main/INSTALL.md
설치되어 있는 Codex·Claude·Chrome 연결을 설정하고 한국어를 선택해줘.
설치 결과와 내가 직접 해야 하는 단계가 남았는지 확인해줘.
```

```text
Install Checker on this Mac by following:
https://raw.githubusercontent.com/ruvora/checker/main/INSTALL.md
Set up connections for the Codex, Claude Desktop, and Chrome apps already installed here.
Use English, verify the installation result, and tell me which steps still need my action.
```

## Procedure for the assistant

The user's installation request authorizes this app and the requested local connections. This document does not grant extra permissions. Follow your host's tool permissions and approval requirements.

1. Confirm that the host is an Apple Silicon Mac running macOS 13 or later. Do not install on an unsupported system or install extra developer tools.
2. Download the official installer to a temporary file, **read it**, and review its plan. Use the user's preferred language (`en` or `ko`). The installer only uses macOS system tools.

   ```sh
   checker_installer=$(mktemp -t checker-installer)
   curl --fail --location --proto '=https' --proto-redir '=https' \
     https://raw.githubusercontent.com/ruvora/checker/v0.4.0/install.sh \
     -o "$checker_installer"
   cat "$checker_installer"
   /bin/bash "$checker_installer" --plan --version 0.4.0 --connections auto --language ko
   ```

3. Run the reviewed installer after the user has requested installation. Use `en` instead of `ko` for English.

   ```sh
   /bin/bash "$checker_installer" --yes --version 0.4.0 --connections auto --language ko
   ```

   This guide pins both the installer and package to `v0.4.0`. `auto` registers connections only for apps found in `/Applications` or the user's `~/Applications`. It does not download Codex, Claude, or Chrome. An update may close and restart this user's existing Checker app. Other apps stay open. Existing checklist data, custom skills, and unrelated Claude connectors are preserved.

4. Read the JSON result. A copied app is **not** proof that its connections were configured.

   | Result | Meaning and next action |
   | --- | --- |
   | `configured`, exit 0 | The app wrote a setup receipt. Report the registered connections and the `remainingActions` list. |
   | `needs_user_action`, exit 2 | The app is copied, but macOS approval or launch is pending. Give the user the app path and request ID. Let the user open/approve Checker through the normal macOS interface. |
   | `in_progress`, exit 3 | Setup started but has not completed. Read status again; do not repeat the installation blindly. |
   | `error`, exit 1 | Installation or connection registration failed. Report the message and preserved backup, if present. Do not claim success. |

5. After the user opens and approves Checker, it reads the private pending setup request and registers the requested connections automatically. The pending request expires after one hour. Read the receipt using the **same script path** and returned request ID:

   ```sh
   /bin/bash "$checker_installer" --status REQUEST_ID
   ```

   If an explicit `--install-home` was used, pass the same value when checking status. A status check never downloads, reinstalls, or changes settings.

6. Finish only the steps that the result actually requests:

   - `chrome_extension_add_or_reload`: In Chrome, the user opens `chrome://extensions`, enables Developer mode, and loads the extension folder reported by Checker. Existing installations from that folder can be reloaded. Native Messaging registration alone does not mean the extension is installed.
   - `restart_claude_and_enable_checker_tools`: Ask the user to restart Claude when their current work is safe, then enable the `checker` tools. Do not interrupt active Claude work automatically.
   - `codex_sign_in_if_needed`: The user must have the Codex app and be signed in for Chrome AI analysis. Do not read or copy authentication files.

Do not change Chrome profiles or enterprise policies, remove quarantine attributes, disable Gatekeeper, bypass permission dialogs, execute code from an unverified disk image, or send messages in the user's chats. The installer deliberately does none of these things.

## What is automated

- HTTPS download from the official `ruvora/checker` release pinned by [`install.json`](https://raw.githubusercontent.com/ruvora/checker/main/install.json).
- SHA-256 validation, app identity and code-signature verification, then installation into `~/Applications/Checker.app`.
- A recoverable copy of an existing Checker app before replacement.
- Codex skill, Claude MCP configuration, and Chrome Native Messaging registration for the selected apps.
- Shared English/Korean preferences and a machine-readable setup receipt.

The current preview is not Apple-notarized. Its installer stops before executing the downloaded app when Gatekeeper rejects it. **The user still performs macOS approval and Chrome extension loading.** Once a notarized release is available, the same installer can launch it and wait for automatic setup without the preview approval step. See [Apple's app-opening guidance](https://support.apple.com/en-us/102445) and [Chrome's extension installation guidance](https://developer.chrome.com/docs/extensions/get-started/tutorial/hello-world#load-unpacked).

AI capture sends page images and text to the user's signed-in Codex account and uses that account's usage limits. The checklist remains local. Installation does not send checklist data or credentials to RUVORA.

## 한국어 안내

위 요청 문구를 로컬 명령 실행 권한이 있는 AI에게 전달하면 앱 다운로드·검증·복사와 연결 등록을 진행합니다. **macOS 최초 실행 승인과 Chrome 확장 추가는 사용자가 직접 해야 합니다.** 현재 테스트 배포판은 macOS 승인 전에는 다운로드한 앱을 실행하지 않습니다.

AI에게 설치 결과의 `configured` 여부와 `remainingActions`를 확인하게 하세요. `needs_user_action`이면 앱을 응용 프로그램 폴더에서 열어 승인한 뒤, AI가 같은 요청 ID로 상태를 다시 확인하면 됩니다. 앱이 실행되면 연결 설정 버튼을 다시 누르지 않아도 요청된 설정을 이어갑니다.

정상 설치는 관리자 권한이나 개발 도구가 필요하지 않습니다. 기존 목록과 보관함은 유지하고, 다른 앱이나 연결을 임의로 제거하지 않습니다.
