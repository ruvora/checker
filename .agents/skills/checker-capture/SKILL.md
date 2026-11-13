---
name: checker-capture
description: 작업이 끝난 뒤 사용자가 나중에 확인할 일, 결과 검토, 웹페이지 후속 작업을 로컬 Checker 체크리스트에 남기려 할 때 사용한다.
---

# Checker에 후속 작업 남기기

사용자가 챙기려는 다음 행동을 짧은 제목으로 기록한다. 실행 중인 AI 작업이나 자동 완료 상태를 만들지 않는다.

1. `"<이 스킬 폴더>/scripts/checker" categories`로 현재 카테고리·설명·`language` (`en`/`ko`)를 읽는다. 새 제목과 메모는 이 언어로 작성하되 사용자가 다른 언어를 명시하면 그 요청을 따른다. 기존 항목이나 직접 만든 카테고리 이름을 번역해 덮어쓰지 않는다. 이 실행 파일은 Checker에 포함된 Python을 사용한다.
2. 제목·현재 작업 맥락으로 기존 카테고리 ID를 고른다. 애매하면 `uncategorized`를 쓴다. 카테고리를 임의로 새로 만들지 않는다. 사용자가 지정한 분류를 우선한다.
3. 원래 작업으로 돌아갈 정확한 링크를 함께 보낸다. Codex의 실제 thread ID가 현재 맥락에서 제공되면 `codex://threads/<실제 ID>`를 쓴다. CLI는 `CODEX_THREAD_ID`가 있으면 이를 사용한다. Claude 데스크톱의 Claude Code 세션은 `claude://code/continue?session=<$CLAUDE_CODE_HOST_SESSION_ID 값>`, Claude 채팅은 실제 대화 URL, Chrome은 실제 페이지 URL을 쓴다. Jira·PR·문서처럼 작업 대상이 되는 웹페이지는 원문 링크가 아니라 `relatedURL`에 넣는다. 확인할 수 없는 ID나 대화 URL을 추측하지 않는다. 링크가 없으면 그 사실을 알리고 사용자가 제공한 링크를 받거나, 링크 없이 남기는 것이 의도에 맞는 경우 생략한다.
4. 현재 대화에 실제로 표시된 제목을 알면 `sessionName`에 넣는다. Codex 연결은 대화 링크에 해당하는 로컬 제목을 찾을 수 있다. `projectName`에는 알려진 프로젝트명이나 현재 작업의 저장소·워크스페이스 폴더 이름만 넣는다. CLI는 현재 작업 폴더가 Git 저장소 안에 있으면 그 저장소 폴더 이름을 기본값으로 쓴다. 세션 ID, 절대 경로, 추측한 이름은 넣지 않는다. 모르는 필드는 생략한다.
5. `"<이 스킬 폴더>/scripts/checker" add --json`에 JSON을 stdin으로 전달한다. 필드는 `title`, `sourceApp` (`codex`/`claude`/`chrome`/`manual`), `sourceURL` (선택), `relatedURL` (선택, 웹페이지), `sessionName` (선택), `projectName` (선택), `categoryID`, `note` (선택), `requestID` (선택 UUID)다. 제목은 실제 해야 할 행동으로 쓰고, 긴 대화 전체 대신 필요한 맥락만 메모한다. 사용자 문자열을 셸 코드에 삽입하지 말고 인용된 heredoc 또는 JSON 파일을 사용한다.
6. 반환된 `status`를 확인한다. `added`면 실제 목록 저장 완료다. `queued`면 로컬에 등록 요청이 저장됐으며 앱이 열리면 반영된다고 알린다. 오류를 완료로 보고하지 않는다. 같은 요청을 재시도할 때는 같은 `requestID`를 재사용한다.

Claude 데스크톱에서 Checker MCP 도구가 연결되어 있으면 `list_categories`와 `add_checklist_item`으로 같은 흐름을 수행할 수 있다. Claude 웹은 Chrome 확장에서 실제 대화 URL과 함께 저장할 수 있다.
