# 개발 · 연결 · 배포 가이드

[← Checker 소개로 돌아가기](../README.md)

소스에서 실행하거나 연결 구조·데이터 저장·배포 과정을 확인할 때 사용하는 문서입니다. 아래 명령은 저장소 루트에서 실행합니다. 앱 설치만 필요하다면 [설치 안내](../INSTALL.md)를 참고하세요.

## 소스에서 실행

macOS 13 이상과 Apple Command Line Tools(Swift), Python 3이 필요합니다. Chrome AI 추가 기능에는 Codex 앱 설치와 로그인이 필요합니다.

```sh
./scripts/build.sh
python3 scripts/setup_integrations.py --install --claude
open "$HOME/Applications/Checker.app"
```

## Codex · Claude · Chrome 연결

```sh
python3 scripts/setup_integrations.py --install --claude
```

이 명령은 앱을 `~/Applications/Checker.app`에 복사하고, 실행용 브리지와 스킬을 `~/Library/Application Support/Checker/runtime/`에 설치합니다. Codex 스킬 링크와 Chrome Native Messaging 호스트를 등록하고, Claude 데스크톱 설정에 `checker` MCP 항목을 병합합니다. 실행용 파일이 바탕화면 프로젝트에 의존하지 않아 Claude에 바탕화면 접근 권한을 추가할 필요가 없습니다. 기존 연결은 보존하며 Claude 설정의 최초 변경 전 백업을 남깁니다. 같은 이름의 다른 설치는 덮어쓰지 않습니다.

설정 파일만 준비하려면 인자 없이 실행합니다. 준비된 파일은 `build/native-host.json`, `build/claude-desktop-config.json`입니다. 해당 설정을 사용하려면 위 설치 명령으로 런타임도 설치해야 합니다.

### Codex

새 대화에서 `$checker-capture`를 사용해 “이 결과를 나중에 확인하게 추가해줘”처럼 요청합니다. 현재 카테고리를 읽고 작업 맥락으로 분류해 등록합니다. 카테고리가 애매하면 미분류로 남깁니다.

현재 대화의 실제 ID가 `CODEX_THREAD_ID` 환경 변수로 제공되면 CLI가 `codex://threads/<실제 ID>`를 저장합니다. 그 외에는 대화의 실제 링크를 함께 제공해야 합니다. 대화 ID를 추측하거나 로컬 기록을 무단으로 수집하지 않습니다.

### Claude 데스크톱

설정 후 Claude 데스크톱을 다시 시작하고 Checker의 `list_categories`, `add_checklist_item` 도구를 사용합니다. MCP 서버는 의존성 없는 Python stdio 서버이며 MCP 2025 초기화 방식을 지원합니다.

**Claude가 현재 대화 URL을 자동으로 제공하지 않는 경우가 있습니다.** 그때는 실제 대화 링크를 함께 제공해야 정확한 대화로 돌아갈 수 있습니다. 링크가 없으면 일반 항목으로 저장하고, 링크가 있는 것처럼 보고하지 않습니다. Claude 웹에서는 Chrome 확장으로 현재 대화 URL을 바로 저장할 수 있습니다.

Claude 설정 경로: `~/Library/Application Support/Claude/claude_desktop_config.json`

Claude 데스크톱은 실행 중에 이 파일을 다시 저장하면서 새로 추가된 연결을 지울 수 있습니다. 그래서 Claude가 실행 중이면 앱은 바로 설치하지 않고 **Claude 종료 후 설치**를 안내합니다. 이 버튼은 Claude를 종료하고 연결을 설치한 뒤 Claude를 다시 엽니다.

### Claude Code

연결 설정에서 **Claude Code**를 선택하면 같은 MCP 서버를 Claude Code의 사용자 범위(`~/.claude.json`의 `mcpServers.checker`)에 등록합니다. 모든 프로젝트에서 `list_categories`, `add_checklist_item` 도구를 쓸 수 있으며 등록 후 **새로 시작한 세션**부터 적용됩니다. 다른 설정과 프로젝트별 MCP는 그대로 두고, 최초 변경 전 `~/.claude.json.checker-backup`을 남깁니다. 같은 이름의 다른 `checker` 연결이 있으면 덮어쓰지 않습니다. 소스에서는 `python3 scripts/setup_integrations.py --install --claude-code`로 등록합니다.

Claude 데스크톱에서 실행한 Claude Code 세션은 `claude://code/continue?session=local_<ID>` 링크를 원문 링크로 저장해, 제목을 누르면 그 세션으로 돌아갑니다. 세션 ID(`CLAUDE_CODE_HOST_SESSION_ID`)는 Claude가 전달하거나, Claude Code가 띄운 연결에서는 자동으로 채웁니다. 이 링크가 없는 터미널 세션은 실제 세션 ID가 `CLAUDE_CODE_SESSION_ID`로 제공되면 메모 끝에 `claude --resume <세션 ID>`를 남깁니다.

Jira·PR·문서처럼 작업 대상이 되는 웹페이지는 `relatedURL`로 원문 링크와 따로 저장하고, 항목 아래 🔗 링크로 엽니다. Codex·Claude가 웹페이지를 원문 링크로 넘겨도 실제 대화 링크를 알 수 있으면 대화 링크를 원문으로 쓰고 웹페이지는 관련 링크로 옮깁니다.

### Chrome

1. `chrome://extensions`를 엽니다.
2. 개발자 모드를 켜고 **압축해제된 확장 프로그램을 로드합니다**를 누릅니다.
3. 이 프로젝트의 `extension` 폴더를 선택합니다.
4. 웹페이지에서 Checker 아이콘을 열고 **추가하기**만 누릅니다. 입력할 내용은 없습니다.

확장의 ID는 `manifest.json`에 있는 공개 키로 고정합니다. 설치할 ID는 `build/extension-id.txt`에도 기록됩니다. Native Messaging은 이 ID에서 온 연결만 받습니다.

AI가 현재 탭의 화면 이미지·본문·선택한 문장을 읽고 **할 일 제목, 메모, 기존 카테고리**를 정합니다. 예를 들어 PR에서는 변경 내용을 읽고 무엇을 검토할지 구체적으로 정리합니다. 현재 보이는 화면과 선택 문장을 우선하며 원래 페이지 URL은 그대로 보존합니다. 선택 문장이나 페이지의 우클릭 메뉴에서도 같은 분석을 시작할 수 있습니다. 화면 이미지를 얻을 수 없으면 읽을 수 있는 본문으로 분석합니다.

분석은 로그인된 Codex 계정의 사용 한도를 사용합니다. 팝업을 닫아도 계속 진행하며 완료된 뒤 Checker에 추가됩니다. 팝업을 다시 열면 진행 상황과 결과를 확인할 수 있습니다. AI 분석이 실패하면 오류를 표시하고 다시 시도할 수 있습니다. 분석용 본문·이미지 임시 파일은 처리 후 삭제합니다.

이전 버전을 설치했다면 `chrome://extensions`에서 Checker의 **새로고침**을 한 번 눌러 0.3 버전을 반영합니다. 확장 소스가 바뀐 뒤에도 같은 방법으로 갱신합니다.

## 직접 등록 / 연결 확인

```sh
python3 bridge/checker_bridge.py categories
python3 bridge/checker_bridge.py add --json <<'JSON'
{
  "title": "Codex 저장소 확인",
  "sourceApp": "chrome",
  "sourceURL": "https://github.com/openai/codex",
  "categoryID": "documents",
  "note": "공개 저장소의 README를 확인하기"
}
JSON
```

`added`는 앱이 실제 목록 파일에 저장한 뒤 발행한 확인입니다. `queued`는 등록 요청이 로컬 큐에 안전하게 저장되었으며 앱 실행 후 반영된다는 뜻입니다. 같은 등록을 재시도할 때 UUID `requestID`를 재사용하면 보관된 항목도 중복 생성하지 않습니다.

## 저장 위치와 구조

`~/Library/Application Support/Checker/`

- `checklist.json`: 항목·카테고리. 앱만 원자적으로 갱신합니다.
- `window.json`: 위치·크기·고정·접힘 설정.
- `settings.json`: 앱·확장·AI가 공유하는 언어 (`en` / `ko`).
- `inbox/`: 스킬·확장의 등록 큐. 앱이 닫혀 있어도 남습니다.
- `receipts/`: 실제 저장 결과. 중복 요청을 판별합니다.
- `failed/`: 형식이 잘못된 요청. 정상 요청을 막지 않도록 분리합니다.
- `runtime/`: 설치한 브리지·스킬·Chrome 연결 실행 파일.
- `analysis/jobs/`: Chrome AI 분석의 진행 상태와 결과. 분석용 본문·이미지는 `analysis/requests/`, `analysis/images/`에 잠시 저장한 뒤 삭제합니다.

테스트용 저장소는 `CHECKER_DATA_DIR` 환경 변수 또는 앱의 `--data-dir`로 분리합니다. `Checker --import-only --data-dir <폴더>`는 UI 없이 큐를 반영하는 진단 명령입니다.

## 검증

```sh
./scripts/test.sh
```

Swift 저장소 검사와 Python 브리지 검사를 실행합니다. XCTest가 포함되지 않은 Command Line Tools 환경에서도 동작하도록 Swift 검사는 별도의 작은 실행 타깃을 사용합니다. 원문 링크·카테고리 유지, 보관·복구, 재전송 중복 방지, 저장 후 확인, 잘못된 요청 격리, CLI→Swift 저장소 통합과 Native Messaging/MCP 프레이밍을 검사합니다.

설치 검사에서는 개발 프로젝트를 제거한 뒤에도 설치된 스킬이 실행되는지, 업그레이드가 기존 Claude 연결과 설정을 보존하는지 확인합니다.

AI 연결 검사는 모델을 호출하지 않는 단위 검사에 포함됩니다. 확장의 화면 수집·탭 변경 감지·분석 실패 동작은 Node.js 환경에서 별도로 검사합니다.

```sh
node Tests/test_extension.mjs
```

실제 이미지 분석까지 확인하려면 아래 선택 검사를 실행합니다. 합성 PR 화면과 임시 저장소만 사용하며 로그인된 Codex 계정으로 실제 모델을 호출합니다. 이미지에만 있는 내용을 읽는지, 팝업에 해당하는 Native Messaging 프로세스가 끝난 뒤에도 저장되는지, 원문 링크 유지와 임시 파일 삭제를 확인합니다.

```sh
python3 scripts/test_ai_live.py
python3 scripts/test_ai_live.py --installed
```

## 배포용 설치 파일

Apple Silicon Mac에서 Python 3.12 이상과 Command Line Tools로 빌드합니다.

```sh
python3 scripts/package.py
python3 scripts/test_distribution.py
python3 scripts/test_installer.py
```

`VERSION`의 버전으로 다음 산출물을 만듭니다.

- `dist/Checker-<버전>-macOS-arm64.dmg`: 앱·포함된 Python·연결 설치 도구·Chrome 확장·설치 안내.
- `dist/Checker-<버전>-Chrome-extension.zip`: Chrome 확장을 별도로 전달할 때 사용하는 압축 파일.
- `dist/SHA256SUMS.txt`, `dist/release.json`: 파일 체크섬과 서명·공증·런타임 정보.
- `dist/install.json`: AI 설치 도구가 사용하는 버전·공식 다운로드 URL·SHA-256. 릴리스 공개 후 저장소 루트의 `install.json`도 이 파일로 갱신합니다.

Python Standalone Builds의 런타임을 지정된 버전·SHA-256으로 확인하고 포함합니다. 관련 라이선스와 고정된 소스 정보도 앱에 넣습니다. 빌드 입력은 앱 코드·연결 코드·확장·스킬·런타임으로 제한하며 사용자 데이터나 로그인 정보를 읽어 패키지에 넣지 않습니다.

배포판 설치 검사는 디스크 이미지를 마운트한 뒤 앱을 임시 사용자 폴더에 복사하고 **디스크 이미지를 추출한 상태에서** 수행합니다. 포함된 Python 사용, Chrome Native Messaging → 앱 저장·확인, Codex 스킬, Claude MCP 초기화와 도구 목록을 확인합니다. 단위 검사에서는 업데이트 시 기존 설정·체크리스트 보존과 알 수 없는 연결을 덮어쓰지 않는 동작도 검사합니다.

설치 스크립트 검사는 별도 폴더에서 신규 설치·같은 버전 재실행·업데이트를 확인합니다. 같은 버전의 앱은 교체하지 않고 백업도 만들지 않으며, 실제 업데이트에서는 이전 앱과 기존 데이터를 보존합니다. 앱 실행과 연결 등록은 이 스크립트가 수행하지 않습니다.

실제 AI 이미지 분석을 배포판의 Python으로 확인하는 선택 검사도 있습니다. 합성 화면만 보내며 로그인된 Codex 계정으로 실제 모델을 호출합니다.

```sh
python3 scripts/test_ai_live.py --app-bundle build/distribution/Checker.app --language en
python3 scripts/test_ai_live.py --app-bundle build/distribution/Checker.app --language ko
```

번역 원본은 `localization/strings.json`입니다. 수정 후 `python3 scripts/sync_localization.py`로 Swift·Chrome 카탈로그를 갱신합니다. 앱 빌드·패키징에서도 자동으로 갱신하며 검증 스크립트는 생성 파일이 최신인지 검사합니다.

기본 빌드는 모든 실행 파일을 ad-hoc 서명한 테스트 배포판입니다. 외부 공개용 Developer ID Application 인증서와 저장된 notarytool 프로필을 준비한 뒤에는 아래 명령으로 서명·공증·티켓 첨부까지 수행할 수 있습니다. `--notary-profile`을 지정하면 Apple 공증 서비스로 설치 파일을 전송합니다.

```sh
python3 scripts/package.py \
  --sign-identity 'Developer ID Application: YOUR NAME (TEAM_ID)' \
  --notary-profile YOUR_NOTARY_PROFILE
```

Intel Mac·Windows용 패키지와 Chrome 웹 스토어 등록은 아직 지원하지 않습니다. 배포판의 Chrome 확장은 `~/Library/Application Support/Checker/runtime/extension`에 설치되므로 소스 프로젝트나 디스크 이미지에 의존하지 않습니다.

## 참고한 공식 문서

- [Codex 대화 딥링크](https://learn.chatgpt.com/docs/app/commands)
- [Codex 비대화형 실행](https://learn.chatgpt.com/docs/non-interactive-mode)
- [Codex CLI 이미지·구조화 출력 옵션](https://learn.chatgpt.com/docs/cli/reference)
- [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
- [Chrome 확장 ID 유지](https://developer.chrome.com/docs/extensions/reference/manifest/key)
- [MCP 초기화 프로토콜](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
- [AppKit NSPanel](https://developer.apple.com/documentation/appkit/nspanel)
- [Python Standalone Builds 배포 구조](https://docs.astral.sh/python-build-standalone/distributions/)
- [Apple Developer ID 배포](https://developer.apple.com/developer-id/)
- [Mac에서 앱을 안전하게 열기](https://support.apple.com/en-us/102445)
