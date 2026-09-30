# UI structure and performance

Feature folders own their presentation and edit coordination. `Components` contains shared controls and layouts; audio processing and persistence remain outside the UI tree.

When adding an editor:

- Keep profile sections in the same SwiftUI layout tree. `StableEditorSection` uses an equatable revision to skip unrelated parent updates while preserving native control identity. Avoid nested hosting controllers with cached heights: their controls can lag behind a disclosure's new size. Prepare large sections between event-loop turns and retain them while the profile is open; profile identity releases their state on navigation.
- Supply a revision containing every input used to construct a section. Let SwiftUI inherit appearance and text size and calculate dynamic height. Never return infinite sizes from custom layouts; treat infinite-width probes as requests for an ideal size.
- Keep native focus groups at the profile-section and EQ-band boundaries. Without these boundaries, macOS AutoFill's next/previous key-view discovery can scan the entire editor when a numeric field receives focus. Verify that Tab still crosses band groups after changing focus structure.
- Observe audio telemetry only in the smallest drawing view. Text fields, buttons, menus, and their containing layout should not subscribe to FFT or meter publications. Keep the publication cadence unchanged during scrolling.
- Use `ResponsiveStackLayout`, `AdaptiveEditorLayout`, or `WrappingControlLayout` to reposition the same controls. Avoid constructing multiple copies of an editor to measure which copy fits.
- Use `EqualizerBandScrollView` for EQ strips and `OverflowAwareHorizontalScrollView` for other horizontal content. A fitting strip must reject horizontal scrolling and discard stale offsets after resizing.
- Use `SectionDisclosureStyle` for disclosures. Reflow text and native controls together; animate only the chevron or meter artwork and honor Reduce Motion. Animated layout frames can move AppKit controls and SwiftUI labels at different times.
- Use `SteppedValueSlider` for finely stepped numeric controls. It quantizes values while retaining a native continuous track, avoiding hundreds of AppKit tick marks and their measurement cost.
- `SelectedEditorPageLayout` retains Auto EQ work when switching correction methods and measures only the selected page. Hidden editors must reject input and accessibility focus. Its explicit alignment methods return `nil`: top-leading placement needs no child baseline guides, and deriving them would lay out retained editors repeatedly during telemetry updates.
- Resolve editable collection bindings by identity, preserve surviving control objects, and commit the focused field before changing its editing target. Navigation must not persist a profile.
- Store cancellation handles and bookkeeping in non-published runtime objects. Publish only state that changes visible output. Share expensive catalog preparation and perform decoding, indexing, and response calculations off the main thread.
- Preserve existing help text wording. Remove visible guidance only after user approval.

## Validation

`--ui-self-test <artifact-directory>` runs native control, focus, layout, resizing, and scrolling-cadence checks in a Debug build. `--ui-app-self-test <artifact-directory>` exercises the complete window, profile navigation, settings, continuous telemetry, scrolling, editing, and the menu bar.

The full-window test uses simulated audio services and temporary profiles. Optional environment variables:

- `CAMITUNE_UI_TEST_PROFILE_LIBRARY`: profile library to copy into the temporary fixture; the original is never edited.
- `CAMITUNE_UI_TEST_SUPPORT_DIRECTORY`: isolated supporting files, such as copied Auto EQ drafts.
- `CAMITUNE_UI_SOAK_SECONDS`: sustained scrolling and telemetry duration.
- `CAMITUNE_UI_MAX_NAVIGATION_GAP_MS`: navigation regression budget (500 ms by default for unoptimized Debug builds).
- `CAMITUNE_UI_EDIT_ONLY=1`: isolate the real channel-gain field edit, with a five-second pause before editing to attach a sampler. The edit must save and meet the interaction budget.

Performance artifacts report main-loop scheduling gaps and process memory. These are regression measurements, not display-frame-rate guarantees. Compare the same configuration and fixtures without concurrent builds. For optimized measurements with diagnostic entry points enabled, use `swift build -c release -Xswiftc -DDEBUG`.

Also run the full `--self-test` suite, an Xcode build, and `Scripts/verify-source-targets.py` when files move between folders or targets.
