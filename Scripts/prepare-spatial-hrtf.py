#!/usr/bin/env python3
"""Compile the pinned SADIE II D1 SOFA to a small, native runtime filter bank.
Build-time only: numpy==2.2.6 scipy==1.15.3 h5py==3.13.0.
Usage: python prepare-spatial-hrtf.py /path/to/D1_48K.sofa [output directory]
The SOFA file comes from the D1_HRIR_SOFA.zip archive linked in the manifest.
"""
import hashlib
import json
import math
from pathlib import Path
import sys
import h5py
import numpy as np
from scipy.signal import resample_poly

SOURCE_SHA256 = '9af7cb19531e52fb7ae8ec92621e6ab62b1d5fe584b3742be36699a0ddb0ccd4'
source = Path(sys.argv[1])
out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parents[1] / 'Sources/CamiTune/SpatialAssets'
assert hashlib.sha256(source.read_bytes()).hexdigest() == SOURCE_SHA256, 'Unreviewed source revision'
out.mkdir(parents=True, exist_ok=True)
roles = [('left', -30), ('right', 30), ('center', 0), ('leftSurround', -105),
         ('rightSurround', 105), ('leftRearSurround', -145), ('rightRearSurround', 145)]
with h5py.File(source) as f:
    attrs = {k: v.decode('utf-8') for k, v in f.attrs.items() if isinstance(v, bytes)}
    assert attrs['SOFAConventions'] == 'SimpleFreeFieldHRIR' and attrs['DataType'] == 'FIR'
    assert 'Apache License, Version 2.0' in attrs['License'] and 'KU100' in attrs['Comment']
    assert float(f['Data.SamplingRate'][0]) == 48000
    assert f['SourcePosition'].attrs['Type'] == b'spherical'
    assert np.all(f['Data.Delay'][:] == 0), 'Nonzero SOFA delays must be preserved explicitly'
    assert np.allclose(f['ReceiverPosition'][:, 1, 0], [0.09, -0.09]), 'Unexpected ear order'
    positions = f['SourcePosition'][:]
    source_filters = []
    directions = []
    for role, angle in roles:
        # CamiTune: negative is left. SOFA: positive azimuth is left.
        azimuth_error = np.abs((positions[:, 0] + angle + 180) % 360 - 180)
        error = azimuth_error ** 2 + positions[:, 1] ** 2
        index = int(np.argmin(error))
        assert error[index] <= 1, 'No sufficiently close measured direction'
        ir = f['Data.IR'][index]
        assert ir.shape == (2, 256) and np.isfinite(ir).all()
        source_filters.append(ir)
        directions.append(dict(role=role, azimuthDegrees=angle, elevationDegrees=0,
                               measuredSofaPosition=positions[index].tolist(), sourceMeasurementIndex=index))
    filters = np.stack(source_filters)
    # One dataset-wide scale, shared by all directions/ears: unity broadband
    # energy for the frontal pair. Do not normalize each ear or direction.
    common_gain = float(1 / np.sqrt(np.mean(np.sum(filters[2] ** 2, axis=1))))
    filters *= common_gain
    reference_delay = int(np.argmax(np.mean(filters[2] ** 2, axis=0)))
    payload = bytearray()
    rates = []
    for rate in [44100, 48000, 88200, 96000, 176400, 192000]:
        if rate == 48000:
            bank = filters
        else:
            divisor = math.gcd(rate, 48000)
            # IR resampling must preserve transfer gain, not waveform area growth.
            bank = resample_poly(filters, rate // divisor, 48000 // divisor,
                                 axis=-1, window=('kaiser', 8.6)) * 48000 / rate
        assert np.isfinite(bank).all()
        rates.append(dict(sampleRate=rate, frameCount=bank.shape[-1], byteOffset=len(payload),
                          referenceDelayFrames=round(reference_delay * rate / 48000)))
        payload.extend(bank.astype('<f4').tobytes(order='C'))
    manifest = dict(version=1, id='sadie-ii-d1-ku100', name='SADIE II KU100',
        authors=['Cal Armstrong', 'Lewis Thresh', 'Gavin Kearney'],
        copyright='Copyright 2018, University of York', license='Apache-2.0',
        source='https://zenodo.org/records/10886409', sourceVersion='2-1',
        archiveURL='https://zenodo.org/records/10886409/files/D1_HRIR_SOFA.zip?download=1',
        sourceFile='D1_HRIR_SOFA/D1_48K_24bit_256tap_FIR_SOFA.sofa', sourceSHA256=SOURCE_SHA256,
        sourceLicense=attrs['License'], sourceMetadata=attrs,
        citation='Armstrong, C.; Thresh, L.; Murphy, D.; Kearney, G. (2018). A Perceptual Evaluation of Individual and Non-Individual HRTFs: A Case Study of the SADIE II Database. Applied Sciences 8(11), 2029. https://doi.org/10.3390/app8112029',
        modifications=['Selected seven nearest measured horizontal directions; SOFA positive-left angles mapped to CamiTune negative-left angles.',
                       'Applied a single frontal broadband energy normalization shared by all ears and directions.',
                       'Polyphase Kaiser-window resampling with transfer-gain normalization for six sample rates.',
                       'Converted to contiguous little-endian float32 in rate/direction/ear/sample order.'],
        commonGain=common_gain, file='sadie-d1.f32', sha256=hashlib.sha256(payload).hexdigest(),
        directions=directions, rates=rates)
    (out / 'sadie-d1.f32').write_bytes(payload)
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(dict(bytes=len(payload), gain=common_gain, delay=reference_delay, directions=directions), indent=2))
