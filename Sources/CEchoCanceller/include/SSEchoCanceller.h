#ifndef SS_ECHO_CANCELLER_H
#define SS_ECHO_CANCELLER_H

#ifdef __cplusplus
extern "C" {
#endif

/// Microphone clean-up for a call: echo cancellation (WebRTC AEC3) against a
/// reference of everything this Mac is playing, plus high-pass filter, noise
/// suppression and gain control. All audio is 48 kHz Float32 in -1...1, in
/// blocks of exactly 10 ms (480 frames).
typedef struct SSEchoCanceller SSEchoCanceller;

enum { SSEchoCancellerBlockFrames = 480, SSEchoCancellerSampleRate = 48000 };

/// `stereoReference`: model left and right speakers separately.
SSEchoCanceller *SSEchoCancellerCreate(int stereoReference, int noiseSuppression, int gainControl);
void SSEchoCancellerDestroy(SSEchoCanceller *canceller);

/// What the speakers play during the next block (call before ProcessCapture
/// for the same block). `right` is ignored for a mono reference.
int SSEchoCancellerAnalyzeRender(SSEchoCanceller *canceller, const float *left, const float *right);
/// Cleans one block of microphone audio in place.
int SSEchoCancellerProcessCapture(SSEchoCanceller *canceller, float *mono);
/// Echo return loss enhancement (dB) and the estimated echo delay (ms) as the
/// canceller reports them; negative when it has no estimate yet.
void SSEchoCancellerGetStats(SSEchoCanceller *canceller, double *erleDb, int *delayMs);

#ifdef __cplusplus
}
#endif
#endif
