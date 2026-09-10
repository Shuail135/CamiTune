# Third-party components

CamiTune builds CamillaDSP from its official upstream source with the repository's Core Audio UID patch and includes the resulting executable in the app bundle. The app bundle also includes the source-built System Audio Bridge HAL driver so users do not need a separate loopback download.

- [CamillaDSP](https://github.com/HEnquist/camilladsp): dual-licensed under GPL-3.0 and MPL-2.0 for the macOS build used here.
- System Audio Bridge is a modified, output-only derivative of [BlackHole](https://github.com/ExistentialAudio/BlackHole) revision `ffcb74433fbcf8c8ca5c736677c1a4864384dc09`, Copyright (C) 2019 Existential Audio Inc., licensed under GPL-3.0. Modifications add the System Audio Bridge identity and a private, versioned app transport.
- Device Correction target samples are derived from [AutoEq](https://github.com/jaakkopasanen/AutoEq) and [PublicGraphTool](https://github.com/HarutoHiroki/PublicGraphTool), both under their MIT licenses. Full attribution and license texts are bundled in `DeviceCorrectionTargets/NOTICE.md`.

CamiTune is therefore distributed under GPL-3.0-only. Each component remains subject to its upstream copyright and license terms. Recheck those terms before changing how dependencies are acquired or bundled.

## Spatial headphone filters

The bundled virtual-speaker filters are derived from the **SADIE II D1 KU100**
dataset, version 2-1, Copyright 2018 University of York, licensed under
**Apache-2.0**. This permits commercial redistribution and modification subject
to the license's notice requirements; it does not change CamiTune's GPL-3.0-only
license or the obligations of other components.

Data: Cal Armstrong, Lewis Thresh and Gavin Kearney, AudioLab, University of York.
Source: https://doi.org/10.5281/zenodo.10886409
Reference: Armstrong, C.; Thresh, L.; Murphy, D.; Kearney, G. (2018),
*A Perceptual Evaluation of Individual and Non-Individual HRTFs: A Case Study of
the SADIE II Database*, Applied Sciences 8(11), 2029,
https://doi.org/10.3390/app8112029.

The unmodified license, attribution, modification notice and provenance manifest
ship inside `SpatialAssets/`. The original SOFA data is converted at development
time by `Scripts/prepare-spatial-hrtf.py`; Python, h5py, NumPy and SciPy are not
runtime dependencies or redistributed as part of this asset.
