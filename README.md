# SpotifyEQPro – one-click GitHub build

This project builds a real iOS `SpotifyEQPro.dylib` on a GitHub macOS runner.

## What it does

- Replaces Spotify's 6-band model with 10 bands:
  31 / 63 / 125 / 250 / 500 / 1k / 2k / 4k / 8k / 16k Hz.
- Keeps Spotify's existing Equalizer screen.
- Bottom of a slider: values at about -12 dB are converted to -96 dB ("near kill").
- Positive gain is expanded, capped at +24 dB.
- 31 Hz = low shelf; 16 kHz = high shelf; middle bands = parametric.
- Bass bands receive the strongest positive expansion.

## Build on GitHub

1. Create a new PRIVATE GitHub repository.
2. Upload the CONTENTS of this folder (including `.github`).
3. Open the repository's **Actions** tab.
4. Open **Build SpotifyEQPro dylib**.
5. Press **Run workflow**.
6. When it finishes, open the run and download the artifact `SpotifyEQPro-dylib`.
7. Unzip the artifact. Inside is `SpotifyEQPro.dylib`.

## Inject with Sideloadly

Use your original EeveeSpotify IPA as input. In Sideloadly's advanced options add/inject
`SpotifyEQPro.dylib`, then sign/install normally.

Do not inject the old SpotifyEQ10 at the same time: this project already contains the
10-band model hook.

## Important

This is experimental. Spotify private class names and its audio path can change between
versions. If Spotify crashes, remove this dylib and reinstall your known-good EeveeSpotify IPA.

The -96 dB behavior is not a mathematically perfect brick-wall mute of an entire frequency
range. It is a very deep attenuation of the selected EQ band. A true band-stop mode needs
separate UI semantics because Apple's BandStop filter does not use the Gain parameter in
the same way as a parametric band.

Very large boosts can clip or damage hearing/headphones at high playback volume. Start at
low volume.
