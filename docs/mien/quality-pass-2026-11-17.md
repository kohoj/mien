# Core interaction quality pass — 2026-11-17

This pass follows the user's request to improve the whole experience. It is a
bounded repair of the core conversation and readiness flows, not a whole-product
release acceptance or a measured claim about model speed.

## Reproduced problems

- A terminal answer withheld the next composer for 120 + 160 + 140 ms when
  activity existed. Another 300 ms delay controlled final collapse. Focus moved
  again after the composer's fade. Completion and animation shared authority.
- Every submitted turn constructed and loaded a `WKWebView`, including requests
  that only reached an authentication error. The new regression tests failed on
  the original code: one WebView existed before any result, and completion did
  not synchronously enable the composer.
- Native process rows displayed executable names and metadata strings, while
  plan text could reach presentation through the application delegate.
- A collapsed process occupied a separate row above each answer. The target
  application was invisible, and copying a complete answer lacked a direct UI.
- Permission refresh reapplied unchanged views every 500 ms; the System Settings
  guide checked and raised an unchanged window every 50 ms.
- A retry disabled its own button without reenabling it after another retryable
  failure.

## Delivered behavior and ownership

Terminal state and input availability now commit synchronously. Fades decorate
that state and do not own task lifetime, delayed focus, or recovery. Submissions
immediately show one local preparation state, replaced by the first standardized
Agent activity. `AgentActivityPresentation` owns product vocabulary from typed
kind/status/tool identity; remote titles and plan prose do not enter progress UI.

The header identifies the target app without inventing evidence scope. Copy and
recorded-process disclosure share a compact footer. Copy is an explicit local
user action over the immutable result. Retries retain the submitted turn and can
be used again after a second failure.

The result view creates WebKit only for a nonempty validated answer and avoids
rerendering identical Markdown. Failure/login-only turns create zero WebViews.
Multiple content-size changes coalesce into one scheduled window resize. This
does not claim reduced inference latency, startup latency, RSS, or energy usage.

`MienReadinessState.swift` owns derived readiness/next-action policy separately
from the settings view. `SystemSettingsGuide.swift` owns the permission-guide
window and geometry mechanism. Permission state checks run once per second only
while incomplete permissions are visible, and redraw only changed states. Guide
geometry checks run at 10 Hz and do not reset or raise an unchanged frame. Public
TCC checks remain authoritative; these changes do not grant any permission.

## Verification

- Regression tests establish the original failures and the new immediate-input,
  lazy-rendering, repeated-retry, target-label, and typed-activity behavior.
- Existing conversation, IME, sizing, authentication recovery, model selection,
  permissions, offline-renderer, and task-ledger checks remain part of
  `scripts/verify-mien.sh`.
- Local baseline/current renderings and verification logs are under
  `.build/quality-pass/`; this generated evidence is not a tracked release.
- Installation uses `script/build_and_run.sh --verify`. Actual installed Settings
  is checked separately from synthetic preview images.

## Limits at the end of this first pass

The follow-up [native architecture pass](native-quality-2026-11-17.md) supersedes the long-conversation and delegate-ownership limitations below.

- Completed rich answers still own separate WebViews. Long-conversation memory,
  typing/resize p95 latency, and idle power need a controlled workload and soak
  measurements before a shared-renderer or virtualization redesign is justified.
- Native previews expose a background mismatch between WebKit text and the
  material surface. Do not treat preview snapshots alone as proof of live
  compositor behavior; native light/dark rendering needs separate acceptance.
- The application delegate still coordinates task, recovery and draft lifetimes.
  Separating presentation policy removes one responsibility, but this pass is
  not a full redesign of conversation orchestration.
- The ad-hoc development build still needs real-machine TCC permission and a
  separately signed/notarized distribution acceptance. No clean-machine,
  production-release, or end-user acceptance is claimed here.
