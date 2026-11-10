#import <MediaToolbox/MediaToolbox.h>

NS_ASSUME_NONNULL_BEGIN

/// Creates an MTAudioProcessingTap (post-effects). Wrapped in C because the
/// Swift import of MTAudioProcessingTapCreate's out-parameter differs between
/// SDK versions. Returns NULL on failure.
MTAudioProcessingTapRef _Nullable SSAudioTapCreate(const MTAudioProcessingTapCallbacks *callbacks) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
