# Install Checker with an AI assistant

**Apple Silicon · macOS 13+ · no developer tools required.**

Copy this into an assistant that can run local commands:

```text
이 안내에 따라 Checker를 설치해줘:
https://raw.githubusercontent.com/ruvora/checker/main/INSTALL.md
```

```text
Install Checker on this Mac using:
https://raw.githubusercontent.com/ruvora/checker/main/INSTALL.md
```

## For the assistant

1. Download and read the [v0.7.0 installer](https://raw.githubusercontent.com/ruvora/checker/v0.7.0/install.sh). Save its absolute temporary path; shell variables may not persist between tool calls.
2. Run `/bin/bash <saved-path> --yes --version 0.7.0`. It verifies the official download and copies Checker into `~/Applications`. A valid installation of the same version is left unchanged. If updating a running app, close Checker first.
3. Open Checker normally. In **Settings & connections**, choose English or 한국어 and press **Install selected connections**. The app handles connector registration through this existing button.
4. Help the user finish the Chrome extension instructions and restart Claude if selected. An installed app does not mean those steps are complete.

Follow your host's tool permissions. Do not bypass macOS approvals, remove quarantine attributes, or modify Chrome profiles/policies. The script does not execute the downloaded app or change connection settings. It preserves checklist data and backs up the previous app only when replacing it with another version.

The preview is not Apple-notarized, so normal macOS approval may be required when opening it. Chrome extension loading remains a one-time user action. AI capture requires a signed-in Codex app and uses that account's usage limits.

## 한국어

AI가 다운로드·검증·앱 복사를 진행합니다. 같은 버전이면 재설치하지 않습니다. 이후 앱을 열어 **연결 설정 → 선택한 연결 설치**를 한 번 누르면 됩니다. macOS 실행 승인과 Chrome 확장 추가는 직접 확인합니다.

설치 대기·재개나 별도 상태 조회는 없습니다. 설치 파일과 자세한 수동 안내는 [Releases](https://github.com/ruvora/checker/releases)에서 제공합니다.
