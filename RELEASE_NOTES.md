# PlusCodex v1.1.5

- Codex 깨우기는 기존 사용량 조회의 원본 응답과 이전 관측값을 비교합니다. 예약 이후 최소 30초 간격의 두 정상 조회에서 사용량 0%와 미래 초기화 시각이 확인될 때 전송하며, 잔량이 있다는 이유만으로 실행하지 않습니다. 시간이 계속 밀리는 빈 주기는 기존 예약을 유지합니다.
- 새 초기화 시각이 안정적으로 확인되고 사용량이 발생한 경우 이미 시작된 주기로 간주해 불필요한 깨우기를 생략합니다. 전송 성공 후 활성 주기가 조회되면 로컬 계산보다 서버의 초기화 시각을 우선합니다.
- 저장된 채팅의 재사용이 전송 전에 명확하게 거절되면 새 채팅을 만들고 다음 실행을 위해 저장합니다. 기존 채팅은 삭제하지 않습니다. 전송 후 응답이 불명확한 경우에는 새 채팅으로 즉시 재전송하지 않아 중복을 방지합니다.
- 오래되거나 순서가 뒤바뀐 응답은 전송 판단에서 제외합니다. 계정 변경 시 비교 기록을 초기화하고, 주간 한도 등 조회된 한도가 소진된 경우 깨우기를 보내지 않습니다. 설정에는 마지막 깨우기 실패 사유와 다음 시도 안내를 표시합니다.
- 작업 목록 위쪽 여백을 줄여 아래쪽 간격과 균형을 맞췄습니다. 메뉴 진입 시 업데이트 확인 동작은 유지했습니다.

## English

- Automatic wake compares raw responses from existing usage refreshes with persisted observations. Sending requires two successful post-deadline reads at least 30 seconds apart showing zero usage and a future reset. Available balance alone no longer authorizes a wake; moving empty-window estimates do not continually postpone the reservation.
- A stable future reset with positive usage is treated as an already active cycle, avoiding an unnecessary wake. After a successful send, an observed active server window takes precedence over a locally calculated deadline.
- When reusing the saved chat is explicitly rejected before submission, a replacement chat is created and remembered without deleting the previous chat. Ambiguous post-submission errors do not trigger an immediate replacement send.
- Stale and out-of-order responses are rejected, account changes clear comparison history, and exhausted reported limits including the weekly window block sending. Settings show the latest wake failure and next-attempt information.
- Reduced the spacing above task rows to balance the lower gap. Update checks on menu open remain unchanged.

## 설치 및 업데이트

기존 정식 버전은 앱의 업데이트 기능으로 `v1.1.5`를 설치할 수 있습니다. 수동 설치는 [PlusCodex-1.1.5.dmg](https://github.com/hyxx-su/PlusCodex/releases/download/v1.1.5/PlusCodex-1.1.5.dmg)를 열고 PlusCodex를 Applications로 옮기세요. 기존 설정은 유지됩니다.

Apple Silicon Mac과 macOS 14 이상을 지원합니다. 이 배포본은 ad-hoc 서명되어 있으며 Apple Developer ID 서명·공증은 없습니다. PlusCodex는 OpenAI의 공식 앱이 아닙니다.

## 검증 범위 / Validation

배포 검증 대상은 전체 자동 테스트(`bash test.sh`), DMG 무결성, Sparkle 업데이트 피드·ZIP 서명과 길이입니다. 새 채팅 대체 전송은 실제 응답 완료를 확인했습니다. 실제 Mac의 짧은 잠자기·복귀 후 예약 유지를 확인했으나, 5시간 실예약 및 예약 시각을 넘긴 장시간 잠자기 후 자동 전송은 아직 검증 중입니다. 주기 전환 판단은 조회 응답에 기반한 보수적 추정이며 서버의 명시적인 초기화 완료 이벤트가 아닙니다. Mac이 꺼지거나 잠든 동안에는 실행되지 않으며, 복귀 후 앱 실행·로그인·정상 사용량 조회가 필요합니다.

Release validation covers the full automated suite, DMG integrity, and Sparkle feed/ZIP signatures and lengths. A real replacement-chat send completed successfully. A brief physical sleep/wake test preserved the reservation; a full five-hour scheduled run and catch-up after sleeping across the deadline remain under validation. Cycle detection is a conservative inference from usage responses, not an explicit server reset event. Execution requires an awake Mac, a running app, authentication, and successful usage reads.

---

# PlusCodex v1.1.4

- Codex 자동 깨우기는 요청 접수만으로 성공 처리하지 않고 실제 작업 완료를 확인한 뒤 해당 주기를 기록합니다. 명확하게 실패한 작업은 기존 15분 재시도를 사용하며, 전송 후 응답이 불명확한 경우에는 중복 전송 방지를 위한 보수적인 대기를 유지합니다.
- 사용량 조회에서 초기화 예상 시각이 뒤로 이동하더라도 이미 예약된 깨우기 시각은 계속 미뤄지지 않도록 수정했습니다. 기능을 켤 때 알려진 일정을 저장하고, 전송 직전에는 초기화 예정 시각 이후의 최신 사용량과 사용 가능 여부를 다시 확인합니다.
- 앱 재실행과 장시간 중단 후 깨우기 일정을 복구합니다. 성공 직후 앱이 종료되어 다음 조회를 받지 못한 경우에도 마지막 실행 기록을 기준으로 다음 일정을 복원하며, 놓친 주기는 한 번만 보충 시도합니다.
- 메뉴를 열어 둔 상태에서 작업 정보가 갱신될 때 기존 행을 재사용합니다. 갱신 시각만 바뀌는 조회는 아이콘과 애니메이션을 다시 그리지 않아 주기적인 깜빡임을 줄였습니다.
- 완료된 작업을 읽어 행이 사라지면 열린 메뉴의 높이도 함께 줄어듭니다. 작업 화살표와 제목의 세로 위치를 알림 버튼에 맞췄습니다.
- 작업 알림 끄기는 대화방 전체가 아닌 현재 작업에만 적용됩니다. 같은 대화방의 다음 작업은 기본적으로 알림이 켜지며, 현재 작업의 설정은 완료와 앱 재실행 후에도 유지됩니다. 이전 버전의 대화방 단위 음소거는 새 작업에 상속하지 않습니다.

## English

- Automatic Codex wake records a successful cycle only after the turn completes, rather than when the request is accepted. Explicit failures retain the 15-minute retry; ambiguous responses after submission retain conservative waiting to prevent duplicate sends.
- A later reset estimate from usage refreshes no longer postpones an already scheduled wake. Enabling the feature persists the known schedule, while sending still requires fresh post-deadline usage and available quota.
- Wake schedules recover after relaunch and extended downtime, including shutdown immediately after a successful turn before the next usage refresh. Missed cycles trigger only one catch-up attempt.
- Open menus reuse existing task rows. Timestamp-only updates no longer redraw icons or restart animations, reducing periodic flicker.
- The open menu shrinks when acknowledged tasks disappear. Task arrows and titles are vertically aligned with notification controls.
- Muting applies to the current turn instead of the whole conversation. The next turn defaults to notifications on; the current turn's choice survives completion and relaunch. Legacy conversation-wide mute settings are not inherited by new turns.

## 설치 및 업데이트

기존 정식 버전은 앱의 업데이트 기능으로 `v1.1.4`를 설치할 수 있습니다. 수동 설치는 [PlusCodex-1.1.4.dmg](https://github.com/hyxx-su/PlusCodex/releases/download/v1.1.4/PlusCodex-1.1.4.dmg)를 열고 PlusCodex를 Applications로 옮기세요. 기존 설정은 유지되지만, 작업 알림 음소거는 위의 작업별 정책으로 변경됩니다.

Apple Silicon Mac과 macOS 14 이상을 지원합니다. 이 배포본은 ad-hoc 서명되어 있으며 Apple Developer ID 서명·공증은 없습니다. PlusCodex는 OpenAI의 공식 앱이 아닙니다.

## 검증 범위 / Validation

전체 자동 검증(`bash test.sh`)과 DMG 무결성, Sparkle 업데이트 피드·ZIP 공개키 서명 및 길이를 검증합니다. 자동 깨우기는 Mac이 종료되거나 잠든 동안 실행할 수 없으며, 복귀 후 PlusCodex 실행·Codex 로그인·최신 사용량 확인이 필요합니다. 실제 다른 기기의 절전 복귀와 알림 전달은 별도 실기 확인이 필요합니다. 메뉴 진입 시 업데이트 확인 동작은 유지했습니다.

Validation covers the full automated suite (`bash test.sh`), DMG integrity, and public-key signatures and lengths of the Sparkle feed and ZIP. Automatic wake cannot run while the Mac is shut down or asleep; recovery requires PlusCodex running, Codex authentication, and fresh usage. Sleep recovery and notification delivery on other devices still require device testing. Update checks on menu open remain unchanged.

---

# PlusCodex v1.1.3

- 사용량과 작업 완료·읽음 기록을 계정별로 분리했습니다. 계정 전환 중 이전 계정의 늦은 조회 결과가 새 계정 화면에 반영되지 않으며, 읽은 완료 항목이 앱 재실행 뒤 다시 나타나는 현상을 줄였습니다.
- Codex 작업 상태 연결이 끊기거나 응답이 늦는 경우 복구 구독을 다시 시도합니다. 확인되지 않은 작업은 실행 또는 읽음 완료로 단정하지 않고, 장시간 응답이 없는 행은 메뉴에서 정리한 뒤 새 상태를 받으면 다시 표시합니다. 완료 항목의 읽음 상태는 이벤트와 짧은 재확인 주기로 동기화합니다.
- 사용량 초기화 알림에 계정·주기별 예약 장부를 추가했습니다. 조회 때마다 바뀌는 초기화 시각에 같은 주기의 알림을 반복 예약하지 않으며, 확인된 주기 변경은 알림과 자동 깨우기 일정에 함께 반영합니다.
- 자동 깨우기는 계정 전환과 오래된 전송 결과를 확인하고, 저장된 Codex 대화방을 재사용합니다. 새 사용량 주기와 예약 상태는 재실행 후에도 복구합니다.
- Claude와 Grok 사용량 조회는 계정 변경이나 설정 토글 전에 시작한 오래된 결과를 폐기합니다. 일시적인 네트워크 제한은 로그아웃으로 오인하지 않고 재시도 대기와 최근 사용량 표시를 유지합니다. Claude 플랜 미보유와 구독 확인 실패 안내를 구분합니다.
- 알림음 예약을 취소하거나 테스트를 다시 보내면 해당 예약도 함께 정리합니다. 사용자 지정 음원의 길이·음량 변환은 백그라운드에서 처리하고 마지막 설정만 적용해 설정 화면이 멈추는 일을 줄였습니다.
- 상태 복구·중복 알림·계정 경계를 검사 목록에 추가하고 Sparkle 준비 중 빌드 경합을 막았습니다. 메뉴 진입 시 업데이트 확인 동작은 유지했습니다.

## English

- Usage and task completion/read receipts are now scoped by account. Late results from a previous sign-in are discarded, and acknowledged tasks are less likely to reappear after relaunch.
- Codex activity subscriptions recover after disconnects and delayed responses. Unknown tasks are not treated as running or read; rows without a response are eventually hidden and return when a fresh state arrives. Read state for completed tasks is synchronized from events and a short retry interval.
- Reset notifications use a persistent ledger keyed by account and usage cycle. Repeated usage refreshes no longer schedule duplicate alerts for the same cycle, and confirmed reset changes update both notification and automatic-wake schedules.
- Automatic wake validates account changes and stale send results, reuses the saved Codex conversation, and restores its schedule after relaunch.
- Claude and Grok discard usage results started before an account or setting change. Temporary network throttling preserves retry timing and recent usage instead of appearing as sign-out. Claude plan requirements are distinguished from subscription lookup failures.
- Cancelling or retrying a sound test also releases its reservation. Custom sound conversion runs in the background and applies only the latest duration and volume settings.
- Added checks for recovery, duplicate notifications, and account boundaries, and prevented build races while preparing Sparkle. The existing update check on menu open is retained.

## 설치 및 업데이트

기존 정식 버전은 앱의 업데이트 기능으로 `v1.1.3`을 설치할 수 있습니다. 수동 설치는 [PlusCodex-1.1.3.dmg](https://github.com/hyxx-su/PlusCodex/releases/download/v1.1.3/PlusCodex-1.1.3.dmg)를 열고 PlusCodex를 Applications로 옮기세요. 기존 설정은 유지됩니다.

Apple Silicon Mac과 macOS 14 이상을 지원합니다. 이 배포본은 ad-hoc 서명되어 있으며 Apple Developer ID 서명·공증은 없습니다. PlusCodex는 OpenAI의 공식 앱이 아닙니다.

## 검증 범위 / Validation

전체 자동 검증(`bash test.sh`)이 통과했습니다. DMG 무결성 검사와 Sparkle 업데이트 피드·ZIP의 공개키 서명 및 길이 검증도 통과했습니다. 실제 절전 복귀와 macOS 알림 전달·재생은 OS 권한, 집중 모드 및 기기 상태에 따라 달라져 별도 실기 확인이 필요합니다. Claude Desktop 캐시와 현재 로그인 조직의 일치 여부는 이번 릴리즈에서 보장하지 않습니다. 메뉴 진입 시 업데이트 확인 동작은 기존대로 유지했습니다.

The full automated suite (`bash test.sh`) passed. DMG integrity and public-key verification of the Sparkle feed and ZIP archive also passed. Actual sleep/wake recovery and macOS notification delivery/playback require device testing because they depend on OS permissions, Focus, and device state. This release does not guarantee that a Claude Desktop cache belongs to the currently signed-in organization. The existing update check on menu open remains unchanged.

---

# PlusCodex v1.1.2

## English

- Stabilized Codex reset scheduling so notifications and automatic wake do not chase a reset timestamp that slides on each usage refresh. Confirmed schedule corrections and account changes are synchronized, while pending-cycle and retry state survive app relaunch.
- Automatic wake now requires a fresh post-reset usage check and available quota. A cycle is recorded only after the Codex server accepts the turn; duplicate sends for a completed cycle and retries after ambiguous connection failures are prevented.
- Usage and chat activity continue updating while the menu bar is open. Percentages and bars transition smoothly, account changes do not inherit the previous account's animation, and the activity section stays hidden when there is no work.
- Each chat has a circular notification control for muting or enabling its completion, failure, and attention notifications. Active work uses a synchronized shimmer across the title and notification icon.
- Usage is refreshed shortly after task completion, with simultaneous completions batched to avoid unnecessary requests. Recent usage is retained for up to 10 minutes during transient lookup failures; older data switches to the error screen.
- Improved handling of large Codex thread snapshots and restored activity subscriptions after IPC connection resets to reduce missing menu-bar activity.

## 설치 및 업데이트

기존 정식 버전은 앱의 업데이트 기능으로 `v1.1.2`를 설치할 수 있습니다. 수동 설치는 [PlusCodex-1.1.2.dmg](https://github.com/hyxx-su/PlusCodex/releases/download/v1.1.2/PlusCodex-1.1.2.dmg)를 열고 PlusCodex를 Applications로 옮기세요. 기존 설정은 유지됩니다.

Apple Silicon Mac과 macOS 14 이상을 지원합니다. 이 배포본은 ad-hoc 서명되어 있으며 Apple Developer ID 서명·공증은 없습니다. PlusCodex는 OpenAI의 공식 앱이 아닙니다.

## 검증 범위 / Validation

전체 자동 검증(`bash test.sh`)이 통과했습니다. DMG 무결성 검사와 Sparkle 업데이트 피드·아카이브의 공개키 서명 및 길이 검증도 통과했습니다. macOS 알림 배너는 알림 권한과 집중 모드 설정의 영향을 받으며, 자동 깨우기는 Codex 로그인·앱 실행·사용량 갱신 상태에 따라 동작합니다.

The full automated suite (`bash test.sh`) passed. DMG integrity and public-key verification of the Sparkle feed/archive signatures and byte lengths also passed. macOS notification banners depend on notification permissions and Focus settings; automatic wake requires Codex sign-in, a running app, and refreshed usage.

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
