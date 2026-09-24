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
Claude/Grok은 해당 CLI 설치 및 로그인이 필요합니다. 기존 로그인·알림·자동 실행 설정은 유지됩니다.

이 빌드는 ad-hoc 서명이며 Apple Developer ID 서명·공증은 없습니다.
OpenAI의 공식 앱이 아닌 비공식 보조 앱입니다.

## 검증 범위 / Validation

알림 배너와 사용자 지정 소리의 실제 재생 시간은 macOS 알림 권한·집중 모드·알림 스타일의 영향을 받습니다. 자동 깨우기는 Codex 로그인과 사용량 조회, 앱 실행 상태에 따라 동작하며 Codex 사용량을 소모합니다.
Notification banners and custom-sound playback depend on macOS permissions, Focus, and alert style. Auto wake requires a Codex login, a fresh usage check, and a running PlusCodex app; it consumes Codex usage.
