# Implementation Notes

## RustDesk-Herbin 1.4.9 baseline

- Upstream baseline: official RustDesk tag `1.4.9`.
- Product identity remains isolated as `RustDesk-Herbin`, bundle ID
  `com.herbin.rustdesk`, URL scheme `rustdesk-herbin://`, and independent macOS
  config and launchd namespaces.
- Generated macOS service plists preserve the exact bundle ID while applying
  product-name substitutions. Reinstalling the service unloads the current
  user agent and root daemon before rewriting and reloading them so launchd
  refreshes its code requirements after an application replacement.
- The abandoned Windows and macOS shortcut-remapping experiments have been
  removed. RDH now uses upstream keyboard handling without a custom keymap file,
  built-in remap, or compatibility fallback.

## macOS remote-click activation fix

- The controlled Mac resolves the visible application under the cursor before a
  remote left-button-down event and asks AppKit to activate regular applications.
- A precisely identified `com.apple.SecurityAgent` accessory window is the sole
  non-regular activation exception. RDH sets its public Accessibility
  `kAXFrontmostAttribute` before the original mouse-down so keyboard focus stays
  with the authorization dialog while the requesting application remains the
  AppKit frontmost application.
- Dock-owned windows and non-regular overlay applications are ignored.
- Activation remains best effort: failure is logged at debug level and the mouse
  click is still delivered.
- High-volume protocol, injection, focus-transition, and delayed-settle tracing
  from the diagnosis builds has been removed.

## Build and distribution

- macOS builds remain CI-first through `.github/workflows/codex-macos-herbin.yml`.
- Until a Developer ID certificate is available, CI artifacts are ad-hoc signed,
  not notarized, and explicitly marked `installable=false`. The workflow proves
  build and signature integrity only; it does not produce the persistent-host
  installation candidate.
- Before local installation, the verified CI artifact must be promoted with the
  existing Apple Development identity for Team `7373GRMT82`. Promotion preserves
  the approved entitlements and must reproduce the certificate-based Designated
  Requirement of the last known-good RDH app. The promoted artifact alone may be
  marked `installable=true`.
- `res/rdh-macos-signing-policy.sh --promote` is the canonical local entrypoint.
  Its report policy fails closed on ad-hoc signatures and bundle, Team ID,
  Designated Requirement, or entitlement drift before producing a separate DMG.
- A direct ad-hoc rdh.23 installation demonstrated why this gate is required:
  `tccd` rejected the existing Screen Capture and Listen Event grants because
  their stored Apple Development code requirement no longer matched the ad-hoc
  cdhash requirement. Bundle ID and entitlements had not changed.
- Artifact versions use `<upstream>-rdh.<revision>` while the application keeps
  the upstream protocol/application version.
- The upgrade rehearsal workflow never merges or installs automatically. It only
  checks the latest official release, rehearses the merge in an ephemeral runner,
  and runs the RDH static invariants.

## OSS management API boundary

- Automatic `/api/heartbeat`, `/api/sysinfo`, and `/api/audit/*` traffic starts
  only when `api-server` is explicitly configured. A custom rendezvous server by
  itself no longer implies that the closed Server Pro management API exists on
  port 21114.
- This gate does not change the native hbbs registration/heartbeat protocol,
  direct connections, hole punching, or hbbr relay traffic.
- An explicitly configured private API server retains the upstream device
  inventory, connection reporting, remote disconnect, and strategy behavior.

## macOS user-server memory recovery

- The RDH `--server` now contains a low-frequency RSS watchdog with a 1 GiB default
  threshold. It is active only when the exact RDH launchd job is supervising the
  process.
- Memory is checked once daily at 06:00 local time. This preserves the previous
  automation cadence instead of continuously polling the process.
- 06:00 is inside the 00:00-06:59 unattended window, where active connections are
  intentionally ignored. If the scheduled wake is delayed beyond 07:00, the check
  is skipped rather than restarting during daytime.
- Recovery exits only the user server with a nonzero status so the existing
  launchd `KeepAlive` policy relaunches it. It never unloads or restarts the root
  service and therefore does not require an administrator prompt.
- `rdh-memory-restart-threshold-mib=0` disables the watchdog. Invalid values disable
  it explicitly instead of silently falling back.
- This mitigates the long-running leak but does not identify or fix its allocation
  source; heap profiling remains a separate follow-up.

No public compatibility layer is retained for the removed shortcut mapping.

## macOS CLI discovery and dispatch

- `--help`, topic help, `--version`, and `--capabilities` are handled before
  global runtime initialization and before AppKit/Flutter. CI injects
  `RDH_REVISION`; local builds without it identify themselves as `rdh.dev`.
- The pre-AppKit gate claims every argument vector containing `--headless`.
  Supported terminal and file-transfer combinations reach their existing
  parsers; any other combination fails closed with status 2 and never becomes a
  Flutter peer connection.
- `docs/rdh-cli.md` is the operator source of truth. It separates installed and
  candidate binaries, defines the capability preflight, and requires external
  SHA-256 verification after file transfer.

## macOS headless file transfer CLI

- `--file-transfer --headless` owns only the combined form before Flutter
  dispatch and transfers one regular file by `push` or `pull` through the native
  `FILE_TRANSFER` session and `FileManager` path.
- The CLI preserves saved-credential operation without a TTY, prompts securely
  only for an actual password or 2FA requirement with stdin TTY, rejects
  `--password` and insecure transport, and keeps stdout limited to the success
  destination while prompts, progress, and diagnostics use stderr.
- Existing destinations fail with status 7 unless `--overwrite` is explicit;
  overwrite starts at offset block 0. There is no retry, reconnect, or resume.
  Push success requires native completion plus a remote regular-file/size
  postflight; real acceptance independently compares external SHA-256 values.

Open questions: none
