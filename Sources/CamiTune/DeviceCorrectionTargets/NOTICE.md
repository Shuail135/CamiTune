# Device Correction Target Data Notices

The bundled CSV files retain their source sampling or use approximately 1/24-octave spacing. CamiTune
interpolates them on a logarithmic frequency axis and retains the original source
shape; target-specific shelves and user tilt are calculated at runtime.

## AutoEq

The Harman Over-Ear 2018, Harman In-Ear 2019, B&K 5128 diffuse-field, JM-1, and 711/5128-transfer
source curves are derived from the `targets` directory of
[AutoEq](https://github.com/jaakkopasanen/AutoEq), commit
`7ae0f56d53074872b028649617a22bbb4232feb7`.

MIT License

Copyright (c) 2018-2022 Jaakko Pasanen

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## PublicGraphTool

The IEF Neutral 2023, Etymotic, and KEMAR diffuse-field source curves are
derived from [PublicGraphTool](https://github.com/HarutoHiroki/PublicGraphTool).
The repository is the redistribution source, not the author of each acoustic
target: IEF Neutral 2023 is attributed to Crinacle and the Etymotic reference is
attributed to Etymotic Research.

MIT License

Copyright (c) 2024 Haruto Hiroki

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Registry 2 source-specific additions (2026-09-26)

The following curves are copied from AutoEq commit
`7ae0f56d53074872b028649617a22bbb4232feb7`, under the MIT notice above:

| Bundled file | Upstream `targets/` file | Added shelf |
| --- | --- | --- |
| oratory-optimum-hifi.csv | oratory1990 optimum hifi over-ear.csv | Already included |
| autoeq-in-ear.csv | AutoEq in-ear.csv | +8 dB at 105 Hz, Q 0.7 |
| hms-autoeq-in-ear.csv | HMS II.3 AutoEq in-ear.csv | +8 dB at 105 Hz, Q 0.7 |
| hms-harman-in-ear.csv | HMS II.3 Harman in-ear 2019 without bass.csv | +9.5 dB at 105 Hz, Q 0.7 |
| hms-harman-over-ear.csv | HMS II.3 Harman over-ear 2018 without bass.csv | +6 dB at 105 Hz, Q 0.7 |
| ears-harman-over-ear.csv | crinacle EARS + 711 Harman over-ear 2018.csv | Already included |
| lmg-5128.csv | LMG 5128 0.6.csv | Already included |
| jm1-harman.csv | JM-1 with Harman filters.csv | Already included |

Source compatibility and default shelves are taken from
<https://autoeq.app/targets>, checked against <https://autoeq.app/entries>
on 2026-09-26. Explicit source/form/rig tuples bound wildcard upstream source
recommendations to observed fixtures. In particular, HMS targets are not applied
to newer RTINGS 5128 measurements. Two HypetheSonics catalog rows labeled
GRAS RA0045 (over-ear/earbud) lack a matching published target; the source-level
5128 recommendation is not applied to them. Other compatible measurements of
the same device remain available. The registry provides targets for every
current catalog laboratory, including its published source-specific transfers.

## Neutral baselines (registry 3)

“Neutral” is CamiTune's fixture-aware baseline selection, not a claim that one
curve is perceptually neutral for every listener. It applies no extra preference
bass shelf. The acoustic reference itself is not a flat coupler response.

| Measurement domain | Baseline |
| --- | --- |
| 711 / provider-listed 711 sources | IEF Neutral 2023 |
| GRAS-compatible headphones | oratory1990 Optimum HiFi |
| B&K 5128 / 4620 | JM-1 PopAvg-DF, fixed −1 dB/octave tilt |
| HMS II.3 in-ear / earbuds | AutoEq HMS II.3 Harman In-Ear 2019 without bass |
| HMS II.3 headphones | AutoEq HMS II.3 Harman Over-Ear 2018 without bass |
| crinacle EARS + 711 headphones | AutoEq crinacle EARS + 711 Harman Over-Ear 2018 without bass |

The EARS baseline is copied from `targets/crinacle EARS + 711 Harman over-ear
2018 without bass.csv` at the pinned AutoEq commit above. HMS and EARS retain
upstream fixture compensation; no generic 711 curve is substituted for them.
The 5128 baseline reverses the published JM-1 treble shelf before applying the
fixed tilt, using the existing JM-1 resolver. IEF and Optimum HiFi keep their
published shapes. Native and converted paths retain the source registry's
compatibility restrictions and conversion flags. Two conflicting RA0045 rows
remain excluded. All 23 catalog sources have a ready neutral baseline for their
validated domains; imported CSVs still require a declared compatible fixture.
