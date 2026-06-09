# AICreditsBar

**🌐 Language / 언어 — [English](#english) · [한국어](#한국어)**

---

## English

A native macOS **menu-bar** widget that continuously shows how much token/quota is
left for **Codex**, **Claude**, and **Gemini** — and flags when a window has refilled.

```
  Cx 54%  ·  Cl 31%  ·  Gm —
```

- **Green** > 50% left · **Yellow** 20–50% · **Red** < 20% · **Gray** unknown/stale · **↑** just refilled.
- **Auto-detects** which AI CLIs you use — it just reads each tool's local data dir. Nothing to configure to get started.
- Click the bar for a breakdown (5h + weekly windows, reset countdown, plan, burn rate).
- Auto-refreshes every 30s (configurable) and on every menu open. **No network calls** — everything is read from local CLI data on disk.

### Screenshots

**Menu bar** — every provider's remaining % at a glance (green > 50 · yellow 20–50 · gray unknown):

![menu bar](docs/images/menubar.png)

**Dropdown** — click the bar for the full per-provider breakdown (5h + weekly windows, reset countdown, plan, burn rate):

![dropdown breakdown](docs/images/dropdown.png)

**Settings (⌘,)** — display mode, provider toggles, custom colors & thresholds, Claude plan + one-click calibration:

![settings window](docs/images/settings.png)

### What each provider shows

| Provider | Source | Accuracy |
|---|---|---|
| **Codex** | `~/.codex/sessions/**/rollout-*.jsonl` → `rate_limits` | **Exact official %** — 5h (`primary`) + weekly (`secondary`), straight from the server, with real reset times. |
| **Claude** | `~/.claude/projects/**/*.jsonl` token usage | **Estimate** vs a budget (ccusage-style 5h block + 7-day sum). Anthropic stores no official % on disk, so you **calibrate** it once for accuracy (see below). |
| **Gemini** | `~/.gemini/` | Install / login status only — Gemini CLI exposes no local quota %. Shows `—`. |

> Numbers update only when that CLI actually makes a request, so a snapshot can be a few
> minutes old (shown as "snapshot Nm ago"). Stale Codex windows are greyed instead of shown as confident green.

### Accurate login — exact official % (recommended)

By default Claude is a local **estimate**. For the **exact official %** (identical to what `/usage` shows,
and it tracks real resets), open **Settings → Accurate login → Log in** and sign in to claude.ai in the
popup window — the session is captured automatically (no DevTools, no API keys, no manual paste).
**Codex needs no extra login** — it automatically reuses your `codex` CLI sign-in (`~/.codex/auth.json`),
so it goes live the moment the app starts. Session tokens are stored locally (they're revocable — log out
of claude.ai to invalidate); if a login expires, the bar falls back to the estimate/disk and shows a notice — just log in again.

### Requirements

- **macOS 11+** (Intel or Apple Silicon — you build a native binary on your own Mac).
- **Xcode Command Line Tools** (provides `swiftc`). If missing: `xcode-select --install`.

### Build & run

```bash
bash build.sh          # compiles main.swift → AICreditsBar.app
open AICreditsBar.app  # launches the menu-bar agent (no Dock icon)
```

Quit from the menu (**Quit AICreditsBar**) or `pkill -x aicreditsbar`. Print values as text without the GUI:

```bash
./AICreditsBar.app/Contents/MacOS/aicreditsbar --once
```

### Settings

Open **Settings…** from the menu (⌘,). Everything persists across launches:

- **Show in menu bar** — 5-hour window · Weekly window · Both (`5h/week`) · Lowest of the two.
- **Providers** — toggle Codex / Claude / Gemini, and whether to show the `Cx/Cl/Gm` labels.
- **Refresh interval**.
- **Colors & thresholds** — pick your own High / Mid / Low / Unknown colors and the green/yellow cutoffs.
- **Claude budget** — choose a plan (Pro / Max 5x / Max 20x) or a custom token budget.

#### Calibrate Claude for accuracy

Because Claude has no official % on disk, the cleanest accurate fix is a one-time calibration:

1. In Claude Code, run `/usage` and note your real **5h used %** and **weekly used %**.
2. In **Settings → Calibrate**, type those two numbers and click **Calibrate**.

The app back-computes your token budgets from the current usage so the displayed % matches
reality, then tracks proportionally as you spend tokens. Re-calibrate occasionally if it drifts.

The in-app **Settings → Calibrate** updates the running app live. You can also calibrate from
the command line, but then you must restart the app for it to take effect:

```bash
BIN=./AICreditsBar.app/Contents/MacOS/aicreditsbar
$BIN --set-week-used 52   # /usage says 52% of the weekly limit used → weekly shows 48% left
$BIN --set-5h-used 80     # /usage says 80% of the 5-hour limit used → 5h shows 20% left
# then restart so it reloads: quit from the menu (or `pkill -x aicreditsbar`) and `open AICreditsBar.app`
# (or, if you installed the login item: launchctl kickstart -k "gui/$(id -u)/com.sueun.aicreditsbar")
```

### Start at login (optional)

```bash
bash install-login-item.sh     # registers a LaunchAgent that runs it at login
bash install-login-item.sh -u  # remove it
```

### Files

- `main.swift` — the whole app (data readers + menu-bar UI + settings).
- `build.sh` — compile + assemble the `.app` bundle.
- `install-login-item.sh` — add/remove the login LaunchAgent.
- `probe.py` — reference reader in Python; prints the same numbers (used to validate the Swift).

### How it works / privacy

AICreditsBar never makes network requests and never touches your credentials. It only reads the
usage/limit data the CLIs already write to disk under `~/.codex`, `~/.claude`, and `~/.gemini`,
computes the numbers locally, and draws them in the menu bar.

### License

MIT — see [LICENSE](LICENSE).

---

## 한국어

Codex, Claude, Gemini의 남은 토큰/한도를 macOS **메뉴바**에 계속 표시하고,
한도 창이 리필되면 알려주는 네이티브 위젯입니다.

```
  Cx 54%  ·  Cl 31%  ·  Gm —
```

- **초록** 50%↑ 남음 · **노랑** 20–50% · **빨강** 20% 미만 · **회색** 알 수 없음/오래됨 · **↑** 방금 리필됨.
- **자동 감지** — 각 도구의 로컬 데이터 폴더를 읽어, 당신이 쓰는 AI CLI를 알아서 띄웁니다. 시작할 때 따로 설정할 것 없음.
- 메뉴바를 클릭하면 상세 정보(5시간 + 주간 창, 리셋 카운트다운, 요금제, 소모 속도)를 봅니다.
- 30초마다(설정 가능) + 메뉴를 열 때마다 자동 갱신. **네트워크 호출 없음** — 전부 디스크의 로컬 CLI 데이터에서 읽습니다.

### 스크린샷

**메뉴바** — 한눈에 보는 각 제공자의 남은 % (초록 > 50 · 노랑 20–50 · 회색 알 수 없음):

![메뉴바](docs/images/menubar.png)

**드롭다운** — 바를 클릭하면 제공자별 상세(5시간 + 주간 창, 리셋 카운트다운, 요금제, 소모 속도):

![드롭다운 상세](docs/images/dropdown.png)

**설정 (⌘,)** — 표시 모드, 제공자 토글, 색상·임계값 커스텀, Claude 요금제 + 원클릭 보정:

![설정 창](docs/images/settings.png)

### 각 제공자가 보여주는 것

| 제공자 | 출처 | 정확도 |
|---|---|---|
| **Codex** | `~/.codex/sessions/**/rollout-*.jsonl` → `rate_limits` | **정확한 공식 %** — 5시간(`primary`) + 주간(`secondary`), 서버 값 그대로, 실제 리셋 시각 포함. |
| **Claude** | `~/.claude/projects/**/*.jsonl` 토큰 사용량 | **추정치** (ccusage 방식 5시간 블록 + 7일 합계 vs 예산). Anthropic은 공식 %를 디스크에 저장하지 않으므로, 정확도를 위해 한 번 **보정**합니다(아래 참고). |
| **Gemini** | `~/.gemini/` | 설치/로그인 상태만 — Gemini CLI는 로컬 한도 %를 노출하지 않음. `—` 표시. |

> 수치는 해당 CLI가 실제로 요청을 보낼 때만 갱신되므로, 스냅샷이 몇 분 전 값일 수 있습니다
> (메뉴에 "snapshot N분 전"으로 표시). 오래된 Codex 창은 자신만만한 초록 대신 회색으로 처리됩니다.

### 정확한 로그인 — 공식값 그대로 (권장)

기본적으로 Claude는 로컬 **추정치**입니다. **공식 정확값**(`/usage`와 완전히 동일, 실제 리셋도 반영)을 원하면
**Settings → Accurate login → Log in**에서 팝업 창에 claude.ai 로그인을 하세요 — 세션이 자동 캡처됩니다
(DevTools·API 키·수동 붙여넣기 불필요). **Codex는 추가 로그인 불필요** — `codex` CLI 로그인(`~/.codex/auth.json`)을
자동 재사용해서 앱 시작 즉시 live로 동작합니다. 세션 토큰은 로컬에 저장됩니다(취소 가능 — claude.ai에서
로그아웃하면 무효화). 만료되면 추정치/디스크로 폴백하고 알림을 띄웁니다 — 다시 로그인만 하면 됩니다.

### 요구 사항

- **macOS 11+** (Intel 또는 Apple Silicon — 자기 맥에서 네이티브 바이너리를 직접 빌드).
- **Xcode Command Line Tools** (`swiftc` 제공). 없으면: `xcode-select --install`.

### 빌드 & 실행

```bash
bash build.sh          # main.swift 컴파일 → AICreditsBar.app
open AICreditsBar.app  # 메뉴바 에이전트 실행 (Dock 아이콘 없음)
```

메뉴의 **Quit AICreditsBar**로 종료하거나 `pkill -x aicreditsbar`. GUI 없이 값을 텍스트로 출력:

```bash
./AICreditsBar.app/Contents/MacOS/aicreditsbar --once
```

### 설정

메뉴에서 **Settings…**(⌘,)를 엽니다. 모든 설정은 재실행해도 유지됩니다:

- **메뉴바 표시** — 5시간 창 · 주간 창 · 둘 다(`5h/week`) · 둘 중 낮은 값.
- **제공자** — Codex / Claude / Gemini 토글, `Cx/Cl/Gm` 라벨 표시 여부.
- **갱신 주기**.
- **색상 & 임계값** — High / Mid / Low / Unknown 색상과 초록/노랑 경계를 직접 지정.
- **Claude 예산** — 요금제(Pro / Max 5x / Max 20x) 또는 커스텀 토큰 예산 선택.

#### Claude 정확도 보정

Claude는 공식 %가 디스크에 없으므로, 가장 깔끔한 정확화 방법은 한 번의 보정입니다:

1. Claude Code에서 `/usage`를 실행해 실제 **5시간 사용 %**와 **주간 사용 %**를 확인합니다.
2. **Settings → Calibrate**에 그 두 숫자를 입력하고 **Calibrate**를 누릅니다.

앱이 현재 사용량으로 토큰 예산을 역산해 표시 %를 실제와 맞추고, 이후 토큰 사용에 비례해 추적합니다.
어긋나면 가끔 다시 보정하세요.

인앱 **Settings → Calibrate**는 실행 중인 앱에 즉시 반영됩니다. 커맨드라인으로도 보정할 수 있지만,
그 경우 앱을 재시작해야 적용됩니다:

```bash
BIN=./AICreditsBar.app/Contents/MacOS/aicreditsbar
$BIN --set-week-used 52   # /usage 주간 52% 사용 → 주간 48% 남음으로 표시
$BIN --set-5h-used 80     # /usage 5시간 80% 사용 → 5시간 20% 남음으로 표시
# 그런 다음 재시작: 메뉴에서 종료(또는 `pkill -x aicreditsbar`) 후 `open AICreditsBar.app`
# (로그인 항목을 설치했다면: launchctl kickstart -k "gui/$(id -u)/com.sueun.aicreditsbar")
```

### 로그인 시 자동 시작 (선택)

```bash
bash install-login-item.sh     # 로그인 시 실행되는 LaunchAgent 등록
bash install-login-item.sh -u  # 제거
```

### 파일 구성

- `main.swift` — 앱 전체 (데이터 리더 + 메뉴바 UI + 설정).
- `build.sh` — 컴파일 + `.app` 번들 조립.
- `install-login-item.sh` — 로그인 LaunchAgent 추가/제거.
- `probe.py` — Python 참조 구현; 같은 숫자를 출력 (Swift 검증용).

### 작동 방식 / 프라이버시

AICreditsBar는 네트워크 요청을 하지 않고 자격증명도 건드리지 않습니다. CLI들이 이미
`~/.codex`, `~/.claude`, `~/.gemini`에 기록해 둔 사용량/한도 데이터만 읽어, 로컬에서 계산해
메뉴바에 그립니다.

### 라이선스

MIT — [LICENSE](LICENSE) 참고.
