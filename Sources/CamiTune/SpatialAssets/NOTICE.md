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
CamiTune selects seven horizontal directions, converts the azimuth sign convention,
applies one common frontal-energy gain to all ears and directions, resamples to
six supported rates with polyphase anti-alias filtering and transfer-gain scaling,
and serializes the result as little-endian float32. The original interaural
level/time differences and windowed HRIR timing are retained. No ear-specific
normalization or minimum-phase conversion is applied.

manifest.json records source and derived SHA-256 hashes, measured direction indices,
exact source metadata, common gain, resampling rates and original license notice.
Scripts/prepare-spatial-hrtf.py reproduces this asset from the pinned original SOFA.
The Python converter dependencies are build-time tools and are not bundled in the app.
