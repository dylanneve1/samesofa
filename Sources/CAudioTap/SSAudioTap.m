#import "SSAudioTap.h"

MTAudioProcessingTapRef SSAudioTapCreate(const MTAudioProcessingTapCallbacks *callbacks) {
    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
    return status == noErr ? tap : NULL;
}
