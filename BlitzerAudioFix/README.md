# BlitzerAudioFix

Jailed in-process audio-session correction for Blitzer.de PRO 400.1.5 on iOS 15+.

It forces the app's announcements to use the system-selected playback route, applies spoken-audio ducking so Spotify continues at reduced volume, and notifies other audio sessions when an announcement deactivates. It prevents the app from forcing output to the iPhone speaker.

The supplied IPA already exposes equivalent settings: System output, background-audio ducking, and speaker-port override. This library enforces those behaviors at the AVAudioSession boundary for the reported Lightning/USB-to-AUX setup.

No Substrate, Substitute, libhooker, jailbreak path, private entitlement, or global C-function hook is used. The output IPA still needs normal sideload signing before installation.
