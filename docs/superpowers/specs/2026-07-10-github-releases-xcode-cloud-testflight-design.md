# Design: GitHub Releases to Xcode Cloud to TestFlight

**Status:** approved 2026-07-10. Build 24 at commit `6b33559` is the initial changelog baseline. This design automates TestFlight distribution only; App Store listing attachment and submission remain explicit manual operations.

## Goal

Make GitHub Releases the release control plane without storing Apple signing material in GitHub:

1. GitHub continuously maintains one draft prerelease with an automatically generated, user-facing changelog.
2. Robbie reviews and publishes that prerelease in GitHub.
3. The published release's Git tag starts Xcode Cloud.
4. Xcode Cloud signs, archives, and distributes the exact tagged commit to TestFlight.
5. The user-facing portion of the GitHub Release body becomes TestFlight's “What to Test” text.

Publishing a GitHub prerelease is the only human deployment gate. Automation must never attach a build to the App Store listing or submit an App Store version for review.

## Decision: GitHub control plane, Xcode Cloud distribution plane

Three approaches were considered:

1. **Custom GitHub draft workflow plus Xcode Cloud distribution — selected.** This includes direct-to-`main` commits as well as PRs, keeps release review in GitHub, and delegates Apple signing/provisioning/build numbering to Apple's service.
2. **Release Drafter plus Xcode Cloud.** Simpler for PR-only repositories, but Dispatch regularly lands small fixes directly on `main`; adding a second direct-commit generator removes the simplicity advantage.
3. **GitHub-generated notes plus GitHub Actions distribution.** Minimal release-note code, but weaker filtering/direct-commit coverage and requires long-lived distribution certificates, provisioning profiles, and App Store Connect credentials in GitHub.

Xcode Cloud supports Git-tag start conditions, automatic TestFlight post-actions, automatic build numbering, and dynamically generated tester notes. Apple Developer Program membership includes 25 Xcode Cloud compute hours per month. The GitHub Actions CI workflow remains the ordinary branch/PR quality gate; Xcode Cloud is used only for tagged TestFlight distributions.

References:

- [Xcode Cloud workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)
- [Including notes for TestFlight testers](https://developer.apple.com/documentation/xcode/including-notes-for-testers-with-a-beta-release-of-your-app)
- [Xcode Cloud build numbering](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)
- [Xcode Cloud plans](https://developer.apple.com/xcode-cloud/get-started/)

## Release identity and numbering

GitHub Release tags identify a TestFlight release sequence, not the App Store Connect build number:

```text
v<marketing-version>-tf.<sequence>
v1.0-tf.1
v1.0-tf.2
v1.1-tf.1
```

- `MARKETING_VERSION` remains authoritative in `project.yml`.
- The draft sequence is one higher than the newest published GitHub TestFlight tag for the current marketing version.
- Changing `MARKETING_VERSION` resets the GitHub TestFlight sequence to `1`.
- Xcode Cloud owns `CFBundleVersion`. Its initial next build number is manually set to `25` in App Store Connect because build 24 is already on TestFlight. Xcode Cloud then increments it for every cloud build; retries may consume numbers, which is expected.
- `CURRENT_PROJECT_VERSION` in `project.yml` remains a local-development fallback and is not used as the cloud release identity.

The first draft uses commit `6b33559` as its previous-ref baseline, so it contains only changes made after shipped build 24. No historical Git tag or retroactive GitHub Release is required. After `v1.0-tf.1` is published, each subsequent draft uses the latest published TestFlight tag as its comparison base.

## GitHub draft workflow

Add `.github/workflows/release-draft.yml` with these semantics:

- Trigger on completion of the existing `CI` workflow.
- Run only when the completed workflow was a successful `push` build for `main`.
- Check out `github.event.workflow_run.head_sha` with full history. Never generate a draft from current moving `main` or from a PR checkout.
- Use a concurrency group with cancellation so only the newest successful `main` result updates the draft.
- Grant only `contents: write` and `pull-requests: read` to its `GITHUB_TOKEN`.
- Run the checked-in changelog generator.
- Find the single draft prerelease whose title starts `Next TestFlight:`. Update it if present; otherwise create it.
- Set the draft's target commit to the successful CI SHA, its tag to the next sequence, `draft: true`, and `prerelease: true`.

The workflow never publishes a release. Robbie reviews the target SHA and body in GitHub and clicks Publish. GitHub's `release: published` event is not used for distribution in the selected design; publishing creates the tag, and Xcode Cloud's Git-tag start condition observes that tag.

If draft generation fails, the separate release-draft workflow is red but `main` and its already-completed CI result remain unaffected. The previous draft remains available for inspection and must not be partially rewritten.

## Changelog generation

Add a small, standard-library-only release-note tool with fixture-driven tests. It consumes a base ref, head SHA, repository name, and GitHub API responses. Network access and Git operations stay at the boundary; classification/rendering remain pure and testable.

Included commit types:

- `feat` → **New**
- `fix` → **Fixed**
- `perf` → **Improved**
- `revert` → **Changed**

Excluded types are `docs`, `test`, `ci`, `build`, and `chore`. Unprefixed commits are excluded by default so internal work does not leak into tester-facing notes. A future explicit release-note override may be added only if a real need appears; it is not part of v1.

For every included commit, the generator:

1. Uses the first associated merged PR when GitHub reports one.
2. Renders a PR number/link and the PR author's GitHub login for PR-backed work.
3. Otherwise renders the short commit link and GitHub commit author for direct-to-`main` work.
4. Deduplicates contributor attribution.
5. Appends a GitHub compare link under **Full Changelog**.

The body layout is deterministic:

```markdown
## New
- Description (#123) — @contributor

## Fixed
- Description (abc1234) — @contributor

## Full Changelog
https://github.com/robbiet480/Dispatch/compare/<base>...<head>
```

Empty categories are omitted. If there are no user-facing changes, the draft body says `No user-facing changes since the previous TestFlight release.` If it is published anyway, Xcode Cloud blocks distribution during the notes validation described below.

The TestFlight portion is everything before `## Full Changelog`. The generator keeps that portion at or below 3,500 Unicode characters, leaving headroom below App Store Connect's tester-note limit for manual edits. The Xcode Cloud fetcher rejects empty notes or notes above 4,000 characters rather than truncating silently.

## Committed Xcode project

Xcode Cloud requires a consistent Xcode project or workspace to be continuously present and warns that dynamically generated projects may fail initial configuration or later builds. Dispatch currently ignores `Dispatch.xcodeproj`, so implementation must:

1. Remove `Dispatch.xcodeproj/` from `.gitignore`.
2. Generate and commit `Dispatch.xcodeproj`, its shared schemes, and `Dispatch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
3. Continue treating `project.yml` as the only hand-edited project definition.
4. Add a GitHub CI step that runs XcodeGen and fails if `Dispatch.xcodeproj` changes.
5. Document that project changes are made in `project.yml`, followed by `xcodegen generate`; direct `.pbxproj` edits are forbidden.

The existing generated user data remains ignored through the existing `xcuserdata/` rule. Committing the generated project is an Xcode Cloud compatibility artifact, not a change in source-of-truth policy.

Reference: [Xcode Cloud project requirements](https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud).

## Xcode Cloud workflow

The one-time workflow is configured in Xcode/App Store Connect after the repository changes land:

- Connect Apple's Xcode Cloud GitHub App to `robbiet480/Dispatch` only.
- Product/scheme: `DispatchApp` from the committed `Dispatch.xcodeproj`.
- Start condition: Git tag matching `v*-tf.*`.
- Action: clean archive using the current production Xcode version compatible with the project.
- Post-action: distribute to the existing TestFlight tester groups.
- Next build number: `25`.
- Auto-cancel: disabled for this release workflow; a published release must never be cancelled by a later tag.

GitHub CI already tested and built the exact SHA before the draft could target it. Xcode Cloud therefore performs the signed clean archive rather than duplicating the full GitHub test matrix. The archive action still recompiles every shipped target, including the watch app and extensions.

Xcode Cloud manages signing and provisioning for team `UTQFCBPQRF`. No Apple distribution certificate, provisioning profile, App Store Connect API key, or Apple-account credential is stored in GitHub.

## TestFlight notes handoff

Add `ci_scripts/ci_post_xcodebuild.sh` plus a focused helper. The script acts only when all of these are true:

- `CI_TAG` matches `v*-tf.*`.
- `CI_XCODEBUILD_ACTION` is `archive`.
- `CI_XCODEBUILD_EXIT_CODE` is `0`.
- Xcode Cloud produced an App Store-signed app path.

The helper fetches the public GitHub Release for `CI_TAG` from `https://api.github.com/repos/robbiet480/Dispatch/releases/tags/<tag>`, retrying boundedly to tolerate the short release-publication/tag-observation race. It then:

1. Requires `draft == false` and `prerelease == true`.
2. Requires the release tag to exactly equal `CI_TAG`.
3. Extracts the release body before `## Full Changelog`.
4. Rejects empty content or content over 4,000 Unicode characters.
5. Writes `TestFlight/WhatToTest.en-US.txt` in the location Xcode Cloud recognizes.

No GitHub token is required because the repository and published release are public. The helper sends an explicit GitHub API version and `User-Agent`, handles `403`/`429` with bounded backoff, and never falls back to stale or generated-local text. The published release body is the source TestFlight receives.

If note retrieval or validation fails, the post-build script exits nonzero so Xcode Cloud reports a failed build and does not silently distribute a build without accurate tester notes. Robbie can correct the GitHub Release body and manually rerun the Xcode Cloud workflow for the existing tag.

## Security and hard rules

- GitHub's writable token exists only in the draft-maintenance workflow; release builds do not receive GitHub secrets.
- Xcode Cloud receives source access through Apple's repository integration and manages Apple signing internally.
- Release builds check out the immutable published tag, never moving `main`.
- Only tags matching the TestFlight pattern start the cloud workflow.
- The automation has no App Store Connect listing-update step, no build-attachment step, and no submission capability.
- Existing local App Store Connect scripts remain available for explicit manual staging, but the Xcode Cloud workflow never calls them.

## Error handling and recovery

| Failure | Result | Recovery |
|---|---|---|
| GitHub CI fails | Draft is not updated | Fix `main`; successful CI updates the draft |
| Draft generator/API fails | Separate workflow fails; previous draft remains | Rerun after fixing generator/API issue |
| Draft contains no user-facing changes | Draft exists with explanatory text; Xcode Cloud refuses distribution if published | Add a user-facing change or do not publish |
| Published tag is malformed | It does not match the Xcode Cloud trigger, or script validation fails | Correct by publishing a properly tagged prerelease |
| Xcode Cloud archive/signing fails | GitHub Release remains published; nothing reaches TestFlight | Fix configuration/code and rerun the tag workflow |
| GitHub Release body fetch races/fails | Bounded retries, then cloud build fails | Rerun after the release API is available |
| Tester notes are empty/too long | Cloud build fails before silent distribution | Edit release body and rerun |
| TestFlight processing fails | Xcode Cloud reports the distribution failure | Diagnose in Xcode Cloud/App Store Connect and rerun |

Automation never deletes, unpublishes, retags, or rewrites a published GitHub Release as recovery.

## Testing and verification

Automated tests cover:

- Conventional-prefix classification and excluded internal types.
- Direct-commit rendering.
- PR-backed rendering and contributor attribution.
- Deduplication and deterministic category order.
- Sequence calculation by marketing version.
- Build-24 baseline behavior when no published TestFlight tag exists.
- Empty-change behavior.
- GitHub compare URLs.
- Unicode-aware 3,500/4,000-character boundaries.
- GitHub Release JSON parsing, prerelease/tag validation, and extraction before `## Full Changelog`.
- Retryable versus terminal HTTP failures using fixtures/mocks, with no live network in tests.
- TestFlight tag parsing.

Repository verification adds:

- Existing `swift test` suite.
- Existing generated app build.
- XcodeGen regeneration followed by a zero-diff assertion for the committed project.
- Workflow syntax validation where available locally, plus GitHub Actions execution after push.
- A dry-run changelog command against `6b33559..HEAD` before enabling draft mutation.

The first preflight proof stops before publication: after the Xcode Cloud workflow is configured, create/update the draft and inspect its target, body, and tag. Only then does Robbie publish `v1.0-tf.1` for the end-to-end proof. Confirm Xcode Cloud assigns build 25, distributes it to TestFlight, and places the GitHub release notes in “What to Test.”

## Implementation boundaries

Implementation may change release tooling, CI configuration, generated-project tracking, and documentation. It must not change app runtime behavior, App Store listing metadata, App Store submission state, tester groups, or the existing untracked `scripts/contact-id-probe.swift` file.

Initial Xcode Cloud connection and workflow creation require authenticated Xcode/App Store Connect UI steps. Repository implementation prepares and verifies everything possible before those steps, then guides or performs the UI configuration with Robbie's active session. Publishing the first prerelease remains Robbie's explicit action.
