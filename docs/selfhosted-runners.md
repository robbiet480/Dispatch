# Self-hosted CI runners (Mac mini stack)

Dispatch's heavy CI jobs (`test`, `build-app`, `ios-ui-suite`, `ipad-ui-suite`,
`mac-ui-smoke`) run on self-hosted M4 Mac minis instead of GitHub-hosted
runners. Why: hosted macOS runners are 3-vCPU M1s with a ~5-job concurrency
cap, and — decisively — **`mac-ui-smoke` cannot run hosted at all**: the Mac
app's app-sandbox + iCloud entitlements make launchd refuse to spawn an
ad-hoc-signed build (`Runningboard error 5 / Launchd job spawn failed`), so the
job needs a real Apple Development identity, which needs a persistent trusted
machine. An M4 mini runs the iOS suite ~40% faster while running the iPad
suite concurrently on its second lane.

Topology: each mini hosts **two runner instances** (one job each), all sharing
the `dispatch-selfhosted` label — jobs load-balance across every idle instance.
Two minis = four lanes + host redundancy.

## Security model (public repo!)

- Every self-hosted job carries a **same-repo-PR gate**
  (`(github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository)`)
  so fork-PR code never executes on these machines while non-PR events
  (push, schedule, dispatch) still run. Repo settings additionally
  require maintainer approval for all external contributors' workflow runs.
- Repo Actions permissions: GitHub-authored actions only, SHA-pinned.
- FileVault stays ON (the signing identity lives here). The boot-unlock
  password passes through to the desktop, so no auto-login is needed.
- The Apple Development identity on these boxes signs development builds only;
  keep it off other machines.

## Machine setup (run in a GUI session — Screen Sharing/console, NEVER plain SSH)

Nearly every trap below is a variant of one rule: **the runner must live inside
a real logged-in GUI (Aqua) session** — that's what provides the unlocked login
keychain (codesign) and the window server + automation mode (XCUITest).

### 0. Prereqs
```sh
# macOS + Xcode versions matching the other minis, then:
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
brew install xcodegen xcbeautify
```
System Settings → Lock Screen: require password **Never**; display sleep
**Never** (UI tests cannot run on a locked screen). Leave FileVault on.

### 1. Signing identity + profile
Clone the repo, `xcodegen generate`, open `Dispatch.xcodeproj`, select the
`DispatchMac` scheme + My Mac, set the team, and build once. Xcode registers
the machine as a development device, mints an Apple Development identity into
the login keychain, and fetches the team provisioning profile.

Then grant non-Xcode tools access to the new private key (a freshly minted key
only trusts Xcode; the runner's `codesign` would otherwise fail with
`errSecInternalComponent`):
```sh
security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
```
Verify from a GUI terminal — must print SIGN-OK with **no dialog**:
```sh
cp /bin/ls /tmp/ls-test
codesign --force --sign "Apple Development" /tmp/ls-test && echo SIGN-OK
```

### 2. Automation permission (XCUITest)
UI testing needs macOS "automation mode". Trigger the grant once by running a
UI test locally from a GUI terminal and approving the prompt:
```sh
xcodebuild test -project Dispatch.xcodeproj -scheme DispatchMac \
  -destination 'platform=macOS' CODE_SIGN_STYLE=Automatic
```
Without this, CI fails with *"Timed out while enabling automation mode."*
(If the prompt doesn't appear, System Settings → Privacy & Security →
Accessibility → enable Xcode Helper.)

The automation grant can re-prompt when the test-runner binary moves (e.g. a
DerivedData path change) — approve on screen once per path per box.

### 3. Runner instances
Get a registration token (repo → Settings → Actions → Runners → New
self-hosted runner; valid ~1h, usable for both instances back-to-back):
```sh
# instance 1 (repeat with actions-runner-2 / dispatch-<box>2)
mkdir -p ~/actions-runner-1 && cd ~/actions-runner-1
curl -o runner.tar.gz -L https://github.com/actions/runner/releases/download/v2.335.1/actions-runner-osx-arm64-2.335.1.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/robbiet480/Dispatch --token <TOKEN> \
  --name dispatch-<box>1 --labels dispatch-selfhosted --work _work --unattended
```
(Names: `dispatch-a1/a2` = mini A, `dispatch-b1/b2` = mini B, etc.)

### 4. Launch — custom LaunchAgents, NOT `./svc.sh`, NOT `./run.sh`
**Do not use `./svc.sh install`**: its plist sets `SessionCreate=true`, which
detaches the runner into a new security session — codesign then can't reach the
login keychain even though `launchctl` shows the service in the `gui/` domain
(this cost us an evening). `./run.sh` dies on logout. Instead, one plist per
instance (paste each block whole; zsh chokes on loops with unquoted heredocs):

```sh
cat > ~/Library/LaunchAgents/dispatch-runner-1.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dispatch-runner-1</string>
  <key>ProgramArguments</key>
  <array><string>/Users/USERNAME/actions-runner-1/run.sh</string></array>
  <key>WorkingDirectory</key><string>/Users/USERNAME/actions-runner-1</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/Users/USERNAME/actions-runner-1/agent.out.log</string>
  <key>StandardErrorPath</key><string>/Users/USERNAME/actions-runner-1/agent.err.log</string>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dispatch-runner-1.plist
```
Repeat for `dispatch-runner-2`. Substitute USERNAME. If bootstrap returns
`Input/output error`, a stale service holds the label: `launchctl bootout
gui/$(id -u)/dispatch-runner-1` first (and make sure this terminal is a GUI
session, not SSH). RunAtLoad brings both up automatically on every login.

Verify: `launchctl print gui/$(id -u)/dispatch-runner-1 | grep state` →
`running`, and the runners show **Idle** in repo → Settings → Actions → Runners.

## How the workflows use these machines

- **DEVELOPER_DIR** is set per job (the LaunchAgent context defaults to
  CommandLineTools); jobs fail fast if no Xcode is found.
- **Per-instance simulators**: both instances share one CoreSimulator service,
  so each job creates/uses a device named for its runner (e.g.
  `iPhone 17 Pro-dispatch-a1`) — concurrent jobs never touch each other's device.
- **Sims are ERASED at job start**: persistent sims keep app state (submission
  throttle/dedupe) that breaks re-runs; erasing restores hosted-style fresh
  state.
- **DerivedData / SwiftPM caches persist** in `$HOME/ci-cache/…` per instance —
  deliberately OUTSIDE the workspace, because `actions/checkout` cleans
  untracked workspace files each run. (Keep build state, erase sim state.)
- The `changes` docs-only gate stays on `ubuntu-latest`.

## Maintenance

- Reload an instance: `launchctl bootout gui/$(id -u)/dispatch-runner-N`,
  then bootstrap again. The runner binary self-updates.
- **Never swap services while a job is running** — the job dies with no logs;
  wait for Idle or expect to rerun.
- Xcode upgrades: one box at a time; confirm green before doing the next.
- After a reboot: type the FileVault password at the console once — the GUI
  session comes up, RunAtLoad restores the runners.
- Hosted fallback: if the stack is down, flip any job's `runs-on` back to
  `macos-26` in a PR (drop the signing flags for mac-ui-smoke and expect it
  red — see the entitlements note at top).
