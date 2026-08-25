# System Audio Bridge

System Audio Bridge is an output-only Core Audio HAL device for macOS 13 and
later. It is DSP-agnostic: any companion application that implements the
versioned transport can consume its PCM stream. Transport protocol version 5
preserves Core Audio client ID, PID, bundle ID, lifecycle, cycle timing, and
separate PCM blocks so the companion can apply per-application processing
before mixing. Each packet also carries its Core Audio channel-layout tag so
semantic roles survive the driver boundary. The current product profile
exposes one 7.1 Float32 LPCM transport endpoint in ITU order
(`L R C LFE Ls Rs Rls Rrs`). It is hidden under the generic
`System Audio Bridge` name while idle and can be made visible under an active
profile name by a companion app. It exposes no input stream and does not use
macOS Microphone privacy APIs. A companion app can also publish per-profile
Core Audio aggregate outputs as inactive selection entries.

The driver is deliberately small. It receives client-scoped interleaved Float32
blocks from Core Audio and copies them into a bounded shared ring. A companion
userspace process reads that ring and may analyze, record, route, or process
the frames with any suitable audio engine.

```text
macOS apps -> native profile endpoint -> hidden bridge transport
                              |
                              v
                    private mapped ring
                              |
                              v
                    companion audio process
                              |
                              v
                    physical output or sink
```

Calls and screen sharing apps can continue to use the real microphone as
their input. Because the virtual device is not an input device, another caller
cannot select it as a microphone and feed remote voices back into the call.

## Build

The scripts use Apple's command-line tools and target macOS 13 by default.

```sh
Drivers/SystemAudioBridge/build-driver.sh
Drivers/SystemAudioBridge/package-driver.sh
```

Generated artifacts are written under `build/driver/`. The driver is ad-hoc
signed and the package is unsigned unless a release pipeline replaces those
development defaults with Developer ID signing and notarization.

For a local system test, build the package and then run:

```sh
Drivers/SystemAudioBridge/install-driver.sh
```

That operation asks for an administrator password, installs only
`/Library/Audio/Plug-Ins/HAL/CamillaAudio.driver`, and reloads Core Audio.
The corresponding removal script is `uninstall-driver.sh`. Neither operation
is run as part of a normal build.

## LPCM layout contract

The product build uses `SABR_CHANNELS=8`. Development builds may select only
the standard layouts `2`, `6`, or `8`; the driver publishes the matching Core
Audio labels and tags for stereo, 5.1, and 7.1 respectively.

The transport protocol provides:

- interleaved Float32 transport capacity up to 32 channels;
- explicit active-channel count independent of allocated capacity;
- an explicit channel-layout tag on every packet;
- versioned direction, stream ID, and bus index fields;
- monotonic 64-bit ring positions and observable drop/underrun counters;
- standard build settings such as `SABR_CHANNELS=6`;
- a lock-free latest-value volume/mute control lane; the next PCM block applies
  each change without waking the consumer, writing the physical endpoint, or
  invoking live DSP volume RPCs.

CamiTune accepts all three layouts and preserves the source roles through its
transport, per-application mixer, metering, and analysis paths. Until the
FrontStageRenderer milestone replaces it, a bounded role-aware stereo fallback
feeds the existing stereo DSP/output path. It passes stereo unchanged, maps
center and surround beds conservatively, and excludes unfiltered LFE from small
full-range speakers.

Future microphone support should be a separate, explicit input stream or
device using `SABR_TRANSPORT_DIRECTION_INPUT`. It will also need its own ring
ownership rules, UI consent, channel layout, clocking tests, and a clear
privacy explanation. Do not advertise an input stream in the output-only
product build: doing so would bring the virtual device back into call-app
microphone lists and could reintroduce feedback.

## Real-time rules

The driver callback does not allocate, lock, open files, log, or call into the
app. File mapping and connection changes occur through a non-real-time custom
Core Audio property. If the app falls behind, the bounded writer counts and
drops new frames instead of blocking Core Audio.
