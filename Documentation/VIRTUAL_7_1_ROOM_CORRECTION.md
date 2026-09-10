# Virtual 7.1 microphone calibration and room correction

Open **Virtual 7.1 → Calibrate Virtual 7.1… → Microphone / imported recording…**.

In either method, place the microphone at your normal **head position, at ear height**. Do not place it next to the speakers. Keep position/orientation, speaker placement, EQ and volume unchanged. Use speakers, start at a comfortable volume, and keep the room quiet. The sweeps measure the two physical playback channels that reproduce Virtual 7.1; virtual sources are not treated as seven independent room loudspeakers.

## Connected microphone

Choose a built-in or external microphone, optionally import its sensitivity calibration file, then press **Play sweeps and measure**. macOS requests microphone permission. Capture and analysis stay local. Separate left/right sweeps bypass virtual placement, retain existing output EQ/master volume, and never turn system volume up. Optional left/right ear measurements are available as diagnostics; room EQ uses the normal head-position measurement.

## Record on another device

Select **Other device → import recording**. Place that device's microphone at head position. Record lossless **mono WAV or AIFF** with automatic gain, noise reduction, voice enhancement and other processing disabled where possible. Start its recorder, then press **Play sweeps for recorder** in CamiTune. Stop recording after both sweeps and their tail finish, transfer the file to this Mac, then import it in the same measurement session.

Use **Trim leading seconds** to discard only the excess lead-in: retain at least 0.2 seconds of quiet before the first sweep and put its beginning within the first two seconds. Both sweeps must remain intact. Decoder limits are 100 MB, 120 seconds total, mono, 8–192 kHz, with at most 16 seconds analyzed after trimming. Trimming operates on decoded sample counts. Raw audio is not saved by CamiTune; your original imported file is unchanged.

This is not arbitrary recording-to-EQ conversion. The file must contain CamiTune's complete sweep pair from the current output/EQ/volume configuration. The app checks signal quality and session state, but cannot prove an imported file's provenance or verify that a recorder disabled hidden processing. Unknown recorder response and clock drift can bias results. A calibrated measurement microphone is preferable.

## Proposed correction

The app measures response, relative timing, early reflections, signal/noise and coherence. It proposes only shared peaks between the left and right measured outputs at the available low-frequency analysis points (125–500 Hz). Both channels must meet signal/noise and coherence requirements. Deep nulls are never boosted, high frequencies are not inverted, and left/right disagreements are not “corrected” by a shared filter.

- Unknown/built-in microphones: up to 1.5 dB cut per band, 3 dB total cut budget.
- Calibrated external microphones: up to 3 dB cut per band, 6 dB total cut budget.
- At most three broad Q=1 peaking cuts. No makeup gain, volume boost or limiter relaxation.

Review the frequencies and cuts before pressing **Apply proposed room correction**. If no reliable shared peaks need correction, nothing is applied. Applying saves a separate room-EQ stage and measurement metadata while preserving existing EQ and virtual directions. Use **Remove room correction** before remeasuring; corrections do not stack.

This is conservative correction of the combined speaker/room/current-EQ response at one seat—not full-band room inversion, absolute SPL calibration, precise speaker-distance estimation or individualized HRTF reconstruction. The measurement microphone also affects the observed response. Moving the speakers or seat requires another measurement. Live microphone/recorder compatibility and audible results require hardware validation; automated checks do not initiate audible playback or recording.
