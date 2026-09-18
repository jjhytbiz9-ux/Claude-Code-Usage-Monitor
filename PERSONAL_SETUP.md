# Four-account monitor setup

This fork keeps four subscription accounts in separate credential directories so
switching a CLI login cannot put one account's usage under another account's label.
The settings file contains paths and labels only; OAuth credentials stay under
`%USERPROFILE%\.ai-usage-accounts` with a user-only Windows ACL.

## Fixed slots

| Slot | Account | Official plan | Profile directory |
| --- | --- | --- | --- |
| 코덱스 (공용) | `6tawesome@gmail.com` | ChatGPT Pro 20x | `.ai-usage-accounts\codex\6t` |
| 코덱스 (승엽) | `wna8fgh1@naver.com` | ChatGPT Pro 5x | `.ai-usage-accounts\codex\wna` |
| 클로드 (공용) | `6tawesome@gmail.com` | Claude Max 5x | `.ai-usage-accounts\claude\6t` |
| 클로드 (승엽) | `jsy@awesomeent.kr` | Claude Max 20x | `.ai-usage-accounts\claude\jsy` |

## Install

```powershell
.\scripts\Install-AwesomeMonitor.ps1
```

The installer builds the release executable, saves the currently active Codex
credential as the Codex 6t profile if that slot is empty, installs the widget,
writes the four-account settings, and enables per-user Windows startup.
The widget counts down the remaining allowance, so an account at 96% used is
shown as 4% remaining. Codex shows its weekly reset, while each Claude card
shows separate `5시간 갱신` and `전체 갱신` countdowns in `0일 0시간` form;
Fable shares the overall weekly reset. When the provider does not expose a
timestamp, the corresponding row shows `—` instead of inventing a time. Once a
reset timestamp has been captured, its countdown is recalculated from the local
clock every minute even if that account's usage percentage remains at its last
known value after switching.

## Desktop layout

The four accounts render as independent 420×210 Windows 95-style cards in a
2×2 grid on display 3. They are hosted by Explorer's desktop layer instead of
the taskbar, so they stay out of both the taskbar and Alt+Tab and appear with
the desktop when other windows are cleared. This mirrors Memo95's quiet
desktop-widget behavior while keeping the usage monitor read-only.

Each Codex card intentionally renders only the remaining weekly allowance; the
five-hour window is not part of the Codex layout.

Each Claude card shows three independent windows: `5H`, general `7D`, and
model-scoped `FABLE`. Claude Desktop's local usage history supplies the first
two windows, but it does not contain the model-scoped Fable window. Run the
dedicated Claude login below once for each slot to enable the live Fable value.
Until then the widget deliberately shows `--` instead of treating missing data
as zero usage.

## Connect a missing slot

```powershell
.\scripts\Login-AIAccount.ps1 -Profile codex-wna
.\scripts\Login-AIAccount.ps1 -Profile claude-jsy
.\scripts\Login-AIAccount.ps1 -Profile claude-6t
```

Each command sets `CODEX_HOME` or `CLAUDE_CONFIG_DIR` only for the child login
process. Claude logins also suppress `ANTHROPIC_API_KEY` and
`ANTHROPIC_AUTH_TOKEN` only inside that child login so the CLI performs the
subscription OAuth flow instead of silently selecting API-key mode. The
original environment is restored afterward, so other terminals keep their
existing API-key setup.
