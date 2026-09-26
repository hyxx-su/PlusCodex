# PlusCodex v1.1.1

- Codex에서 완료 작업을 읽음 처리하면 메뉴바의 완료 작업 항목도 함께 사라지도록 읽음 상태 동기화를 보완했습니다. 새 작업이 생기면 다시 표시됩니다.
- 완료 이벤트와 읽음 이벤트가 동시에 도착하는 경우에도 메뉴바 작업 목록이 잘못 되살아나지 않도록 처리 순서를 안정화했습니다.

## English

- Improved read-state synchronization so a completed task disappears from the menu bar after it is read in Codex, and appears again when the thread receives new work.
- Stabilized event ordering so a menu-bar task is not incorrectly restored when completion and read events arrive together.

# PlusCodex v1.1.0

- Codex 앱 업데이트로 내장 CLI 실행 파일의 경로가 변경되어 PlusCodex가 Codex를 찾지 못하고 사용량 조회와 자동 깨우기에 연결하지 못하던 문제를 수정했습니다. 현재·이전 앱 내부 경로와 별도로 설치된 CLI를 순서대로 확인합니다.
- Claude는 Desktop 또는 CLI에서 확인 가능한 구독 사용량을 조회합니다. Grok은 CLI 설치·로그인과 사용량 조회 성공을 확인한 뒤에만 메뉴바 표시를 켭니다.
- Claude/Grok이 미설치이거나 구독 사용량을 확인할 수 없는 상태에서는 설정 스위치를 끕니다. 확인된 무료 계정이나 사용량을 제공하지 않는 계정도 표시하지 않습니다. 모든 서비스 항목이 숨겨지면 작은 PlusCodex 설정 아이콘을 남깁니다.
- Codex 로그아웃·재로그인으로 로그인 정보가 바뀌면 이전 조회 결과를 버리고 새 계정의 사용량을 다시 조회합니다.
- Claude 설정 안내 문구를 `클로드 코드 구독을 활성화하세요.`로 명확히 했습니다.
- 메뉴바 팝업이 사용량 갱신 중 즉시 닫히거나 활동 행의 호버 상태가 남는 문제를 수정했습니다.
- 사용자 지정 알림음 재생 시간을 음원 길이 내에서 1~15초로 선택하고, 음량을 최대 200%까지 설정할 수 있습니다. 슬라이더를 움직이는 동안 퍼센트가 즉시 표시됩니다. 음량 기본값은 100%이며, 높은 음량에서는 소리가 클리핑될 수 있습니다.

## English

- Fixed a connection failure after a Codex app update changed the bundled CLI executable path. PlusCodex now checks current and legacy app paths, then separately installed CLIs, for usage checks and automatic wake.
- Claude can read available subscription usage from Desktop or the CLI. Grok appears in the menu bar only after its CLI, sign-in, and displayable usage have been verified.
- Settings keep Claude and Grok off when they are not installed or subscription usage is unavailable, including confirmed free or non-reporting accounts. A small PlusCodex settings icon remains when all provider items are hidden.
- When Codex sign-in changes, PlusCodex discards an in-flight result from the previous account and refreshes usage for the new sign-in.
- Clarified the Claude settings guidance to “Activate a Claude Code subscription.”
- Fixed the menu bar popup closing immediately during a usage refresh and the activity row remaining hovered.
- Custom notification sounds can play for 1–15 seconds, up to the source's length, and volume can be set up to 200%. The percentage updates as you drag the slider. Volume defaults to 100%; higher volume may cause clipping.

# PlusCodex v1.0.9

- Codex 5시간 사용량 초기화 시 자동으로 메시지를 보내 깨우는 기능을 추가했습니다. 기본값은 꺼짐이며, 모델·메시지를 설정할 수 있습니다. 기본 메시지는 `Wake up`이고 같은 채팅을 재사용합니다.
- 사용량 초기화 예정 시각이 변경되면 알림 예약과 자동 깨우기 일정을 최신 시각에 맞춰 갱신합니다. 앱 재실행·잠자기 복귀 후에도 예약을 다시 확인합니다.
- 업데이트 알림을 클릭하면 GitHub 릴리즈 대신 앱의 업데이트 창을 엽니다.
- 알림 설정에서 일부 스위치와 선택 버튼이 클릭되지 않던 문제를 수정했습니다.

## English

- Added an optional Codex wake message at the five-hour usage reset. Choose a model and message; the default message is `Wake up`, and subsequent messages reuse the same chat.
- Resynchronize reset notifications and wake timing when the reported reset time changes, including after app relaunch or waking from sleep.
- Clicking an update notification now opens the in-app update window instead of the GitHub release page.
- Fixed notification settings switches and pickers that sometimes did not respond to clicks.

## 설치 및 업데이트

기존 정식 버전 사용자는 앱의 업데이트 기능으로 설치할 수 있습니다. 다운로드·서명 검증·설치는 기존 Sparkle 방식으로 진행하며 필요하면 재실행을 안내합니다.
처음 설치한다면 DMG에서 PlusCodex를 Applications로 옮겨 실행하세요.
Apple Silicon Mac, macOS 14 이상을 지원합니다. 베타 빌드의 자동 업데이트는 비활성화되어 있으므로 베타 사용자는 정식 DMG를 수동 설치하세요.
Claude 사용량은 Desktop 또는 CLI의 유효한 정보로 조회합니다. Grok 사용량 표시는 Grok CLI 설치와 로그인 및 사용량 확인이 필요합니다. 기존 로그인·알림·자동 실행 설정은 유지됩니다.

이 빌드는 ad-hoc 서명이며 Apple Developer ID 서명·공증은 없습니다.
OpenAI의 공식 앱이 아닌 비공식 보조 앱입니다.

## 검증 범위 / Validation

알림 배너와 사용자 지정 소리의 실제 재생 시간은 macOS 알림 권한·집중 모드·알림 스타일의 영향을 받습니다. 자동 깨우기는 Codex 로그인과 사용량 조회, 앱 실행 상태에 따라 동작하며 Codex 사용량을 소모합니다.
Notification banners and custom-sound playback depend on macOS permissions, Focus, and alert style. Auto wake requires a Codex login, a fresh usage check, and a running PlusCodex app; it consumes Codex usage.
