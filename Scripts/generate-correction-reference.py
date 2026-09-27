#!/usr/bin/env python3
"""Generate synthetic correction fixtures from a pinned AutoEq checkout.

Dependencies: numpy<2, scipy, matplotlib, pillow, pyyaml, tabulate.
Usage: python generate-correction-reference.py --autoeq-root /path/to/AutoEq --output /path/to/AutoEQReference.json
Reference commit: 7ae0f56d53074872b028649617a22bbb4232feb7.
The Swift implementation deliberately differs in smoothing, confidence and fitting;
fixtures establish regression tolerances, not numerical equivalence or superiority.
"""
import argparse
import json
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--autoeq-root', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
sys.path.insert(0, str(args.autoeq_root))
import numpy as np
from autoeq.frequency_response import FrequencyResponse

frequencies = np.geomspace(20, 20_000, 181)
cases = {
    'flat': np.zeros(181),
    'broad_bass': -4 / (1 + (frequencies / 120) ** 4),
    'midrange_peak': 4 * np.exp(-0.5 * (np.log2(frequencies / 1_000) / 0.7) ** 2),
    'treble_notch': -15 * np.exp(-0.5 * (np.log2(frequencies / 9_000) / 0.05) ** 2),
}
fixtures = []
for name, measured_error in cases.items():
    response = FrequencyResponse(name=name, frequency=frequencies, raw=measured_error)
    response.error = measured_error.copy()
    response.equalize(treble_gain_k=0.5)
    fixtures.append(dict(name=name, frequency=frequencies.tolist(), rawCorrection=(-measured_error).tolist(), reference=response.equalization.tolist()))
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(dict(commit='7ae0f56d53074872b028649617a22bbb4232feb7', cases=fixtures), indent=2) + '\n')
