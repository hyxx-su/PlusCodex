# PlusCodex v1.0.8

- 알림음 파일을 저장·선택·삭제하고 MP3, M4A, WAV 등 지원 음원을 사용할 수 있습니다.
- 사용자 지정 알림음의 음량과 재생 시간을 설정하고 실제 알림으로 테스트할 수 있습니다. 재생 시간은 음원 길이에 따라 최대 10초까지 선택할 수 있습니다.
- 답변 요청, MCP 확인 요청, 연결된 앱 승인 요청, 작업 실패 알림을 추가하고 각 알림을 개별 설정할 수 있습니다.
- 알림 설정의 스크롤·간격·선택 메뉴를 정리하고, Claude Code와 Grok은 새 설치 시 기본적으로 꺼두었습니다. 기존 선택은 유지됩니다.

## English

- Save, choose, and remove custom notification sounds, including MP3, M4A, and WAV files.
- Set volume and playback duration for custom sounds and test them with a notification. Available durations depend on the file length and are capped at 10 seconds.
- Added separate notifications for answer requests, MCP confirmations, connected-app approvals, and failed Codex tasks.
- Refined notification settings scrolling, spacing, and pickers. Claude Code and Grok start disabled for new installs; existing choices remain unchanged.

## 설치 및 업데이트

기존 정식 버전 사용자는 앱의 업데이트 기능으로 설치할 수 있습니다. 다운로드·서명 검증·설치는 기존 Sparkle 방식으로 진행하며 필요하면 재실행을 안내합니다.
처음 설치한다면 DMG에서 PlusCodex를 Applications로 옮겨 실행하세요.
Apple Silicon Mac, macOS 14 이상을 지원합니다. 베타 빌드의 자동 업데이트는 비활성화되어 있으므로 베타 사용자는 정식 DMG를 수동 설치하세요.
Claude/Grok은 해당 CLI 설치 및 로그인이 필요합니다. 기존 로그인·알림·자동 실행 설정은 유지됩니다.

이 빌드는 ad-hoc 서명이며 Apple Developer ID 서명·공증은 없습니다.
OpenAI의 공식 앱이 아닌 비공식 보조 앱입니다.

## 검증 범위 / Validation

알림 배너와 사용자 지정 소리의 실제 재생 시간은 macOS 알림 권한·집중 모드·알림 스타일의 영향을 받습니다. Codex 요청 감지는 데스크톱 앱의 내부 연동 규격에 의존합니다.
Notification banners and custom-sound playback depend on macOS permissions, Focus, and alert style. Codex request detection depends on the desktop integration protocol.
