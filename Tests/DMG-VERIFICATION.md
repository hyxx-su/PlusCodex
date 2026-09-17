# DMG Finder 검증 (2026-09-17)

## 수정 및 관찰

- 기존 v2는 Finder에서 배경이 없고 아이콘 크기 48/글자 12로 표시됨.
- Notion DMG 및 dmgbuild의 `icvp`와 비교해 누락된 `backgroundColorRed/Green/Blue`를 확인.
- RGB 필드만 추가한 v3에서 실제 Finder 배경과 아이콘 88/글자 13 적용을 확인.
- AppleScript `background picture`는 정상 배경을 표시하는 경우에도 `missing value`를 반환하므로 시각 검증을 대체하지 못함.
- v3 별칭은 동시에 마운트된 같은 이름의 v2로 해석되어 정확한 경로 검사에 실패. 이전 볼륨을 임의 추출하지 않고 새 볼륨 이름을 `PlusCodex Setup`으로 구분.
- 그림은 720×460 유지. 제목/경로 막대 때문에 아래 안내가 잘려 Finder 창을 720×520으로 확장.

## 최종 확인

- 파일: `/Users/user/Downloads/PlusCodex-Installer-v4.dmg`
- 마운트: `/Volumes/PlusCodex Setup`
- 실제 Finder 창 캡처: `build/dmg-v4-finder.png` (빌드 산출물, Git 제외)
- 배경 제목, 앱/Applications 아이콘, 웃는 얼굴/화살표, 하단 안내 두 줄 모두 표시 확인.
- DMG 체크섬, 재마운트한 자체 배경 별칭, Applications 심볼릭 링크, 보이는 파일 2개, 앱 서명 검사 통과.
- 다른 Mac 최초 실행 시 메뉴바 미표시 문제는 이번 변경 대상이 아니며 해결 여부 미검증.

## 아이콘 중앙 정렬 후속 수정

- 사용자 피드백에 따라 아이콘+이름 묶음을 카드 중앙에 배치하도록 두 `Iloc` Y 좌표를 224 → 250으로 이동.
- 결과: `/Users/user/Downloads/PlusCodex-Installer-v5.dmg`
- 실제 Finder 창 캡처 `build/dmg-v5-finder.png`에서 중앙 정렬과 배경/안내 표시 확인.
- v5 DMG 체크섬 확인 통과. 동일 이름의 기존 볼륨을 유지했으므로 v5 자체 별칭 경로 검사는 재실행하지 않음 (위 별칭/서명 검사 결과는 v4 기준).

## 다음 배포 시

```sh
bash package-dmg.sh /absolute/path/new-unique-name.dmg
hdiutil attach /absolute/path/new-unique-name.dmg -nobrowse
build/dmg-tools/bin/python Tests/DMGLayoutChecks.py '/Volumes/PlusCodex Setup'
```

실제 마운트 경로를 사용한다. 같은 볼륨 이름의 이전 설치본이 열려 있으면 별칭이 이전 이미지로 해석될 수 있다. 검사 실패를 무시하지 말고 사용자의 허락 없이 기존 디스크를 추출하지 않는다.

마지막으로 최종 DMG를 Finder에서 열고 **창 화면**을 캡처해 확인한다. 배경 원본 미리보기나 메타데이터 검사 통과만으로 디자인 성공으로 판단하지 않는다. 사용자 다른 화면이 포함되지 않도록 `screencapture -l <Finder 창 ID>`로 창만 캡처한다.
