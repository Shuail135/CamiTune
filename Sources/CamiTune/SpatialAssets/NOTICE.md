# SADIE II KU100 HRTF data

Copyright 2018, University of York.

Data measured and developed at the AudioLab, Department of Electronic Engineering,
University of York, by Cal Armstrong, Lewis Thresh and Gavin Kearney.
Licensed under the Apache License, Version 2.0. The complete, unmodified license is
in LICENSE-SADIE-II.txt. This notice and the license must accompany redistribution.
Neither the University nor the authors endorse CamiTune.

Source: SADIE II Database, version 2-1, https://doi.org/10.5281/zenodo.10886409
Original: D1_HRIR_SOFA/D1_48K_24bit_256tap_FIR_SOFA.sofa (KU100, 48 kHz).

Reference: Armstrong, C.; Thresh, L.; Murphy, D.; Kearney, G. (2018).
A Perceptual Evaluation of Individual and Non-Individual HRTFs: A Case Study of the
SADIE II Database. Applied Sciences 8(11), 2029. https://doi.org/10.3390/app8112029

## Modifications made for CamiTune

The distributed sadie-d1.f32 is derived data, not an unmodified upstream SOFA file.
CamiTune exports a 10-degree azimuth / 15-degree elevation grid (468 entries,
including duplicated pole entries), converts the azimuth sign convention,
applies one common frontal-energy gain to all ears and directions, resamples to
six supported rates with polyphase anti-alias filtering and transfer-gain scaling,
and serializes the result as little-endian float32. The source data are already diffuse-field equalized; no second diffuse-field
inverse is applied. The original interaural level/time differences and windowed HRIR timing are retained. No ear-specific
normalization or minimum-phase conversion is applied.

manifest.json records source and derived SHA-256 hashes, measured direction indices,
exact source metadata, common gain, resampling rates and original license notice.
Scripts/prepare-spatial-hrtf.py reproduces this asset from the pinned original SOFA.
Runtime lookup interpolates peak-aligned waveforms and restores each ear’s
interpolated delay. Full-sphere coverage supports moved speakers and reflected
arrival directions; the data remain one generic KU100 profile, not a measurement
of the listener. Distance gain and simulated room paths are separate from the
measured 1.2 m HRTF.

The Python converter dependencies are build-time tools and are not bundled in the app.

## Measured Genelec studio

`sadie-studio.f32` is derived from
`D1_BRIR_SOFA/D1_48K_24bit_0.3s_FIR_SOFA.sofa` in the same pinned SADIE II
version 2-1 distribution, under the same Apache-2.0 license and attribution above.
The recording uses a KU100 and a Genelec 8030/8040 array at a 1.5 m radius.
The seven exported directions are front 0°, front left/right ±45°, sides ±90°
and rears ±135°. These are exact measured positions, not a claimed ±30° studio.

The converter selects those directions, applies one common frontal early-energy
normalization, adds 60 samples of common padding at 48 kHz to align the time origin
with the directional bank, resamples with transfer-gain preservation, and stores
little-endian float32. It retains all 16,384 original samples at 48 kHz, including
the complete supplied room tail. The source microphone free-field equalization
is retained; no second diffuse-field inverse is applied. This recording includes
the room and measurement listener, not an isolated loudspeaker transfer function
or a personal calibration of the user.

`studio-manifest.json` records the source metadata, hashes, exact measurement
indices, gain, padding and resampling. `Scripts/prepare-spatial-brir.py` reproduces
the asset. At playback, complementary windows split the response 4–5 ms after
the common frontal origin. Room 100% reconstructs the complete response; smaller
values attenuate the later part. No synthetic reverberation is added to this mode.
