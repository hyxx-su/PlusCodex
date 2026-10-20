# PlusCodex PR 검증

## 실행 흐름

`main` 대상 PR 생성·변경과 `main` 푸시에서 `PlusCodex CI`를 실행합니다.
`workflow_dispatch`를 통한 수동 실행도 지원합니다.

1. `macOS Build`: 스크립트·리소스 검사, Apple Silicon 앱 빌드, ad-hoc 서명 검증
2. `Tests`: core / notifications / activity / settings 그룹의 기존 회귀 테스트 실행
3. `CI Gate`: 빌드와 모든 테스트가 성공했을 때만 통과

macOS 작업은 `macos-15`에서 실행합니다. AppKit 테스트는 러너의 데스크톱 환경에
영향을 받을 수 있으며, 실제 계정·손쉬운 사용 권한·알림 배너 검증을 대체하지 않습니다.
앱 서명 검증은 개발용 ad-hoc 서명이며 Developer ID 서명·공증은 아닙니다.

워크플로는 저장소 읽기 권한만 사용하고 서명 키나 사용자 계정을 전달하지 않습니다.
PR 코드는 `pull_request`에서 실행하며 `pull_request_target`은 사용하지 않습니다.
DMG·업데이트 피드 생성, GitHub Release 게시와 자동 병합은 수행하지 않습니다.

## 로컬 실행

```sh
bash build.sh
bash test.sh
bash test.sh MenuBarFormatChecks SettingsTextEditingChecks
```

### 로컬 앱 서명

`build.sh`는 로컬 Keychain에 유효한 Apple Development 인증서가 하나 있으면 이를
자동 선택합니다. 고정 인증서의 기본 서명 요건을 사용해 로컬 앱 교체 때마다 TCC의
권한 연결이 끊기는 문제를 방지합니다. 인증서·개인 키를 저장소에 복사하지 않습니다.

- `CI` 환경에서는 기본적으로 ad-hoc 서명을 유지합니다.
- 로컬 인증서가 없으면 경고 후 ad-hoc 서명하며, 교체 후 권한 재허용이 필요할 수 있습니다.
- 인증서가 여러 개면 자동 선택하지 않고 빌드 전에 오류로 종료합니다.
- `PLUSCODEX_SIGN_IDENTITY`로 인증서 이름·지문을 지정할 수 있습니다. `-`는 명시적 ad-hoc 선택입니다.
- 기존 ad-hoc 앱에서 인증서 서명으로 전환하는 첫 교체에는 권한 재등록이 필요할 수 있습니다.
- Apple Development 서명은 개발용이며 배포용 Developer ID 서명·공증을 대신하지 않습니다.

인수가 없으면 기존 전체 테스트를 실행합니다. 이름을 지정하면 기본 목록에서 해당
테스트만 실행하며, 잘못된 이름이나 실제 계정이 필요한 별도 테스트는 거부합니다.
테스트를 추가할 때는 `test.sh`의 기본 목록과 워크플로의 그룹을 함께 갱신합니다.

## main 보호 정책

저장소의 브랜치 보호 설정에서 다음 정책을 적용합니다. 이 문서 자체가 원격 설정을
변경하는 것은 아닙니다.

- PR 경유 필수, 필수 승인자 수는 0명
- GitHub Actions의 `CI Gate` 성공 필수
- 병합 전 최신 `main` 반영 필수
- 리뷰 대화 해결 필수
- 관리자에게도 동일하게 적용
- 강제 푸시와 브랜치 삭제 금지

필수 검사 이름을 바꾸면 GitHub의 보호 설정도 함께 갱신해야 합니다. 실패한 검사를
우회하기 위해 보호를 해제하지 말고 실패 원인을 수정한 뒤 재실행합니다.
CI 설정의 롤백은 해당 커밋을 되돌리되, 필수 검사와 워크플로가 불일치하지 않도록
원격 보호 설정도 별도 검토해야 합니다.
