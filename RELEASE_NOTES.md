# PlusCodex v1.0.7

- 일반·AI 표시·알림 설정의 섹션과 간격을 통일하고 언어 선택 팝업을 개선했습니다.
- 설정 검색 결과에서 해당 항목으로 이동하며, 설정을 다시 열면 검색어가 초기화됩니다.
- 모든 AI의 사용량을 남은 양 또는 사용한 양으로 표시할 수 있습니다.
- 작업 완료·사용량 부족·초기화·업데이트·승인 요청 알림을 개별 설정할 수 있습니다.
- Codex 파일·명령·권한 승인 요청 감지와 중복 알림 처리를 개선했습니다.
- 알림 클릭 시 설정 창이 자동으로 열리던 동작을 제거했습니다. 작업 알림은 해당 Codex 작업으로 연결됩니다.
- 설정 하단에 버전·제작자 링크를 추가하고 한국어·영어 문구와 DMG 숨김 파일 배치를 개선했습니다.

## English

- Refined settings sections, spacing, search navigation, and the language picker.
- Settings search resets when reopened. Updated Korean and English text.
- Added a shared option to show used or remaining usage for all AI providers.
- Added individual controls for completion, low usage, reset, update, and approval notifications.
- Improved detection and deduplication of Codex command, file, and permission approval requests.
- Removed automatic settings opening when clicking a notification. Task notifications link to the corresponding Codex task.
- Added version and author links and improved hidden-file placement in the DMG.

## 설치 및 업데이트

기존 정식 버전 사용자는 앱의 업데이트 기능으로 설치할 수 있습니다. 다운로드·서명 검증·설치는 기존 Sparkle 방식으로 진행하며 필요하면 재실행을 안내합니다.
이번 버전을 설치하기 전까지는 기존 버전의 업데이트 화면·설치 방식이 적용됩니다.
처음 설치한다면 DMG에서 PlusCodex를 Applications로 옮겨 실행하세요.
Apple Silicon Mac, macOS 14 이상을 지원합니다. 베타 빌드의 자동 업데이트는 비활성화되어 있으므로 베타 사용자는 정식 DMG를 수동 설치하세요.
Claude/Grok은 해당 CLI 설치 및 로그인이 필요합니다. 기존 로그인·알림·자동 실행 설정은 유지됩니다.

이 빌드는 ad-hoc 서명이며 Apple Developer ID 서명·공증은 없습니다.
OpenAI의 공식 앱이 아닌 비공식 보조 앱입니다.

## 검증 범위 / Validation

알림 배너와 작업 이동 동작은 macOS 알림 설정 및 Codex 내부 연동 규격의 영향을 받습니다.
Notification presentation and task navigation depend on macOS settings and the Codex desktop integration protocol.
