#import <Foundation/Foundation.h>
#import "../EQPAudio.h"
#include <assert.h>
#include <stdio.h>
static double phase;
static OSStatus input(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    for (UInt32 f=0;f<frames;f++) {
        float sample=0.001*sin(phase); phase+=2*M_PI*1000/48000; if (phase>2*M_PI) phase-=2*M_PI;
        for (UInt32 b=0;b<data->mNumberBuffers;b++) {
            float *out=data->mBuffers[b].mData;
            for (UInt32 c=0;c<data->mBuffers[b].mNumberChannels;c++) out[f*data->mBuffers[b].mNumberChannels+c]=sample;
        }
    }
    return noErr;
}
static double renderRMS(AudioUnit unit) {
    float samples[1024]; AudioBufferList buffers={.mNumberBuffers=1,.mBuffers={{2,sizeof(samples),samples}}};
    double energy=0;unsigned count=0;
    for (int k=0;k<100;k++) {
        AudioUnitRenderActionFlags flags=0; AudioTimeStamp time={.mSampleTime=k*512,.mFlags=kAudioTimeStampSampleTimeValid};
        buffers.mBuffers[0].mDataByteSize=sizeof(samples);
        assert(AudioUnitRender(unit,&flags,&time,0,512,&buffers)==noErr);
        if (k>50) for(int i=0;i<1024;i++){assert(isfinite(samples[i]));energy+=samples[i]*samples[i];count++;}
    }
    return sqrt(energy/count);
}
int main(void) {
    @autoreleasepool {
        AudioComponentDescription desc={.componentType=kAudioUnitType_Effect,.componentSubType=kAudioUnitSubType_NBandEQ,.componentManufacturer=kAudioUnitManufacturer_Apple};
        AudioUnit unit=NULL;assert(AudioComponentInstanceNew(AudioComponentFindNext(NULL,&desc),&unit)==noErr);
        AudioStreamBasicDescription format={.mSampleRate=48000,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,.mBytesPerPacket=8,.mFramesPerPacket=1,.mBytesPerFrame=8,.mChannelsPerFrame=2,.mBitsPerChannel=32};
        assert(AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&format,sizeof(format))==noErr);
        assert(AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&format,sizeof(format))==noErr);
        AURenderCallbackStruct cb={input,NULL};assert(AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,sizeof(cb))==noErr);
        EQPSettings settings={.enabled=YES,.headroom=NO};EQPStatus status={.minGain=-96,.maxGain=24};
        status=EQPConfigure(unit,settings,status);printf("configure: error=%d bands=%u range=%.0f..%.0f\n",(int)status.error,(unsigned)status.bands,status.minGain,status.maxGain);
        assert(status.error==noErr && status.bands==10 && status.minGain==-96 && status.maxGain==24);
        assert(AudioUnitInitialize(unit)==noErr);
        double neutral=renderRMS(unit);
        settings.gains[5]=24;status=EQPConfigure(unit,settings,status);assert(status.error==noErr);
        AudioUnitReset(unit,kAudioUnitScope_Global,0);double boosted=renderRMS(unit);
        double boostDB=20*log10(boosted/neutral);printf("1 kHz measured boost: %.2f dB\n",boostDB);assert(fabs(boostDB-24)<0.5);
        settings.gains[5]=-96;status=EQPConfigure(unit,settings,status);assert(status.error==noErr);
        AudioUnitReset(unit,kAudioUnitScope_Global,0);double cut=renderRMS(unit);
        double cutDB=20*log10(cut/neutral);printf("1 kHz measured cut: %.2f dB\n",cutDB);assert(cutDB < -70);
        for(int i=0;i<10;i++) settings.gains[i]=i%2?24:-96;
        settings.headroom=YES;status=EQPConfigure(unit,settings,status);assert(status.error==noErr && status.preamp==-96);
        settings.enabled=NO;status=EQPConfigure(unit,settings,status);assert(status.error==noErr && status.preamp==0);
        AudioUnitReset(unit,kAudioUnitScope_Global,0);double bypass=renderRMS(unit);assert(fabs(20*log10(bypass/neutral))<0.1);
        AudioUnitUninitialize(unit);AudioComponentInstanceDispose(unit);puts("AudioUnit tests passed");
    }
    return 0;
}
