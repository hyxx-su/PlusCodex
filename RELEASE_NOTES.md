# PlusCodex v1.0.6

- README 상단에 한국어 / English 링크를 추가하고 영문 README를 제공합니다.
- 설정에 언어 선택을 추가했습니다. 기본값은 한국어이며 English로 변경할 수 있습니다.
- 언어 변경은 PlusCodex를 종료한 뒤 다시 실행하면 적용됩니다. macOS나 다른 앱의 언어는 변경하지 않습니다.
- 메뉴·설정·로딩·오프라인 안내·사용량 한도·알림·앱 자체 오류 문구를 영어로 제공합니다. 업데이트 창도 앱의 언어 설정을 따릅니다.
- 채팅 제목·이메일·서버 응답 및 릴리즈 노트 원문은 자동 번역하지 않습니다.

## English

- Added Korean / English links and an English README.
- Added a language selector in Settings. Korean is the default; English is available.
- Quit and reopen PlusCodex to apply the selected language. Your macOS language is not changed.
- Localized menus, settings, loading/offline messages, usage labels, notifications, and app-generated errors. The update dialog follows the app language.
- Chat titles, email addresses, server-provided text, and release notes are not automatically translated.

## 설치 및 업데이트

기존 정식 버전 사용자는 앱의 업데이트 기능으로 설치할 수 있습니다. 다운로드·서명 검증·설치는 기존 Sparkle 방식으로 진행하며 필요하면 재실행을 안내합니다.
이번 버전을 설치하기 전까지는 기존 버전의 업데이트 화면·설치 방식이 적용됩니다.
처음 설치한다면 DMG에서 PlusCodex를 Applications로 옮겨 실행하세요.
Apple Silicon Mac, macOS 14 이상을 지원합니다. 베타 빌드의 자동 업데이트는 비활성화되어 있으므로 베타 사용자는 정식 DMG를 수동 설치하세요.
Claude/Grok은 해당 CLI 설치 및 로그인이 필요합니다. 기존 로그인·알림·자동 실행 설정은 유지됩니다.

이 빌드는 ad-hoc 서명이며 Apple Developer ID 서명·공증은 없습니다.
OpenAI의 공식 앱이 아닌 비공식 보조 앱입니다.

## 검증 범위 / Validation

요청에 따라 자동 테스트 및 UI 테스트는 실행하지 않았습니다. 배포 빌드와 패키지 서명 검증만 수행합니다.
Automated and UI tests were not run for this release. Validation is limited to the release build and package signatures.
