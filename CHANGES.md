# Changelog

Entries under a released version are **generated when the release is cut**, from the `pr-` label on
each merged pull request — see [RELEASING.md](RELEASING.md). There is nothing to add here for an
ordinary change; label the pull request and write a title that reads as a changelog line.

`Unreleased` is for the exception: something a host has to **act** on. A renamed accessibility
identifier, a port gaining a requirement, a new build setting. Write that here by hand, and the
release will carry it into its own section above the generated list, where a host bumping the
version will actually read it.

## Unreleased

**`ElementCallActiveSpeakerGradient` is now `ElementCallBorderGradient.activeSpeaker`**, beside
`.raisedHand`. A host theme that draws its own speaking ring can do the same for a raised hand by
implementing `raisedHandBorder(in:)`; the default is design's.

## 0.1.0-rc.10 - 2026-10-08

**`MatrixRTCCall` is renamed `MatrixRTCMediaSession`, and `MatrixRTCElementCallCompat` is renamed
`MatrixRTCMembershipFormat`.** The cases are `current`, `sticky2025` and `roomState` (were `off`,
`stickyEvents` and `stateEvents`), and `ElementCallOptions.elementCallCompatibility` is
`membershipFormat`.

**The core is room-first, and the Matrix port is per room.** `ElementCallStack.start()` and `stop()`
are gone: there is nothing to start. A host implementing `ElementCallMatrixTransportProtocol` itself
implements `openRoom(roomID:)`, returning an `ElementCallMatrixRoomProtocol` that carries every room
send and feed and is closed when the call ends; transport discovery moves onto the room as raw JSON.
Every set-shaped feed delivers its current set first, an empty one included, and events cross as raw
`ElementCallRoomEvent`s. Report failures as `MatrixRTCTransportError.failed` with the homeserver's
`errcode` and status rather than classifying them, and `MatrixRTCToDeviceMessage.isSenderCrossSigned`
is optional, nil when the client does not say. `ElementCallController.session` is `rtcCall`, a
`MatrixRTCCall`, and a call whose slot is closed ends with `MatrixRTCEndReason.slotClosed`. Hosts using
`ElementCallSDKTransport` change nothing but the `start()` call.

**`ElementCallThemeProtocol` gains `activeSpeakerBorder(in:)`, the fill of the speaking ring.** It
defaults to the design's gradient; implement it to brand the ring, returning one colour for a plain one.



### What's Changed

✨ Features
* Show/Hide control bar behavior. by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/50
* Show the matrix-rust-rtc version in the overflow menu by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/53
* New optimized layout for small calls, 1:1 and less than 5 by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/55
* Make the audio button a menu when a headset is connected by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/56

🐛 Bugfixes
* Fix: Draw the speaking ring as per design's gradient by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/54

Others
* Release 0.1.0-rc.9 by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/49


**Full Changelog**: https://github.com/element-hq/element-call-ios/compare/0.1.0-rc.9...0.1.0-rc.10

## 0.1.0-rc.9 - 2026-09-29

**`ElementCallLayout` and `ElementCallScreenViewState.layout` are removed, and
`ElementCallScreenViewState.spotlightID` is stored rather than computed.** The one-to-one arrangement
(the other person full-bleed, ourselves as a thumbnail) is retired by the call layout spec: two people
share the stage equally, in direct rooms too. The spotlight is no longer "the hero, else the head of
the ranking": with nobody sharing and at most ten remote members there is no spotlight and every tile
is the same size; above ten the spotlight follows the speaker. `ElementCallController.spotlightTileID`
is written by the screen through `setSpotlightTile(_:)` and is nil whenever there is no spotlight, so
a host reading it for Picture in Picture gets the window's own fallback rather than a guess.

**The layout drives the core's cost controls.** `MatrixRTCCall.setDetailWindow(_:)` declares a
`MatrixRTCDetailWindow` (a rank range plus explicit tiles) and `setVideoVisibility(paused:released:)`
replaces `setReleasedVideoStreams(_:)` as the way the stage names what it is not showing; the old
method remains as a shorthand. A host that drew the stage itself would have to declare both.
`ElementCallScreenContext.shownHeroID` is the hero the user swiped to and `scrollRequest` asks the
stage for an offset (for a harness; a host never needs it); the
`elementCall.heroIndicator` identifier is new and public like the others. The harness types
`MatrixRTCScenario`, `MatrixRTCScriptedSession`, `MatrixRTCScenarioPlayer` and `MatrixRTCManualClock`
ship in `ElementCallKit` for the example app and the scenario tests, and `ElementCallController.fake`
can carry a scripted call.

**`MatrixRTCCallEvent.activeSpeakers` and `MatrixRTCSpeakingMember` are removed.** Speaking is
`MatrixRTCTile.isSpeaking`. Remote audio playback follows the tile roster's `order` rather than
`streamStarted`/`streamStopped`, so a lagging event consumer can no longer leave anyone silent.
`MatrixRTCCall.participants` is read once at connect and no longer kept live; `hasVideo`,
`pictureInPictureCandidate` and `pictureInPicturePlaceholderMemberID` read the tile roster instead, and the
two static forms take `tiles:` rather than `participants:`. The stats overlay's `NO MIC STREAM` line is
gone; the Kit still logs once, at warning, when a member's microphone cannot be opened.

**`MatrixRTCCall.receiveStats` is keyed by `MatrixRTCStreamRef(memberID:, kind:)`, per stream, and
covers only what is drawn.** It used to be keyed by member ID and hold the microphone counters alone, so
a share tile showed its owner's audio and "frames dropped" was always zero. It now holds each drawn
tile's own stream (`MatrixRTCStreamRef(tile.id)`) and its member's microphone (`kind: .microphone`), read
in one core round trip a second for the tiles on the stage rather than one await per member. Tiles released by
`setReleasedVideoStreams(_:)` are not polled.

**`MatrixRTCTileRef` carries `userID`.** A tile outside the declared detail window has no
`MatrixRTCTile`, but its reference now says whose it is, which is what a name and an avatar resolve
through. Anything constructing a `MatrixRTCTileRef` passes it.

**`ElementCallTile.audioLevel` is removed.** No view ever drew it, and projecting it made the call
screen rebuild ten times a second, which left the top bar's menu dropping taps. Use `isSpeaking` if
you need to know who is talking.

**A screen share is now a tile of its own, and a tile is identified by member *and* stream.** The
Rust core hands us a ranked list of call tiles rather than a participant list, and a member
publishing a camera and a screen share is two of them, drawn at the same time. Ordering, its
hysteresis and its coalescing are the model's now; this app renders the order it is given.

For an interop rig driving accessibility identifiers, **nothing you pin has moved**, but there is
more on screen than there was:

| | |
| --- | --- |
| `elementCall.tile.<memberID>` | that member's **camera** — unchanged |
| `elementCall.tile.<memberID>/screenShare` | that member's **screen** — new, and on the stage at the same time as their camera |

Three consequences worth checking a rig for:

- Collecting tile identifiers into a set, or counting tiles to count people, now sees two entries for
  a sharer. This previously *under*-counted, silently, because both tiles carried one identifier.
- Addressing a sharer's *picture* by their member ID now gets their camera. It used to get their
  screen whenever the tile happened to be large, which was never something the identifier said.
- A share tile appears and disappears with the share; it is not a state of a member's tile.

For a host reading the view state:

- `ElementCallTile.id` is `ElementCallTileID`-shaped (`MatrixRTCTileID`: a `memberID` and a `kind`)
  rather than a `String`. `tile.memberID` still gives you the member.
- `ElementCallTile.isScreenSharing` is gone — `tile.kind == .screenShare`, or `tile.isScreenShare`.
- `ElementCallTile.hasMicrophone` and `.isFrontCamera` are gone. The core does not supply them per
  tile and nothing drew them. The equivalents are still on the call:
  `MatrixRTCParticipant.stream(.microphone)` and `MatrixRTCCall.isFrontCamera`.
- `ElementCallTile.isHero` is new: the model marks the tile worth the largest slot.
- `ElementCallScreenViewState.spotlightMemberID` is gone. The list is ranked, so the spotlight is
  derived — read `ElementCallScreenViewState.spotlightID`.
- `ElementCallScreenContext.fullscreenMemberID` is now `fullscreenTileID`.
- `ElementCallController.spotlightMemberID` is now `spotlightTileID`, and is computed rather than
  stored.
- `MatrixRTCCall.setReleasedVideoMembers(_:)` is now `setReleasedVideoStreams(_:)` and takes tile
  identities. Releasing by member took down a sharer's screen when their camera paged away.
- `MatrixRTCCall.activeSpeakerIDs` is gone; speaking is a field on each tile.
- `MatrixRTCCall.pictureInPictureCandidate(spotlightMemberID:)` and
  `pictureInPicturePlaceholderMemberID(spotlightMemberID:)` take `spotlight:` as a tile identity; the
  first returns one too.
- `ElementCallPreviewFixtures.tile(...)` drops `hasMicrophone:` and `isScreenSharing:` and gains
  `kind:` and `isHero:`; `ElementCallPreviewFixtures.share(_:)` builds a share tile;
  `connected(spotlight:)` is gone, because the order of `tiles:` is the ranking.

**`MatrixRTCCall.isScreenSharing` is now derived from publication state**, not from what the app
asked for, so it goes false however a share ended. A capture stopped from outside the app — Control
Centre, another app taking the recorder — now unpublishes rather than leaving a dead share published.



### What's Changed

✨ Features
* Feat: New grid-layout with hero spotlight when needed by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/46

🐛 Bugfixes
* Fix: Legacy Format, stop inferring a sender device for key messages that name none by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/45

🧱 Build
* chore: Use the new core tiles model by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/41


**Full Changelog**: https://github.com/element-hq/element-call-ios/compare/0.1.0-rc.8...0.1.0-rc.9

## 0.1.0-rc.8 - 2026-09-22



### What's Changed

🐛 Bugfixes
* Fix: Option menu keep getting re-drawn by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/37

🧱 Build
* chore: Bump rust-rtc to 0.3.0-rc.2 by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/38


**Full Changelog**: https://github.com/element-hq/element-call-ios/compare/0.1.0-rc.7...0.1.0-rc.8

**A screen share is now a tile of its own, and a tile is identified by member *and* stream.** The
Rust core hands us a ranked list of call tiles rather than a participant list, and a member
publishing a camera and a screen share is two of them, drawn at the same time. Ordering, its
hysteresis and its coalescing are the model's now; this app renders the order it is given.

For an interop rig driving accessibility identifiers, **nothing you pin has moved**, but there is
more on screen than there was:

| | |
| --- | --- |
| `elementCall.tile.<memberID>` | that member's **camera** — unchanged |
| `elementCall.tile.<memberID>/screenShare` | that member's **screen** — new, and on the stage at the same time as their camera |

Three consequences worth checking a rig for:

- Collecting tile identifiers into a set, or counting tiles to count people, now sees two entries for
  a sharer. This previously *under*-counted, silently, because both tiles carried one identifier.
- Addressing a sharer's *picture* by their member ID now gets their camera. It used to get their
  screen whenever the tile happened to be large, which was never something the identifier said.
- A share tile appears and disappears with the share; it is not a state of a member's tile.

For a host reading the view state:

- `ElementCallTile.id` is a `MatrixRTCTileID`: a `memberID` and a `MatrixRTCTileKind`, `.person` or
  `.screenShare` — what the tile *is*, not which stream. The stream a tile draws is
  `kind.videoStreamKind`. `tile.memberID` still gives you the member.
- `ElementCallTile.isScreenSharing` is gone — `tile.kind == .screenShare`, or `tile.isScreenShare`.
- `ElementCallTile.hasMicrophone` and `.isFrontCamera` are gone. The core does not supply them per
  tile and nothing drew them. The equivalents are still on the call:
  `MatrixRTCParticipant.stream(.microphone)` and `MatrixRTCCall.isFrontCamera`.
- `ElementCallTile.isHero` is new: the model marks the tile worth the largest slot.
- `ElementCallScreenViewState.spotlightMemberID` is gone. The list is ranked, so the spotlight is
  derived — read `ElementCallScreenViewState.spotlightID`.
- `ElementCallScreenContext.fullscreenMemberID` is now `fullscreenTileID`.
- `ElementCallController.spotlightMemberID` is now `spotlightTileID`, and is computed rather than
  stored.
- `MatrixRTCCall.setReleasedVideoMembers(_:)` is now `setReleasedVideoStreams(_:)` and takes tile
  identities. Releasing by member took down a sharer's screen when their camera paged away.
- `MatrixRTCCall.activeSpeakerIDs` is gone; speaking is a field on each tile.
- `MatrixRTCTileRef` carries `userID`: a tile outside the declared detail window has no
  `MatrixRTCTile`, but its reference still says whose it is, which is what a name and an avatar
  resolve through. Anything constructing one passes it.
- `MatrixRTCCall.pictureInPictureCandidate(spotlightMemberID:)` and
  `pictureInPicturePlaceholderMemberID(spotlightMemberID:)` take `spotlight:` as a tile identity; the
  first returns one too.
- `ElementCallPreviewFixtures.tile(...)` drops `hasMicrophone:` and `isScreenSharing:` and gains
  `kind:` and `isHero:`; `ElementCallPreviewFixtures.share(_:)` builds a share tile;
  `connected(spotlight:)` is gone, because the order of `tiles:` is the ranking.

**`MatrixRTCCall.isScreenSharing` is now derived from publication state**, not from what the app
asked for, so it goes false however a share ended. A capture stopped from outside the app — Control
Centre, another app taking the recorder — now unpublishes rather than leaving a dead share published.

## 0.1.0-rc.7 - 2026-09-21

**`matrix-rust-rtc` moved to `element-hq`**, pinned at `0.3.0-rc.1` (was `BillCarsonFr` at
`0.2.0-rc.1`). No API change. If you declare `matrix-rust-rtc` yourself, switch to the new URL in the
same commit: both spellings share the identity `matrix-rust-rtc`, so declaring them together fails
resolution.

**Every port protocol now ends in `Protocol`.** Requested by the host: element-x-ios suffixes every
protocol it owns, so the package's ports were the only unsuffixed ones in files that otherwise carry
the suffix throughout. Seven renames, and nothing but the names changed:

| Was | Now |
| --- | --- |
| `ElementCallMatrixTransport` | `ElementCallMatrixTransportProtocol` |
| `ElementCallLogging` | `ElementCallLoggingProtocol` |
| `ElementCallTheme` | `ElementCallThemeProtocol` |
| `ElementCallIconRendering` | `ElementCallIconRenderingProtocol` |
| `ElementCallAvatarRendering` | `ElementCallAvatarRenderingProtocol` |
| `ElementCallSystemProviding` | `ElementCallSystemProvidingProtocol` |
| `ElementCallRoomContext` | `ElementCallRoomContextProtocol` |

A host updates its conformance declarations and any stored-property or parameter types spelled with
the old name. The compiler finds all of them.

**The concrete types keep their plain names** — `ElementCallTokenTheme`, `ElementCallTokenIcons`,
`ElementCallTokenAvatars`, `ElementCallSDKTransport` and the `ElementCallFake*` family are untouched,
as is `ElementCallStrings`, which is a struct rather than a port. So is every method on every port:
no requirement was added, removed or resignatured.

**The settings port is now a struct, and `areTileStatsAvailable` is now `isDeveloperModeEnabled`.**
`ElementCallOptionsProtocol` and `ElementCallDefaultOptions` are both gone, replaced by one value
type:

```swift
options: ElementCallOptions(isDeveloperModeEnabled: appSettings.developerOptionsEnabled)
```

Every member is defaulted, so a host states only what it wants to change — the defaults are Picture
in Picture on, `.stateEvents` compatibility, developer mode off, automatic Picture in Picture for
audio calls off. **A host that had a type conforming to the port can delete it**; pass a constructed
`ElementCallOptions` instead. Note this is the only port that lost its `Protocol` suffix in the same
release it gained one: a concrete type keeps a plain name, so the spelling is `ElementCallOptions`,
which is what it was called before either change.

It is read once, when the stack is built, rather than on every access. Nothing in the call ever
needed a fresher value — compatibility is read when a session joins, the Picture in Picture flags
when the window binds, developer mode when a toggle is tapped — so a host backing these with live
settings should know the values are captured. If that is a problem for you, say so and the stack can
gain a setter.

**Developer mode gates the stats overlay, and hides it.** The overflow menu now holds a
**Developer Options** submenu, and `isDeveloperModeEnabled` decides whether that submenu exists at
all — previously the "Tile stats" toggle was shown unconditionally and the tap was silently refused.
The toggle inside carries a checkmark, so reopening the menu says whether the overlay is on. Point
this at whatever reveals developer surface in your app, not at the flag that enables calls: the
overlay is raw RTP counters in 9pt monospace and is not meant for ordinary users.

**The audio test tone is gone.** The 440 Hz sine that could be injected into the microphone from the
overflow menu, and the generator behind it, are removed outright — it was an early bring-up aid and
had outlived its purpose. `MatrixRTCCall.setAudioTestToneEnabled(_:)`,
`ElementCallController.setAudioTestToneEnabled(_:)` and the `isAudioTestToneEnabled` view-state
property are all deleted; a host calling any of them will not compile.

**Screen sharing is now opt-in, through `isScreenSharingEnabled`, and defaults to off.** It needs
work on the host side before a share behaves, so a host asks for it when it is ready rather than
finding the feature half-wired. Deliberately *not* folded into developer mode: a host may want to
ship sharing to everyone while keeping diagnostics to itself, so the two are separate axes — wire
this to your developer flag today and change one line later.

With it off, the share button is absent from the control bar and `setScreenShareEnabled(true)` is
refused. **Receiving a share is unaffected**: a remote presenter still takes the spotlight, renders,
and is labelled, because a call with a Web peer sharing would otherwise look broken. Stopping a share
is never gated either, so one already in flight can always be ended.

The screen share entry is also **gone from the overflow menu**, where it duplicated the control bar
button exactly. The bar is where a user reaches for it; the menu is now diagnostics only.

**The call screen shows the package version**, as a disabled `version: <semver>` row at the foot of
the overflow menu, so a bug report can quote it — readable as `ElementCallVersion.current` if a host
wants it elsewhere. It is stamped by the release, so it is exact for any host that resolves a tag.



### What's Changed

🐛 Bugfixes
* Fix: Cannot enter PIP mode when alone in the call by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/33

⚠️ API Changes
* Suffix every port protocol with Protocol by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/29
* Make the settings port a value, and gate screen sharing and diagnostics by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/30

🧱 Build
* chore: Bump rust-rtc release 0.3.0-rc.1 by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/35


**Full Changelog**: https://github.com/element-hq/element-call-ios/compare/0.1.0-rc.5...0.1.0-rc.7

## 0.1.0-rc.5 - 2026-09-16

**`import ElementCallAll` is now `import ElementCall`, and the product is `ElementCall`.** The
umbrella module — the one that does nothing but re-export the four layers — has taken the bare name,
because that is the name an integrating app reaches for and there was no answer to "why `All`?" beyond
"the name was taken". Two edits in a host:

- every `import ElementCallAll` becomes `import ElementCall`;
- `product: ElementCallAll` becomes `product: ElementCall` (or
  `.product(name: "ElementCall", package: "element-call-ios")`).

`ElementCallAll` is gone rather than deprecated, so both show up as errors: an unresolved product at
resolution and an unknown module at build.

**The module formerly named `ElementCall` is now `ElementCallHost`**: the call lifecycle, Picture in
Picture, and the ports. A host importing the umbrella never names it and has nothing to do. A host
that depended on the `ElementCall` *product* to get only that layer must switch to `ElementCallHost`
— the `ElementCall` product now vends everything, so such a host keeps compiling but links the view
and transport layers it was deliberately avoiding.

Nothing else moved: the four boundaries, every public type name, and every accessibility identifier
are unchanged.



### What's Changed

⚠️ API Changes
* Packaging: Rename ElementCallAll import to ElementCall  by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/27


**Full Changelog**: https://github.com/element-hq/element-call-ios/compare/0.1.0-rc.4...0.1.0-rc.5

## 0.1.0-rc.4 - 2026-09-14

**This package no longer uses Git LFS**, and this is the first version a host can resolve without
`git-lfs` installed. Every earlier tag fails on Xcode Cloud, which has no `git-lfs` on the image:

> Couldn't check out revision '…' — git-lfs command not found

Nothing to act on beyond bumping to this version. `git-lfs` is no longer needed to work on the
package either, and can come off a development machine once no older tag is in use — but leave the
LFS objects on the remote, because tags up to and including 0.1.0-rc.3 still point at pointer blobs
and cannot be checked out without them.

The snapshot reference images are ordinary blobs now. They were the only thing in LFS, and SwiftPM
cannot cope with it at all: it clones with `--mirror`, which never fetches LFS objects, then checks
out into a separate worktree where the smudge filter fires and fails
([swift-package-manager#5351](https://github.com/swiftlang/swift-package-manager/issues/5351), open
since 2018). History is untouched; only the filter is gone.



### What's Changed

✨ Features
* Double-tap a tile to fill the screen with it by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/24

🧱 Build
* Store the snapshot references as ordinary blobs, not Git LFS by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/25


**Full Changelog**: https://github.com/element-hq/element-call-ios/compare/0.1.0-rc.3...0.1.0-rc.4

## 0.1.0-rc.3 - 2026-09-11

**`compound-design-tokens` is now a range starting at 11.0.0**, where it was pinned exactly at
10.2.4. Nothing in the public surface changes, but a host whose Compound still resolves tokens below
11.0.0 will no longer resolve against this package at all — update Compound first.

The exact pin was the problem. Two `exact` requirements on one package have no solution, so once
`compound-ios` moved to tokens 11.0.0 the integration failed at resolution, before anything compiled.
The range means a host bumping Compound ahead of a release here no longer has to wait for one.



### What's Changed

🧱 Build
* Import Compound as a range to avoid resolution problems on exi by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/21


**Full Changelog**: https://github.com/element-hq/element-call-ios/compare/0.1.0-rc.2...0.1.0-rc.3

## 0.1.0-rc.2 - 2026-09-11

**Every `MatrixRtc*` type is now `MatrixRTC*`** — `MatrixRTCCall`, `MatrixRTCSession`,
`MatrixRTCParticipant`, `MatrixRTCLogRecord` and the rest, 33 public types in all. Initialisms are
uniformly cased per the Swift API Design Guidelines. A find-and-replace of `MatrixRtc` followed by
an uppercase letter covers a host's whole migration.

Two things keep the old spelling because they are not ours: the bindings' module, so
`import MatrixRtc` is unchanged, and the bindings' own `MatrixRtcFFI` and `MatrixRtcFfiError`.

**`ElementCallLogging` now takes a record.** Replace

```swift
func log(_ level: ElementCallLogLevel, _ message: String) { … }
```

with

```swift
func log(_ record: ElementCallLogRecord) { … }
```

`ElementCallLogRecord` carries `level`, `message`, `file` and `line`, where `file` is the `#fileID`
of our own call site — so a host formatting logs with a position can stop passing a placeholder.
Call sites are unchanged: `log(_:_:)` still exists as a convenience that fills in the position.

**`MatrixRTCLogRecord` gained `file`, `line`, `timestampMs` and `thread`**, which the Rust core was
already providing and we were dropping. Nothing to change — the struct is only constructed inside
the package — but a host putting `target` in the file slot can now use `file`, and one stamping its
own receive time should prefer `timestampMs`, which is when the record was emitted.

**Minimizing an audio call now opens a Picture in Picture window** showing the avatar placeholder,
where it previously reported `pictureInPictureUnavailable`. A host that puts up its own minimized
bar will stop seeing that action for audio calls — the bar is still used when the window genuinely
cannot open: the host disabled it, the device does not support it, or a screen share is running.
Nothing to change unless the bar was relied on as the audio-call presentation.

`ElementCallOptions` gains `isAutomaticPictureInPictureForAudioCallsEnabled`, which governs whether
*backgrounding* the app during an audio call opens the window by itself. It has a default of
`false`, so existing conformances keep compiling and behaviour is unchanged; set it to `true` to opt
in. Minimizing on purpose is not affected by it.



### What's Changed

🙌 Improvements
* Carry file and line through both log ports by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/9

🐛 Bugfixes
* Fixes the hang-up deadlock by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/6
* Show the avatar until a stream actually delivers a frame by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/11
* App running on macOS dies on call start with an uncatchable AVFAudio exception by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/12
* Fix: Audio not starting on iOS app by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/14

⚠️ API Changes
* Open Picture in Picture for audio calls, showing the avatar by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/7
* Add an umbrella product so a host takes one dependency by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/8
* Rename MatrixRtc types to MatrixRTC by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/10

🧱 Build
* Release 0.1.0-rc.1 by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/5
* Declare the render-block boxes Sendable by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/13


**Full Changelog**: https://github.com/element-hq/element-call-ios/compare/0.1.0-rc.1...0.1.0-rc.2

## 0.1.0-rc.1 - 2026-09-09

Initial release: a native [MatrixRTC](https://github.com/matrix-org/matrix-spec-proposals/blob/main/proposals/4143-matrix-rtc.md)
implementation of Element Call for iOS. Audio and video calls the app renders itself, with no web view
involved.

The integration a web view cannot reach is the point of it. Calls are driven by the host's CallKit
provider, so they behave like calls — system call UI, the lock screen, and interruptions from other
apps. Audio routing follows the system's own choice of earpiece, headset or Bluetooth, and asks for
the speaker on a video call. Screen sharing captures through ReplayKit, and the call keeps rendering
in Picture in Picture when the app goes to the background.

**Four things a host has to do**, none of them optional:

- **Implement three ports:** `ElementCallSystemProviding` (your CallKit provider, plus audio-session
  and mute events coming back), `ElementCallRoomContext` and `ElementCallAvatarRendering`. The rest is
  turnkey — `ElementCallSDKTransport` covers the whole Matrix side, and theming, icons, strings,
  options and logging all have defaults.
- **Add `-ObjC`** to the app target's Other Linker Flags. Without it libwebrtc's Objective-C
  categories are dead-stripped from the static archive, so the app builds and then aborts at runtime
  on an unrecognised selector. Measured cost: 15.7 MiB on the linked binary.
- **Set `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`.** The media xcframework ships device and
  Apple Silicon simulator slices only, and a package cannot declare this for the projects that
  consume it.
- **Build `ElementCallStack` when the session is created, not when a call starts.** To-device
  delivery has no catch-up, so a stack that subscribes after its own membership has gone out can miss
  the keys sent in that window, and the first remote frames arrive black.

Consumed as a **source** dependency, pinned to an exact version — see the README for why.



### What's Changed

✨ Features
* Basic landscape layout support (not final) by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/1

🧱 Build
* Release pipeline by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/2
* Fixup dry run by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/3
* Devx/ci relax by @BillCarsonFr in https://github.com/element-hq/element-call-ios/pull/4

### New Contributors
* @BillCarsonFr made their first contribution in https://github.com/element-hq/element-call-ios/pull/1

**Full Changelog**: https://github.com/element-hq/element-call-ios/commits/0.1.0-rc.1

