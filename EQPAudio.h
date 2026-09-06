#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#define EQP_BANDS 10
static const Float32 EQPFrequencies[EQP_BANDS] = {31,63,125,250,500,1000,2000,4000,8000,16000};

typedef struct {
    float gains[EQP_BANDS];
    BOOL enabled, headroom;
} EQPSettings;
typedef struct {
    OSStatus error;
    UInt32 bands;
    unsigned long updates;
    float minGain, maxGain, preamp;
} EQPStatus;
static float EQPClamp(float v, float lo, float hi) { return isfinite(v)?fminf(hi,fmaxf(lo,v)):0; }
static void EQPSetError(EQPStatus *s, OSStatus error) { if (!s->error && error) s->error=error; }
static void EQPParam(AudioUnit unit, AudioUnitParameterID p, float value, EQPStatus *status) {
    EQPSetError(status,AudioUnitSetParameter(unit,p,kAudioUnitScope_Global,0,value,0));
}
static EQPStatus EQPConfigure(AudioUnit unit, EQPSettings settings, EQPStatus status) {
    status.error=0;
    UInt32 count=0,size=sizeof(count);
    OSStatus error=AudioUnitGetProperty(unit,kAUNBandEQProperty_NumberOfBands,kAudioUnitScope_Global,0,&count,&size);
    if (error || count!=EQP_BANDS) {
        count=EQP_BANDS;
        EQPSetError(&status,AudioUnitSetProperty(unit,kAUNBandEQProperty_NumberOfBands,kAudioUnitScope_Global,0,&count,sizeof(count)));
    }
    size=sizeof(count);
    EQPSetError(&status,AudioUnitGetProperty(unit,kAUNBandEQProperty_NumberOfBands,kAudioUnitScope_Global,0,&count,&size));
    status.bands=count;
    if (count!=EQP_BANDS && !status.error) status.error=kAudioUnitErr_InvalidPropertyValue;
    AudioUnitParameterInfo info={0}; size=sizeof(info);
    error=AudioUnitGetProperty(unit,kAudioUnitProperty_ParameterInfo,kAudioUnitScope_Global,kAUNBandEQParam_Gain,&info,&size);
    EQPSetError(&status,error);
    if (!error) {
        status.minGain=fmaxf(-96,info.minValue); status.maxGain=fminf(24,info.maxValue);
        if ((info.flags & kAudioUnitParameterFlag_CFNameRelease) && info.cfNameString) CFRelease(info.cfNameString);
        if (!isfinite(status.minGain) || !isfinite(status.maxGain) || status.minGain>0 || status.maxGain<0) status.error=kAudioUnitErr_InvalidParameter;
    }
    AudioStreamBasicDescription format={0}; size=sizeof(format);
    EQPSetError(&status,AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&format,&size));
    if (format.mSampleRate<=40 && !status.error) status.error=kAudioUnitErr_FormatNotSupported;
    if (!status.error) {
        float positiveSum=0;
        for (int i=0;i<EQP_BANDS;i++) positiveSum+=fmaxf(0,EQPClamp(settings.gains[i],status.minGain,status.maxGain));
        status.preamp=(settings.enabled && settings.headroom)?-fminf(96,positiveSum):0;
        EQPParam(unit,kAUNBandEQParam_GlobalGain,status.preamp,&status);
        for (int i=0;i<EQP_BANDS;i++) {
            EQPParam(unit,kAUNBandEQParam_FilterType+i,i==0?kAUNBandEQFilterType_LowShelf:(i==9?kAUNBandEQFilterType_HighShelf:kAUNBandEQFilterType_Parametric),&status);
            EQPParam(unit,kAUNBandEQParam_Frequency+i,fminf(EQPFrequencies[i],(float)format.mSampleRate*0.49f),&status);
            if (i>0 && i<9) EQPParam(unit,kAUNBandEQParam_Bandwidth+i,1.0f,&status);
            float requested=EQPClamp(settings.gains[i],status.minGain,status.maxGain);
            EQPParam(unit,kAUNBandEQParam_Gain+i,requested,&status);
            EQPParam(unit,kAUNBandEQParam_BypassBand+i,settings.enabled?0:1,&status);
            AudioUnitParameterValue actual=0;
            EQPSetError(&status,AudioUnitGetParameter(unit,kAUNBandEQParam_Gain+i,kAudioUnitScope_Global,0,&actual));
            if (fabsf(actual-requested)>0.1f) EQPSetError(&status,kAudioUnitErr_InvalidParameter);
        }
    }
    if (!status.error) {
        UInt32 bypass=settings.enabled?0:1;
        EQPSetError(&status,AudioUnitSetProperty(unit,kAudioUnitProperty_BypassEffect,kAudioUnitScope_Global,0,&bypass,sizeof(bypass)));
    }
    if (status.error) {
        // Fail to bypass, never leave a partially applied extreme preset audible.
        UInt32 bypass=1;
        AudioUnitSetProperty(unit,kAudioUnitProperty_BypassEffect,kAudioUnitScope_Global,0,&bypass,sizeof(bypass));
    }
    status.updates++;
    return status;
}
