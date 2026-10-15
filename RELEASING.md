# Releasing

`element-call-ios` is a source Swift package. A release is a **tag**, and hosts pin it by exact
version:

```yaml
# element-x-ios/project.yml
ElementCall:
  url: https://github.com/element-hq/element-call-ios
  exactVersion: 0.1.0-rc.1
```

Tags are bare semver — `0.1.0`, `0.2.0`, `0.2.1`, and `0.2.0-rc.1` for a prerelease. Bare, because
that is what SwiftPM matches a host's `exactVersion` against; the script refuses a leading `v`.

**`0.x` is deliberate.** The public surface is the ports and the accessibility identifiers, and a
renamed identifier is a breaking change with an external interop rig pinned against it (see
[CONTRIBUTING.md](CONTRIBUTING.md)). `0.x` says the surface is still moving.

Nothing is bumped ahead of time. The one version string in the repository,
`ElementCallVersion.current`, is stamped by `scripts/release.sh` into the commit it tags, so a
contributor never edits it and a pull request never carries a version. It exists because the call
screen shows it: SwiftPM tells a compiled module nothing about the version it was resolved at, and
the package has no bundle of its own to read one from.

## Cut a release

Releases are cut from a **`release/<version>` branch**, never from `main`. `main` is protected, and
nothing in this pipeline needs a token that can bypass that: the tag and the release commit go to the
release branch, and the changelog reaches `main` afterwards through an ordinary reviewed pull request.
The workflow runs on the built-in `GITHUB_TOKEN`.

### 1. Pick a version

- **Patch** (`0.2.0` → `0.2.1`) for fixes behind an unchanged API.
- **Minor** (`0.2.1` → `0.3.0`) for anything else. At `0.x` this is also where breaking changes go,
  which is why every such pull request wants the `pr-api` label — `.github/release.yml` gives it its
  own "⚠️ API Changes" heading precisely so a host reads it before bumping.
- **A prerelease** (`0.3.0-rc.1`) when you want a host to try it without it becoming the version
  everyone gets. See [Prereleases](#prereleases).

### 2. Dry run

**Actions → Release → Run workflow**, on `main`, with the version and `dry_run` left **on**. It is on
by default, and a dry run can be dispatched from any branch because it only reads. Dispatch it from
the branch you intend to release: `main` for an ordinary release, and the release branch itself for a
[hotfix](#hotfix), whose notes are scoped to its own line of history.

Then **read the notes it prints.** They are built from the `pr-` labels on the pull requests merged
since the last tag, and this is the moment to check them, because:

> Anything under **Others** is a pull request that was merged without a `pr-` label.

Nothing enforces that label at merge time — the pull request template asks for it and a reviewer is
expected to notice. When one slips through, add the label to the *merged* pull request and dry-run
again. The notes are generated at release time, not at merge time, so a late label still works.

The same lateness works for taking an entry *out*: `pr-task` on a merged pull request excludes it
from the notes entirely, so a pull request that should never have had a changelog line can be
relabelled and dry-run again rather than edited out of `CHANGES.md` afterwards.

The dry run changes nothing: no commit, no tag, no release, no push.

### 3. Create the release branch

```bash
git fetch --tags --prune
git switch -c release/0.2.0 origin/main
git push -u origin release/0.2.0
```

The name must be exactly `release/<version>` — the workflow refuses to publish when the branch and the
version disagree, so a run dispatched against the wrong branch cannot mint a tag off it.

Pushing the branch starts a `Tests` run (`tests.yml` watches `release/**` for this reason). **Wait for
it to pass.** The release workflow refuses to tag a commit with no green run, and it cannot test
anything itself — it runs on Linux and never opens Xcode.

### 4. Release

**Actions → Release → Run workflow**, this time with `release/0.2.0` selected and `dry_run` **off**.
It will:

1. rename `## Unreleased` in `CHANGES.md` to `## 0.2.0 - <date>`, fill it with the generated notes,
   and open a fresh empty `## Unreleased` above it;
2. commit that as `Release 0.2.0`, tag it, and push the commit and tag **atomically**, so the tag can
   never exist without the changelog entry that describes it;
3. create the GitHub release from the same notes, marked prerelease if the version has a hyphen.

The job summary then links the release and the pull request to open next.

### 5. Merge the changelog back to `main`

Open the pull request the summary links to — `release/0.2.0` → `main` — and get it reviewed like any
other. **Merge it with a merge commit, not a squash.** A squash creates a new commit and leaves the
tagged one reachable only through the tag, so `git describe` on `main` stops finding the release and
"which release contains this commit?" stops having an answer. SwiftPM resolves the tag either way, so
this is about the history staying legible rather than about the release working.

The tag is already public by now, and the release does not depend on this pull request landing. If
review finds a problem with the changelog *text*, fix it on `main` in a follow-up — the tag stays put.
If it finds a problem with the *code*, that is a new release rather than an edit to this one; see
[If it fails halfway](#if-it-fails-halfway) for why a tag is never moved.

### 6. Check it

```bash
git ls-remote --tags https://github.com/element-hq/element-call-ios | grep <version>
gh release view <version>
```

And resolve it the way a host will, from a scratch directory:

```bash
mkdir -p /tmp/probe && cd /tmp/probe
cat > Package.swift <<'EOF'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "probe",
    dependencies: [.package(url: "https://github.com/element-hq/element-call-ios", exact: "<version>")]
)
EOF
swift package resolve && cat Package.resolved
```

## The changelog

[`CHANGES.md`](CHANGES.md) keeps a `## Unreleased` heading at the top. Releasing renames it to
`## <version> - <date>` and opens an empty one above, so the file reads newest-first and always has
somewhere for the next entry to go.

**For an ordinary change there is nothing to write.** Label the pull request and give it a title that
reads as a changelog line; the release generates the list from those.

**For a change no host could observe, label it `pr-task`** — CI plumbing, test-only churn, a
repository chore. `.github/release.yml` excludes that label before categorising, so the pull request
gets no line under any heading, not even the *Others* catch-all. It is the only way to keep a merged
pull request out of the notes, and that is the point: an absent entry is then a decision someone
made and a reviewer could see, rather than what happens when the label is forgotten.

**Write under `## Unreleased` by hand only when a host has to act** — a renamed accessibility
identifier, a port gaining a requirement, a new build setting. Anything found there at release time is
carried into that version's section and kept *above* the generated list, where someone bumping the
version will actually read it rather than below thirty lines of dependency bumps.

The workflow refuses to release if the `## Unreleased` heading is missing, since there would be
nowhere to record the version.

## If it fails halfway

The mutating steps are, in order: **push** (commit and tag, atomically) then **create the release**.
Everything before them changes nothing, so a failure there needs no cleanup — fix the cause and
dispatch again.

| What happened | What to do |
| --- | --- |
| Push failed | Nothing landed — the push is `--atomic`, so the branch and the tag move together or not at all. Fix the cause and dispatch again. |
| Push landed, release creation failed | Dispatch again, same branch and version. The release step is idempotent: it leaves an existing release alone and creates one for a tag that is already pushed. Should an earlier check refuse first, do it by hand: `gh release create <version> --verify-tag --title <version> --notes-file release-notes.md` (add `--prerelease` for a hyphenated version), taking `release-notes.md` from the run's `release-<version>` artifact, uploaded before anything is published for exactly this case. |

**Never delete and re-push a tag to retry.** A host may already have resolved it, and SwiftPM caches
by tag, so a tag that changes meaning is far worse than a missing release page. Release a new patch
instead.

## Bump the host

[Renovate](https://github.com/element-hq/element-x-ios/blob/develop/renovate.json) raises the
`element-x-ios` bump on its own: its built-in `xcodegen` manager reads `project.yml`'s `packages:`
block, so `ElementCall` joins the existing "Project Dependencies" group, and
`renovate-xcodegen.yml` regenerates `ElementX.xcodeproj` and `Package.resolved` on the pull request.

Two things follow from element-x-ios's Renovate config, and both are intended:

- `minimumReleaseAge: 7 days` — a fresh tag waits a week. Edit `project.yml` by hand if you need it
  sooner.
- `config:recommended` ignores unstable versions — **prereleases never arrive by Renovate**, so
  every bump is by hand until the first stable tag.

## Prereleases

A version with a hyphen is marked prerelease automatically: it stays off "latest", Renovate skips it,
and a host has to pin it deliberately. That is what makes it the right first tag today.

**`Package.swift` depends on `https://github.com/element-hq/matrix-rust-rtc` at an exact
prerelease.** A stable tag here would publish that edge into element-x-ios's resolved graph as
though it were settled, so **the first stable release waits for `matrix-rust-rtc` to reach a stable
version.** Until then, release `0.1.0-rc.N`.

## Hotfix

A fix to an older line — `0.2.1` when `0.3.0` has already shipped, for a host still pinned to the 0.2
line — is the same process, branched from the tag instead of from `main`:

```bash
git switch -c release/0.2.1 0.2.0     # the tag, not main
# land the fix on that branch through a pull request as usual
git push -u origin release/0.2.1
```

Then release as above and merge `release/0.2.1` into `main` at the end, so the changelog entry is not
stranded. One difference in step 2: **dry-run from `release/0.2.1`, not from `main`.** The tag scoping
below is what makes a hotfix work, and it follows the branch — a dry run from `main` would show you
the notes for a release you are not cutting.

Nothing special is needed to make this work, and that is deliberate. The workflow reads the newest
release tag **reachable from the branch you are releasing** (`git tag --merged HEAD`), so from
`release/0.2.1` the newest release is `0.2.0` and not `0.3.0`. That single decision does two jobs: it
stops `0.2.1` being refused for sorting below `0.3.0`, and it makes GitHub compare the notes against
`0.2.0`, so they list the fix rather than re-listing everything 0.3.0 contained.

## What the workflow will refuse to do

Every refusal names its own cause in the run summary. In the order they are checked:

| Refusal | What it means |
| --- | --- |
| Dispatch this from a branch named `release/<version>` | You published from `main`, or the branch and the version disagree. Dry runs are exempt. |
| Version must not start with `v` | `matrix-rust-rtc` tags `v0.2.0`; SwiftPM wants `0.2.0` here. |
| Not a semantic version | Typo, or a two-component version like `0.2`. |
| Tag already exists | That version has shipped. Bump. |
| Sorts below `<tag>`, already released in this history | Going backwards within one line. For a fix to an *older* line, branch from that line's tag — see [Hotfix](#hotfix). |
| Already released, so this is a prerelease of the past | `0.2.0-rc.1` after `0.2.0` shipped. |
| No Tests run exists for this commit | The branch is not pushed, or `Tests` never ran on it. **Warning only on a dry run.** |
| Tests has not succeeded for this commit | See below. **Warning only on a dry run.** |
| Could not query the Tests workflow | The token is missing `actions: read`. |
| No changelog entries | Nothing has merged since the last tag. |
| `CHANGES.md` has no `## Unreleased` heading | Someone removed it; restore it. See [The changelog](#the-changelog). |

### "Tests has not succeeded for this commit"

The release job runs on Linux and never opens Xcode, so it cannot test anything itself. It asks
instead whether the `Tests` workflow already passed for the **exact commit** being released, and says
which of "no run at all", "still running" and "failed" it found.

That is on purpose: `XCODE_APP`, `SIMULATOR_NAME` and `SIMULATOR_RUNTIME` are already duplicated
between `tests.yml` and `record-snapshots.yml` (and `AGENTS.md`, and
`Tests/ElementCallTests/Support/SnapshotEnvironment.swift`), and a release job that ran the tests
itself would be another copy to keep in step. So the release gates on that run rather than repeating
it — and a commit nobody has tested cannot be released.

`tests.yml` runs on pushes to `release/**` as well as `main`, so pushing the release branch is what
produces the run this gate is waiting for.

It asks whether **any** run for the commit has succeeded, not whether the newest one has. That
distinction is load-bearing: a release branch cut from `main` at the same commit starts a second run
for a SHA that has already passed, and judging by the newest run would refuse a green commit and
restart the wait on every push. So the wait happens once, on `main`, and pushing the release branch
costs nothing.

**On a dry run this is a warning, not a refusal**, and it is the only check that softens. A dry run
publishes nothing, so blocking it behind a 30-minute macOS test run would buy no safety and cost you
a run-wait-run loop at the step whose entire product is the notes. You still get the warning, and the
real release still refuses — so a dry run that warns here is fine to act on, as long as `Tests` is
green by the time you cut the release.

## Why there are no artifacts on the release page

Comparing this against a [`matrix-rust-rtc`](https://github.com/element-hq/matrix-rust-rtc/releases)
release, the missing `.xcframework.zip` looks like a broken pipeline. It is not.

That repository ships a zip and a checksum because it contains **Rust**: cargo, uniffi and libwebrtc
produce something a consumer cannot build for itself, and rewriting `Package.swift` with a `url` and
a `checksum` is how that artifact reaches SwiftPM. This package is Swift, which Xcode compiles. Every
binary xcframework in the Element org is a Rust FFI artifact; every pure-Swift package
(`compound-ios`, `compound-design-tokens`, `matrix-analytics-events`) ships as source.

Building one here is possible — `xcodebuild archive` plus `-create-xcframework` with
`BUILD_LIBRARY_FOR_DISTRIBUTION=YES` — so this is a choice. Two things pay for it not being made:

1. **It would re-impose the coupling `Package.swift` exists to avoid.**
   `ElementCallSDKTransport.init?(client:)` takes a `MatrixRustSDK.Client`, so that module appears in
   the module interface. The manifest declares `MatrixRustSDK` as a deliberately wide
   `"26.09.01" ..< "100.0.0"`, and the comment there explains why pinning it exactly is unacceptable.
   A prebuilt binary is compiled against whichever SDK version CI happened to have, of a
   Rust-generated API that turns over monthly.
2. **Library evolution is ongoing work** across 452 public declarations in four SwiftUI-heavy
   modules, and there is no build-time problem today that would pay for it.

**Revisit it** if a clean element-x-ios build starts spending real time in these four modules. Even
then the cheaper answers come first: a prebuilt dependency cache in the host's CI, or splitting
`ElementCallMatrix` so its SDK-typed surface is the only part left as source.

## Rehearsing locally

`scripts/release.sh` is the whole of the validation, note generation and changelog step, and it
**never touches the remote** — no commit, no tag, no push, no release. The worst it can do is leave a
modified `CHANGES.md` and a `release-notes.md` in your working tree.

```bash
gh auth login                            # it asks GitHub for the notes
git fetch --tags --prune --prune-tags     # it validates against local tags
./scripts/release.sh 0.2.0
git restore CHANGES.md                    # release-notes.md is gitignored
```

The `git fetch` is not optional. The script reads **local** tags to decide what the previous release
was and whether the version goes backwards, so a stale clone will happily tell you a version is fine
when the remote disagrees. CI has no such problem: it checks out with `fetch-depth: 0`.

The Tests-run check is skipped outside CI, where the commit is usually unpushed; pass `--dry-run` to
downgrade it to a warning rather than skip it. Everything else behaves identically.

## Repository setup

One-off, and required before the first release:

```bash
# The labels .github/release.yml categorises by, in its order, then pr-task, which it excludes
# rather than categorises, plus the record-snapshots trigger label that record-snapshots.yml waits
# for. --force so this is safe to re-run; it also means re-running it resets any colour someone has
# since changed by hand.
while read -r label colour; do
    gh label create "$label" --color "$colour" --force
done <<'LABELS'
pr-feature       0E8A16
pr-change        1D76DB
pr-bugfix        D73A4A
pr-api           D93F0B
pr-a11y          5319E7
pr-build         C5DEF5
pr-doc           0075CA
pr-wip           FBCA04
pr-misc          CFD3D7
pr-task          EDEDED
record-snapshots FEF2C0
LABELS
```

The ten `pr-` labels must exist before the first release, because `.github/release.yml` reads them
— nine to categorise by and `pr-task` to exclude — and a label that does not exist cannot be
applied. Keep this list and that file in step.

| Secret | Used for |
| --- | --- |
| *(none)* | The release workflow runs entirely on the built-in `GITHUB_TOKEN`. |
| `CODECOV_TOKEN` | `tests.yml` only. |

**There is deliberately no personal access token here.** An earlier draft pushed the release commit
straight to `main`, which needs a token that can bypass branch protection — `element-x-ios` keeps an
`ELEMENT_BOT_TOKEN` for exactly that. Releasing from a `release/*` branch removes the need: the
workflow only ever pushes to that unprotected branch and to a new tag, both of which `GITHUB_TOKEN`
can do with `contents: write`, and the changelog reaches `main` through a reviewed pull request like
any other change.

Two settings this depends on:

- **`release/*` must not be protected**, or the workflow cannot push the release commit to it.
- **The pull request back to `main` is opened by hand.** A pull request opened with `GITHUB_TOKEN`
  does not trigger other workflows, so `Tests` would not run on it; the job summary gives you the
  link rather than the workflow creating it.
