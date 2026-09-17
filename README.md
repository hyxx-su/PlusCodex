# PlusCodex

Codex 남은 사용량을 표시하는 개인용 macOS 메뉴 막대 앱.

OpenAI의 공식 앱이 아닌 비공식 보조 앱입니다.

- 기본 표시: Codex 기본 한도(primary)의 남은 퍼센트. 메뉴에서 기간과 주간 한도 확인.
- 공식 Codex App Server `account/rateLimits/read` 사용. 60초 자동 갱신.
- 기존 Codex 로그인 사용. 인증 토큰을 직접 읽거나 별도 저장하지 않음.
- 조회 실패 시 `--%`; 메뉴에 이전 조회 정보임을 명시.
- 다른 모델 전용 한도를 Codex 기본 한도로 대체하지 않음.
- 로그인 시 자동 실행은 설정하지 않음.
- 채팅 활동: 실행 중인 작업은 회색 글씨와 흰색 반짝임, 완료 후 미확인 작업은 기본 글자색으로 표시. 클릭하면 해당 Codex 작업으로 이동.
- 채팅 목록은 로컬 Codex 앱의 내부 IPC와 읽기 전용 SQLite 조회를 사용한다. 최근 100개 작업 및 이미 표시 중인 작업을 대상으로 하며, 앱 업데이트에 따라 호환성 확인이 필요하다. 원격 작업은 지원하지 않는다.
- 동작 줄이기 설정에서는 반짝임을 끈다. 표시할 작업이 없거나 연결이 끊기면 채팅 영역을 숨긴다.
- 새로고침은 macOS 기본 메뉴 항목이며, 선택하면 메뉴가 닫히고 사용량을 갱신한다. 단축키는 ⌘ R이다.
- 메뉴를 열 때도 사용량을 갱신한다. 이미 조회 중이면 중복 요청하지 않는다.
- 완료 채팅의 열기 요청이 성공하면 현재 앱 세션에서 해당 결과를 숨긴다. 새 실행이나 더 최신 결과가 수신되면 다시 표시한다. Codex 자체의 읽음 상태를 변경하지 않으며, 앱 재시작 후에는 Codex가 제공하는 상태를 따른다.
- 앱 아이콘은 제공된 PlusCodex 이미지를 사용한다. 메뉴 막대와 사용량 패널의 Codex 아이콘은 AI 제공자 표시로 유지한다. ‘시스템 종료’ 버튼은 이 앱만 종료한다.
- 실행 시 업데이트를 확인하고 Sparkle로 서명된 새 버전을 자동 다운로드·설치한다. 업데이트 확인 중에는 기존 로딩 배경과 로고 아래에 상태 문구를 표시한다. 네트워크가 느려도 최대 15초 후 사용량 메뉴를 사용할 수 있다.
- 메뉴의 ‘업데이트 확인…’으로 수동 확인할 수 있다. 단순 소스 커밋이 아니라 새 GitHub Release와 서명된 appcast 게시가 필요하다.
- 5시간·주간 한도별 잔여 10% 이하와 0% 소진 시 알림을 보낸다. 첫 조회부터 0%이면 소진 알림만 보내며 반복 조회·재실행 시 중복을 방지한다. 조회 주기 때문에 최대 약 60초 및 네트워크 지연이 있을 수 있다.
- 0% 소진은 API의 실제 사용률 100%를 기준으로 한다. 메뉴의 정수 내림 표시가 먼저 0%가 되어도 아직 남은 소량을 소진으로 판단하지 않는다.

## 빌드 및 실행

```sh
bash build.sh
open build/PlusCodex.app
build/PlusCodex.app/Contents/MacOS/PlusCodex --probe
```

Apple Silicon, macOS 14 이상과 설치된 Codex CLI가 필요하다. ChatGPT/Codex 앱의 내장 CLI 또는 Homebrew 설치 경로를 탐색한다.

`Sources/QuotaClient.swift`는 제한 시간 내 JSON-RPC 요청과 응답을 처리한다.
`Sources/AppDelegate.swift`는 메뉴 막대 표시, 자동 갱신, 오류 상태를 관리한다.
`Sources/AppUpdater.swift`는 Sparkle 업데이트 생명주기와 로딩 상태를 연결한다.
`Sources/QuotaAlertTracker.swift`는 알림 임계값과 중복 방지를 담당한다.
기존 CodexBar에서 아이콘만 재사용했으며 MIT 고지는 `Resources/CodexBar-LICENSE`에 포함한다.
Sparkle 2.10.0은 빌드 시 SHA-256을 검증해 받으며, 배포 앱에 라이선스를 포함한다.

전체 검증: `bash test.sh`. 배포 절차와 서명 키 보관 안내는 [UPDATES.md](UPDATES.md)를 참고한다.

공식 프로토콜: https://learn.chatgpt.com/docs/app-server

## 채팅 활동 검증

```sh
xcrun swiftc Sources/ThreadActivity.swift Sources/ThreadActivityView.swift Tests/ActivityChecks.swift -o build/ActivityChecks
build/ActivityChecks
# Codex에서 실제 실행 중인 작업이 있을 때 메뉴 추적 모드의 수신까지 검증
build/ActivityChecks --live
```
