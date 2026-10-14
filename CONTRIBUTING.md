# Contributing

Thanks for taking the time. This package follows the same conventions as
[element-x-ios](https://github.com/element-hq/element-x-ios/blob/develop/CONTRIBUTING.md), and this
document only records what differs.

## Getting set up

```bash
brew install swiftformat swiftlint sourcery
```

Before you push, run what CI runs first: `swiftformat --lint . && swiftlint`. A formatting
difference fails the run before any test; `swiftformat .` fixes it.

Nothing else. In particular **no `git-lfs`**: the snapshot reference images are ordinary blobs, and
must stay that way. They lived in Git LFS once, and that made the package unresolvable by any host
on a machine without git-lfs installed — SwiftPM clones with `--mirror`, which never fetches LFS
objects, then checks out into a separate worktree where the smudge filter fires and fails
([swift-package-manager#5351], open since 2018). Xcode Cloud has no git-lfs at all, so element-x-ios
could not build against a tag of this package.

So do not put them back for the sake of repository size. It is 5.5 MB of images against a 1.4 GB
media xcframework that a checkout does not even carry, and the growth is bounded by re-recording
only what fails — see the comment in `.github/workflows/record-snapshots.yml`, which is there for
that reason as much as for keeping a reviewer's diff small.

[swift-package-manager#5351]: https://github.com/swiftlang/swift-package-manager/issues/5351

## The boundaries this package defends

Three of the four modules must compile knowing nothing about the host application, and one of them is
allowed to know the SDK:

| Module | May import |
| --- | --- |
| `ElementCallKit` | the RTC core only |
| `ElementCallHost` | nothing beyond the RTC core |
| `ElementCallUI` | the design **tokens** package |
| `ElementCallMatrix` | the Matrix SDK |

Concretely:

- **`MatrixRustSDK` only in `ElementCallMatrix`.** That module exists to speak to the SDK, so the rule
  would protect nothing there. Everywhere else, go through `ElementCallMatrixTransportProtocol`.
- **Never `import Compound`, anywhere.** Its colours live on a single shared instance the host
  re-brands at runtime, so a copy linked in here would never see the override and a re-branded host
  would get a stock-coloured call screen. Take colours through `ElementCallThemeProtocol` and icons through
  `ElementCallIconRenderingProtocol`, and keep every member a computed property so it is read at draw time.
  The `CompoundDesignTokens` package is fine: static values, no shared instance.
- **No host logger, settings or localisation.** Those are `ElementCallLoggingProtocol`, `ElementCallOptions`
  and `ElementCallStrings`.

SwiftLint enforces the first two at error severity. If you need something new from the host, add a
port rather than a dependency.

Accessibility identifiers on the call UI are **public API**. An external interop test rig drives real
host builds through them, so treat a rename as a breaking change. `ElementCallAccessibilityIdentifiers`
has tests asserting the exact strings, which exist to make a rename a deliberate act rather than a
surprise.

## Etiquette

- Be kind and assume good intent.
- Keep pull requests small enough to review in one sitting. Split anything above roughly 500 lines of
  production code.
- Commits need a title and a description. No tiny commits, no enormous ones, and no history rewrites
  on a branch under review.
- Discuss a design before writing it if it changes a port, since ports are consumed by other
  repositories.

## Changelog

Release notes are generated from pull request labels, so every pull request needs **exactly one**
`pr-` label. See [`.github/release.yml`](.github/release.yml) for the list. The pull request title
becomes the changelog entry, so write it as a sentence describing the change rather than referring to
an issue number.

Use **`pr-task`** for a change no host could observe — CI plumbing, test-only churn, a repository
chore. It is excluded from the notes rather than categorised, so the pull request gets no changelog
line at all. It is the only label that does that, so an absent entry is always a decision someone
made rather than a label someone forgot.

Nothing enforces this: no workflow fails over a missing label, so a reviewer noticing is the only
thing keeping an entry out of the catch-all *Others* heading. It is recoverable — the notes are
generated when a release is cut, not when a pull request merges, so labelling a merged pull request
still works — but the person cutting the release has to spot it.

There is **one case where you also write in [`CHANGES.md`](CHANGES.md) by hand**: something a host has
to act on, such as a renamed accessibility identifier, a port gaining a requirement, or a new build
setting. Add it under `## Unreleased` and the release will carry it into that version's section, above
the generated list, where whoever bumps the version will read it. Ordinary changes need nothing there.

See [RELEASING.md](RELEASING.md) for how a release is cut.

## Tests

```bash
sourcery --config Tools/Sourcery/PreviewTestsConfig.yml   # from Tools/Sourcery

xcodebuild test -scheme ElementCall-Package \
  -destination "id=$SIMULATOR_UDID" \
  -testLanguage en -testRegion GB \
  OTHER_LDFLAGS='$(inherited) -ObjC'
```

Three parts of that are not optional, and each fails in a way that does not name its own cause:

- **`-ObjC`**, or the test bundle links and then dies on launch with an unrecognised selector. Library
  targets never link, so a plain `swift build` passes without it and proves nothing.
- **A concrete simulator by id**, not a generic destination, which also builds an architecture the
  media xcframework has no slice for.
- **`-testLanguage en -testRegion GB`**, because snapshot file names carry the locale. element-x-ios
  pins this in a test plan, which a package does not have. The harness asserts it and tells you what
  to pass, rather than letting 42 snapshots fail.

The pinned device and OS live in `Tests/ElementCallTests/Support/SnapshotEnvironment.swift`, which the
workflow reads, so there is one place to change them.

| Layer | Where |
| --- | --- |
| Pure logic | `Tests/ElementCallTests`, runs anywhere |
| Snapshots from previews | same target, needs the pinned simulator |
| Widget bridge wire protocol | same target, fakes the driver channel with a pair of pipes |
| Real media call | needs the `demo/backend` docker stack from matrix-rust-rtc, run by hand |

Add previews for every main state of a view, conform them to `TestablePreview`, and use
`PreviewProvider` rather than the `#Preview` macro so the snapshot cases can be generated. Re-record
with `RECORD_FAILURES=true` in the environment, or by adding the `record-snapshots` label to a pull
request.
