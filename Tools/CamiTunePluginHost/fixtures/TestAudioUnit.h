#ifdef CAMITUNE_PLUGIN_TESTING
#import <AudioToolbox/AudioToolbox.h>
// Process-local fixtures; never registered with macOS or included in Release.
AUAudioUnit* makeCompatibilityTestAU(AudioComponentDescription description, NSError** error);
#endif
