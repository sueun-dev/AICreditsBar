<div align="center">

# AICreditsBar

**How much of your Codex and Claude plan limits is left — in the macOS menu bar.**

![macOS 11+](https://img.shields.io/badge/macOS-11%2B-111?logo=apple&logoColor=white)
![Swift 5](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)
![Official data only](https://img.shields.io/badge/data-official%20APIs%20only-2EA043)
![License: MIT](https://img.shields.io/badge/License-MIT-3B82F6)

<img src="docs/images/menu.png" width="312" alt="Menu bar and dropdown, rendered by the app with live data">

**[English](#english) · [한국어](#한국어)**

</div>

---

## English

A small native menu-bar app. Each provider's mark sits in a thin ring that fills with the
remaining % of the limit you'll hit first. Hover for the exact numbers; click for every
limit, its reset countdown, and your plan.

### Where the numbers come from

| Provider | Source | Signed in with |
|---|---|---|
| **Codex** | `chatgpt.com/backend-api/wham/usage` | your Codex CLI login (`~/.codex/auth.json`) |
| **Claude** | `api.anthropic.com/api/oauth/usage` | your Claude Code login (macOS Keychain) |

These are the official usage endpoints — the same numbers as Codex's `/status` and
Claude Code's `/usage`. Nothing is estimated:

- Each plan limit is shown as the provider reports it. Codex windows are named by their real
  length (a Pro plan currently has a single 7-day window, so there is no 5-hour row).
  Claude's per-model weekly limits (e.g. *Weekly (Fable)*) get their own row. Codex's separate
  code-review limit isn't shown.
- If a refresh fails, the last reading stays visible but greyed, with its age and the reason.
- A window whose reset time has passed shows **—** until the next reading. It is never
  assumed to be back at 100%.
- Not signed in, or a login expired? The menu says so and shows no numbers.

### The menu bar

- One ring per provider. It shows the **lowest remaining** limit by default (Settings can
  pin it to the 5-hour or weekly window). Per-model limits are left out of the ring.
- Drawn in the menu bar's own text color while healthy, **orange** below 30 %, **red**
  below 10 %, faded when the reading isn't current. Thresholds are adjustable.
- Checks every 5 minutes, when the menu opens (at most every 2 minutes), and after the Mac
  wakes. The usage endpoints rate-limit hard — Anthropic's especially — so a service that
  answers HTTP 429 is left alone for 5, 10, 20, then 30 minutes.
- The last good reading is saved, so after a restart it shows right away (faded, with its
  age) until a fresh one arrives.

### Requirements

- macOS 11 or later, Intel or Apple Silicon.
- Xcode Command Line Tools for `swiftc` (`xcode-select --install`).
- The Codex CLI and/or Claude Code, signed in with a ChatGPT / Claude plan.

### Build & run

```bash
bash build.sh          # compile Sources/*.swift → AICreditsBar.app
open AICreditsBar.app  # menu-bar only, no Dock icon
```

Start at login: `bash scripts/install-login-item.sh` (remove with `-u`); it also brings the
app back if it ever crashes. macOS ties a login item to the exact ad-hoc-signed build, so
`build.sh` re-registers it — and restarts the app — after every rebuild.

### Command line

```bash
B=./AICreditsBar.app/Contents/MacOS/aicreditsbar
$B --once                     # check every limit now (live requests), print, exit
$B --dump-config              # settings, then the same report
$B --render-preview menu.png  # the menu bar + dropdown as the app last saw them, as a PNG
$B --render-settings out.png  # the Settings window as a PNG
$B --settings                 # open Settings (launches the app if needed)
```

### Privacy

The app reads the two logins above locally and sends each only to its own provider's
usage endpoint. No telemetry, no other servers, no cookies or cache written to disk.
If macOS asks whether it may read "Claude Code-credentials" from the Keychain, choose
**Always Allow** (Claude Code normally stores it in a way that needs no prompt).

### Project structure

```
Sources/
  Codex.swift          Codex login + usage API + parsing
  Claude.swift         Claude Code login + usage API + parsing
  Models.swift         UsageWindow, Reading, ProviderState
  Support.swift        formatting, JSON, HTTP and Keychain helpers
  RefreshController.swift  background checks, one request per provider at a time
  Rendering.swift      menu-bar rings, colors, provider marks
  ProviderCardView.swift   the dropdown cards
  AppDelegate.swift    status item and menu
  Settings.swift       Settings window
  Config.swift         settings storage
  CLI.swift / Preview.swift / main.swift
Tests/                 unit + end-to-end tests: bash Tests/run.sh
scripts/               install-login-item.sh
```

`bash Tests/run.sh` builds throwaway binaries, runs the unit tests (including real API
replies as fixtures) and an end-to-end pass in a scratch `HOME` with no Keychain access. It
never touches the installed app or your settings.

### License

MIT — see [LICENSE](LICENSE).

---

## 한국어

Codex와 Claude 요금제 한도가 얼마나 남았는지 macOS 메뉴바에 보여주는 작은 네이티브 앱입니다.
각 서비스 아이콘을 감싼 얇은 링이 **가장 먼저 닿을 한도의 남은 %** 만큼 채워집니다. 마우스를
올리면 정확한 숫자, 클릭하면 모든 한도와 리셋까지 남은 시간, 요금제를 보여줍니다.

### 숫자의 출처

| 서비스 | 출처 | 로그인 |
|---|---|---|
| **Codex** | `chatgpt.com/backend-api/wham/usage` | Codex CLI 로그인 (`~/.codex/auth.json`) |
| **Claude** | `api.anthropic.com/api/oauth/usage` | Claude Code 로그인 (macOS 키체인) |

두 서비스의 공식 사용량 API이며, Codex의 `/status`, Claude Code의 `/usage`와 같은 숫자입니다.
추정치는 없습니다.

- 요금제 한도는 서비스가 보고한 그대로 표시합니다. Codex 창 이름은 실제 길이로 정합니다
  (현재 Pro 요금제는 7일 창 하나뿐이라 5시간 줄이 없습니다). Claude의 모델별 주간 한도
  (예: *Weekly (Fable)*)는 별도 줄로 보여줍니다. Codex의 별도 코드리뷰 한도는 표시하지 않습니다.
- 갱신에 실패하면 마지막 값을 회색으로 남기고, 몇 분 전 값인지와 실패 이유를 표시합니다.
- 리셋 시각이 지난 창은 새 값을 받을 때까지 **—** 로 표시합니다. 100%로 가정하지 않습니다.
- 로그인이 없거나 만료되면 그렇게 알려주고 숫자는 표시하지 않습니다.

### 메뉴바

- 서비스마다 링 하나. 기본값은 **가장 적게 남은 한도**이며, 설정에서 5시간/주간 창으로
  고정할 수 있습니다. 모델별 한도는 링에서 제외합니다.
- 여유가 있으면 메뉴바 글자색, 30% 미만 **주황**, 10% 미만 **빨강**, 최신 값이 아니면 흐리게.
  기준값은 설정에서 바꿀 수 있습니다.
- 5분마다, 메뉴를 열 때(최대 2분에 한 번), 잠자기에서 깨어날 때 확인합니다. 사용량 API는
  호출 제한이 엄격해서(특히 Anthropic) HTTP 429를 받으면 그 서비스는 5→10→20→30분 쉽니다.
- 마지막 정상 값을 저장해 두어, 재시작 직후에도 (흐리게, 몇 분 전 값인지와 함께) 바로 보여줍니다.

### 요구 사항

- macOS 11 이상 (Intel / Apple Silicon).
- `swiftc`용 Xcode Command Line Tools (`xcode-select --install`).
- ChatGPT/Claude 요금제로 로그인한 Codex CLI 또는 Claude Code.

### 빌드 & 실행

```bash
bash build.sh          # Sources/*.swift 컴파일 → AICreditsBar.app
open AICreditsBar.app  # 메뉴바 전용 (Dock 아이콘 없음)
```

로그인 시 자동 실행: `bash scripts/install-login-item.sh` (제거는 `-u`, 앱이 비정상 종료되면 다시 띄움). macOS는 로그인 항목을
등록 당시의 ad-hoc 서명 빌드에 묶어두기 때문에, `build.sh`가 재빌드 후 다시 등록하고 앱을
재시작합니다.

### 커맨드라인

```bash
B=./AICreditsBar.app/Contents/MacOS/aicreditsbar
$B --once                     # 모든 한도를 지금 조회(실제 요청)해 출력하고 종료
$B --dump-config              # 설정 출력 후 같은 보고
$B --render-preview menu.png  # 앱이 마지막으로 받은 값으로 메뉴바 + 드롭다운을 PNG 렌더
$B --render-settings out.png  # 설정 창을 PNG로 렌더
$B --settings                 # 설정 창 열기 (필요하면 앱 실행)
```

### 개인정보

위 두 로그인 정보를 로컬에서 읽어 각 서비스의 사용량 API에만 보냅니다. 텔레메트리, 다른 서버,
디스크에 쓰는 쿠키·캐시가 없습니다. macOS가 키체인의 "Claude Code-credentials" 접근을 물으면
**항상 허용**을 선택하세요 (보통 Claude Code가 묻지 않아도 되게 저장합니다).

### 테스트

`bash Tests/run.sh` — 임시 바이너리를 빌드해 단위 테스트(실제 API 응답을 픽스처로 사용)와
e2e(키체인 접근 없는 임시 `HOME`)를 실행합니다. 설치된 앱과 설정은 건드리지 않습니다.

### 라이선스

MIT — [LICENSE](LICENSE) 참고.
