# SpotifyEQPro 0.2 — jailed test build

A ten-band equalizer and editable custom presets for the EeveeSpotify IPA supplied for this project. No jailbreak, Substrate, inline code patches, global C-function hooks, or external tweak loader are required by SpotifyEQPro. The dylib is embedded into the app before normal sideload signing.

## Features

- EQ preset button in the full-size Now Playing screen.
- Replacement equalizer page with 31 / 63 / 125 / 250 / 500 Hz and 1 / 2 / 4 / 8 / 16 kHz controls.
- Actual dB values, in 0.5 dB steps, with the requested -96 to +24 range intersected with the live AudioUnit's reported limits. Long-press a band for minimum, zero, or maximum.
- User-editable presets in place of the stock selection: save, rename, overwrite, delete. Initial custom curves: Neutral, Sub Bass, Punch, Stimmen, Brillant.
- Persistent controls and presets in the app sandbox.
- Optional conservative headroom compensation, capped at -96 dB. This is not a limiter and does not guarantee clipping prevention for every extreme combination.
- Status and shareable diagnostics in the EQ page.

## Audio integration

This version was matched against the Objective-C metadata and audio-driver implementation in the supplied IPA (bundle ID `com.spotify.client`, reported version `2.5.13`, iOS 15 minimum). It chooses the existing AudioUnit path using `SPTEqualizer_EqualizerImplProperties.useCoreEqualizer` and replaces `SPTEqualizerModel.applyEqualizerToAudioUnit:` after checking its exact runtime signature. It leaves Spotify's six-element model arrays intact; the custom UI and audio parameters have their own ten-element state.

Updates go through Spotify's `applyEqualizer:` driver scheduling and its `performWithEqualizerUnit:` path. Raw AudioUnit pointers are never cached and no playing unit is uninitialized. The configuration checks every parameter write and gain readback. It reports failures rather than pretending audio was applied. The low and high bands are shelves; middle bands are one-octave parametric filters. -96 dB is deep attenuation at the filter's target, not a complete spectral mute. Spotify Connect playback on another device is not processed.

## Build and package

GitHub Actions first runs the shared audio implementation against Apple's macOS NBandEQ, measuring a 1 kHz boost/cut and checking ten-band configuration and bypass. It then builds an arm64 iOS 15 dylib with Theos and rejects jailbreak dependencies. This macOS test does not replace an iPhone listening and UI test.

Download the artifact for the exact commit. Package it with the supplied base IPA:

```sh
python3 scripts/package_ipa.py base.ipa SpotifyEQPro.dylib SpotifyEQPro-0.2-test.ipa
```

The packager only inserts an `@executable_path/Frameworks/SpotifyEQPro.dylib` dependency into available Mach-O header padding and embeds the built library. It fails if safe header padding is unavailable. Existing EeveeSpotify files are preserved. The resulting IPA must be signed by your normal sideloading tool/account before installation; an ad-hoc signature alone cannot authorize a jailed iPhone installation.

## Device acceptance checks

1. Launch on a non-jailbroken iPhone; play a downloaded or streamed song locally.
2. Open full-size Now Playing; tap EQ, select a preset, then open the editor.
3. Confirm the status says the ten-band EQ is connected; compare a 1 kHz boost/cut at low listening volume, initially with headroom disabled for that comparison.
4. Save and rename a preset, restart the app, and confirm it persists. Delete it through its context menu.
5. Open Spotify's normal EQ settings entry; confirm the custom page appears and the stock list is absent.
6. Change tracks, pause/resume, change Bluetooth output, and background/foreground the app.
7. If a problem occurs, share `Diagnose teilen` from the editor. Without device execution, the UI placement and this Spotify build's runtime behavior remain unverified.
