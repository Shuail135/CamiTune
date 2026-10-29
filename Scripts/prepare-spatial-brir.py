#!/usr/bin/env python3
"""Prepare the licensed SADIE II D1 Genelec room, preserving the complete tail.
Build-time dependencies match prepare-spatial-hrtf.py. No SOFA parser in playback.
Usage: python prepare-spatial-brir.py D1_48K_24bit_0.3s_FIR_SOFA.sofa [output]
"""
import hashlib
import json
import math
from pathlib import Path
import sys
import h5py
import numpy as np
from scipy.signal import resample_poly

SOURCE_SHA256 = 'f61cc7e0919bc40d95af84aea24e599c6b0a74256adf9f19350add060abd7c8b'
source = Path(sys.argv[1])
out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parents[1] / 'Sources/CamiTune/SpatialAssets'
assert hashlib.sha256(source.read_bytes()).hexdigest() == SOURCE_SHA256, 'Unreviewed source revision'
roles = [('left', -45), ('right', 45), ('center', 0), ('leftSurround', -90), ('rightSurround', 90), ('leftRearSurround', -135), ('rightRearSurround', 135)]
with h5py.File(source) as f:
    attrs = {k: v.decode('utf-8') for k, v in f.attrs.items() if isinstance(v, bytes)}
    assert attrs['SOFAConventions'] == 'SingleRoomSRIR' and attrs['DataType'] == 'FIR'
    assert 'Apache License, Version 2.0' in attrs['License'] and 'Genelec 8030/8040' in attrs['Comment']
    assert float(f['Data.SamplingRate'][0]) == 48000 and np.all(f['Data.Delay'][:] == 0)
    assert np.allclose(f['ReceiverPosition'][:, 1, 0], [0.09, -0.09])
    assert f['SourcePosition'].attrs['Type'] == b'spherical'
    positions, filters, directions = f['SourcePosition'][:], [], []
    for role, azimuth in roles:
        matches = np.flatnonzero((np.abs((positions[:, 0] + azimuth + 180) % 360 - 180) < .001) & (np.abs(positions[:, 1]) < .001))
        assert len(matches) == 1
        index = int(matches[0]); ir = f['Data.IR'][index]
        assert np.isclose(positions[index, 2], 1.5), 'Unexpected measured speaker radius'
        assert ir.shape == (2, 16384) and np.isfinite(ir).all()
        filters.append(ir)
        directions.append(dict(role=role, azimuthDegrees=azimuth, elevationDegrees=0, sourceMeasurementIndex=index, measuredSofaPosition=positions[index].tolist()))
    filters = np.stack(filters)
    # Normalize only once using frontal early energy. The complete measured
    # speaker/room response, ear imbalance and interaural timing remain intact.
    common_gain = float(1 / np.sqrt(np.mean(np.sum(filters[2, :, :240] ** 2, axis=1))))
    filters *= common_gain
    # Align the shared frontal origin with the existing HRIR bank (104 at 48k).
    # Positive padding, no removed samples or per-ear peak alignment.
    padding = 104 - round(float(np.mean(np.argmax(np.abs(filters[2]), axis=1))))
    assert padding >= 0
    filters = np.pad(filters, ((0, 0), (0, 0), (padding, 0)))
    payload, rates = bytearray(), []
    for rate in [44100, 48000, 88200, 96000, 176400, 192000]:
        divisor = math.gcd(rate, 48000)
        bank = filters if rate == 48000 else resample_poly(filters, rate // divisor, 48000 // divisor, axis=-1, window=('kaiser', 8.6)) * 48000 / rate
        assert np.isfinite(bank).all() and np.max(np.sum(np.abs(bank), axis=-1)) < 64
        rates.append(dict(sampleRate=rate, frameCount=bank.shape[-1], byteOffset=len(payload), referenceDelayFrames=round(104 * rate / 48000)))
        payload.extend(bank.astype('<f4').tobytes(order='C'))
    manifest = dict(version=1, id='sadie-ii-d1-genelec-room', name='SADIE II KU100 · Genelec 8030/8040 studio',
        license='Apache-2.0', copyright='Copyright 2018, University of York', authors=['Cal Armstrong', 'Lewis Thresh', 'Gavin Kearney'],
        source='https://zenodo.org/records/10886409', sourceVersion='2-1',
        archiveURL='https://zenodo.org/records/10886409/files/D1_BRIR_SOFA.zip?download=1',
        sourceFile='D1_BRIR_SOFA/D1_48K_24bit_0.3s_FIR_SOFA.sofa', sourceSHA256=SOURCE_SHA256,
        sourceLicense=attrs['License'], sourceMetadata=attrs,
        modifications=['Selected seven exact measured horizontal directions at 1.5 m; no interpolated speakers.',
            'Applied one frontal early-energy scale to every ear and direction.',
            'Added a common positive delay to align the frontal time origin with the directional HRIR bank.',
            'Polyphase Kaiser resampling with transfer-gain normalization; retained the entire source tail.',
            'Converted to little-endian float32 in rate/direction/ear/sample order.'],
        equalizationReference='Source microphone free-field equalization retained. This is a KU100 room recording, not a personal BRIR or an isolated loudspeaker response.',
        roomControl='Complementary 4–5 ms early/tail window relative to the common frontal origin; Room 100% reconstructs the full measured response.',
        commonGain=common_gain, paddingFramesAt48K=padding, file='sadie-studio.f32', sha256=hashlib.sha256(payload).hexdigest(), directions=directions, rates=rates)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'sadie-studio.f32').write_bytes(payload)
    (out / 'studio-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(dict(bytes=len(payload), sha256=manifest['sha256'], gain=common_gain, padding=padding)))
