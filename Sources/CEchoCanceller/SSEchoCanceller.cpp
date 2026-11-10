#include "SSEchoCanceller.h"

#include <cstring>

#include "api/audio/audio_processing.h"
#include "api/scoped_refptr.h"

struct SSEchoCanceller {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    int renderChannels;
    float scratchLeft[SSEchoCancellerBlockFrames];
    float scratchRight[SSEchoCancellerBlockFrames];
    float captureOut[SSEchoCancellerBlockFrames];
};

SSEchoCanceller *SSEchoCancellerCreate(int stereoReference, int noiseSuppression, int gainControl) {
    auto apm = webrtc::AudioProcessingBuilder().Create();
    if (!apm) return nullptr;
    webrtc::AudioProcessing::Config config;
    config.pipeline.maximum_internal_processing_rate = 48000;
    config.pipeline.multi_channel_render = stereoReference != 0;
    config.pipeline.multi_channel_capture = false;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    config.high_pass_filter.enabled = true;
    config.noise_suppression.enabled = noiseSuppression != 0;
    config.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kModerate;
    config.gain_controller1.enabled = gainControl != 0;
    config.gain_controller1.mode = webrtc::AudioProcessing::Config::GainController1::kAdaptiveDigital;
    config.gain_controller2.enabled = false;
    apm->ApplyConfig(config);
    if (apm->Initialize() != webrtc::AudioProcessing::kNoError) return nullptr;
    auto *canceller = new SSEchoCanceller();
    canceller->apm = apm;
    canceller->renderChannels = stereoReference != 0 ? 2 : 1;
    return canceller;
}

void SSEchoCancellerDestroy(SSEchoCanceller *canceller) { delete canceller; }

int SSEchoCancellerAnalyzeRender(SSEchoCanceller *canceller, const float *left, const float *right) {
    if (!canceller || !left) return -1;
    const webrtc::StreamConfig config(SSEchoCancellerSampleRate, canceller->renderChannels);
    const float *src[2] = {left, right ? right : left};
    float *dst[2] = {canceller->scratchLeft, canceller->scratchRight};
    return canceller->apm->ProcessReverseStream(src, config, config, dst);
}

int SSEchoCancellerProcessCapture(SSEchoCanceller *canceller, float *mono) {
    if (!canceller || !mono) return -1;
    const webrtc::StreamConfig config(SSEchoCancellerSampleRate, 1);
    const float *src[1] = {mono};
    float *dst[1] = {canceller->captureOut};
    int status = canceller->apm->ProcessStream(src, config, config, dst);
    if (status == webrtc::AudioProcessing::kNoError) {
        std::memcpy(mono, canceller->captureOut, sizeof(canceller->captureOut));
    }
    return status;
}

void SSEchoCancellerGetStats(SSEchoCanceller *canceller, double *erleDb, int *delayMs) {
    if (erleDb) *erleDb = -1;
    if (delayMs) *delayMs = -1;
    if (!canceller) return;
    auto stats = canceller->apm->GetStatistics(true);
    if (erleDb && stats.echo_return_loss_enhancement) *erleDb = *stats.echo_return_loss_enhancement;
    if (delayMs && stats.delay_ms) *delayMs = *stats.delay_ms;
}
