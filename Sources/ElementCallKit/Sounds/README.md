# Call sounds

Element Call web's own files, copied unchanged so a call sounds the same on every client in it
(spec 024, R3; spec 009, R34). Do not re-encode them: the hashes are how a reviewer checks they still match web.

| File | Source | SHA-256 |
| :--- | :--- | :--- |
| `join_call.mp3` | `element-call` `src/sound/join_call.mp3` at ea6f2952a | `2a5e12c8470f6602249577e6c783231d70e80784504bae419a299330bc5a53f8` |
| `left_call.mp3` | `element-call` `src/sound/left_call.mp3` at ea6f2952a | `5f4c529262388c3cae87df5957e9607ac438cba2be08d1b84484adf73c137971` |
| `raise_hand.mp3` | `element-call` `src/sound/raise_hand.mp3` at ea6f2952a | `0601948ad6e4937cc6bca126f0decb2218037f39f6f7dc99cee359efdb66212b` |

The mp3s rather than web's `.ogg` twins because AVFoundation does not decode Ogg Vorbis.
`raise_hand.mp3` is 24 kHz, and is resampled to the engine's 48 kHz when decoded.
