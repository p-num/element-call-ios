# Call sounds

Element Call web's own files, copied unchanged so a call sounds the same on every client in it
(spec 024, R3; spec 009, R34; spec 030, R23 and R25; spec 037, R9). Do not re-encode them: the hashes are how a reviewer checks they still match web.

| File | Source | SHA-256 |
| :--- | :--- | :--- |
| `join_call.mp3` | `element-call` `src/sound/join_call.mp3` at ea6f2952a | `2a5e12c8470f6602249577e6c783231d70e80784504bae419a299330bc5a53f8` |
| `left_call.mp3` | `element-call` `src/sound/left_call.mp3` at ea6f2952a | `5f4c529262388c3cae87df5957e9607ac438cba2be08d1b84484adf73c137971` |
| `raise_hand.mp3` | `element-call` `src/sound/raise_hand.mp3` at ea6f2952a | `0601948ad6e4937cc6bca126f0decb2218037f39f6f7dc99cee359efdb66212b` |
| `ringtone.mp3` | `element-call` `src/sound/ringtone.mp3` at 956671eef | `f4528c08f5e362b9c5b3693a3349bd9224d32c586953e1d180e90c5414d626c4` |
| `call_declined.mp3` | `element-call` `src/sound/call_declined.mp3` at 956671eef | `bb8d93337c6d8a391fbc7750ce5fb955413ba084183a76c22aba5016f8d0e06b` |
| `call_timeout.mp3` | `element-call` `src/sound/call_timeout.mp3` at 956671eef | `c0aed0c09a85d580824847988e6868121c1329997cf8a3df88a42895adbf3ddd` |
| `reactions/baduntss.mp3` | `element-call` `src/sound/reactions/baduntss.mp3` at eb44fd545 | `48c30e2259598e3de9880d95b1075fcb7aa35a9b41ab94447f22534dc3b3d1e0` |
| `reactions/bell.mp3` | `element-call` `src/sound/reactions/bell.mp3` at eb44fd545 | `d489ccd5e386072e9db47c9a332ef4f33130cf940e1ddde55d062835ae197bb8` |
| `reactions/cat.mp3` | `element-call` `src/sound/reactions/cat.mp3` at eb44fd545 | `cbf49e888bcf2213145fa43045c3493746c8b2fc3cbebadf6727a244ec60ac4d` |
| `reactions/clap.mp3` | `element-call` `src/sound/reactions/clap.mp3` at eb44fd545 | `b927e4bd51c781fb0232b7430b13aa56cf7e9e1bf8a3b049a0011312ce5c8830` |
| `reactions/crickets.mp3` | `element-call` `src/sound/reactions/crickets.mp3` at eb44fd545 | `f7949e8f092a8653f3da9f4d117be8cbc61b68c580bb43f610838df0061da8de` |
| `reactions/deer.mp3` | `element-call` `src/sound/reactions/deer.mp3` at eb44fd545 | `e9fdba54df8e31091c311b61bc16413accaebfc5b3bf18c6b7761577ac354c6c` |
| `reactions/dog.mp3` | `element-call` `src/sound/reactions/dog.mp3` at eb44fd545 | `0b0ce7ea208cd900c11e4743e9c25a6633d7d6e750bd8d5d34f1d3119a469260` |
| `reactions/generic.mp3` | `element-call` `src/sound/reactions/generic.mp3` at eb44fd545 | `748e6d03a559ac909d04b9fa907fca3424c6bf00aa45bcad3f6a07238e58f6cb` |
| `reactions/lightbulb.mp3` | `element-call` `src/sound/reactions/lightbulb.mp3` at eb44fd545 | `2471aac761484adb8c2485954016b93af907d14a4d03afdcffe0a5749f489bb0` |
| `reactions/party.mp3` | `element-call` `src/sound/reactions/party.mp3` at eb44fd545 | `3ab05da72c326143027e1bae16e005512e94eb8985d978a10eb9016f088a6b79` |
| `reactions/rock.mp3` | `element-call` `src/sound/reactions/rock.mp3` at eb44fd545 | `337166ae2fb7cac96b8c5fd6d2872dfd88105fc59363101846f3d55c30986531` |
| `reactions/wave.mp3` | `element-call` `src/sound/reactions/wave.mp3` at eb44fd545 | `4391d019809c9951333cd8ab9f5329b039602334bb55f5855b7852321109a6ac` |

The mp3s rather than web's `.ogg` twins because AVFoundation does not decode Ogg Vorbis.
`raise_hand.mp3` is 24 kHz, and is resampled to the engine's 48 kHz when decoded.
The reaction files are 24, 44.1 and 48 kHz and are resampled the same way. Licensed as web's
`src/sound/LICENCE.md` says: Pixabay for most, Element's own for `rock`, `wave` and `baduntss`; `deer` is not listed there.
