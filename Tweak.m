// SpotifyEQPro
// Extends Spotify's EQ model to 10 bands and makes AUNBandEQ gain handling more aggressive.
// UI minimum (-12 dB) becomes a near-kill (-96 dB). Positive gain is expanded up to +24 dB.
// Band 0 is configured as Low Shelf, band 9 as High Shelf, middle bands as Parametric.
//
// This is an experimental sideload tweak. Spotify internals can change between releases.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>

#define BAND_COUNT 10

static const Float32 kFreqs[BAND_COUNT] = {31,63,125,250,500,1000,2000,4000,8000,16000};

static NSArray *Expand10(NSArray *input) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:BAND_COUNT];
    for (NSUInteger i=0;i<BAND_COUNT;i++)
        [a addObject:(input && i<input.count) ? input[i] : @(0.0)];
    return [a copy];
}

static IMP oSetValues, oValues, oBands, oInit;

static void EQSetValues(id self, SEL cmd, NSArray *values) {
    NSArray *v = Expand10(values);
    if (oSetValues) ((void(*)(id,SEL,NSArray*))oSetValues)(self,cmd,v);
    Ivar iv = class_getInstanceVariable([self class], "_values");
    if (iv) object_setIvar(self,iv,v);
}
static NSArray *EQValues(id self, SEL cmd) {
    NSArray *v=nil; Ivar iv=class_getInstanceVariable([self class],"_values");
    if (iv) v=object_getIvar(self,iv);
    if (!v && oValues) v=((NSArray*(*)(id,SEL))oValues)(self,cmd);
    v=Expand10(v);
    if (iv) object_setIvar(self,iv,v);
    return v;
}
static NSArray *EQBands(id self, SEL cmd) {
    NSArray *f=@[@31,@63,@125,@250,@500,@1000,@2000,@4000,@8000,@16000];
    Ivar iv=class_getInstanceVariable([self class],"_bands");
    if (iv) object_setIvar(self,iv,f);
    return f;
}
static id EQInit(id self, SEL cmd, id a,id b,id c,id d,id e) {
    id r=oInit?((id(*)(id,SEL,id,id,id,id,id))oInit)(self,cmd,a,b,c,d,e):self;
    if (r) {
        Ivar iv=class_getInstanceVariable([r class],"_values");
        if (iv) object_setIvar(r,iv,Expand10(object_getIvar(r,iv)));
        (void)EQBands(r,@selector(bands));
    }
    return r;
}
static void HookMethod(Class c, NSString *s, IMP n, IMP *o) {
    Method m=class_getInstanceMethod(c,NSSelectorFromString(s));
    if (m) *o=method_setImplementation(m,n);
}

// ---- AUNBandEQ processing ----
static OSStatus (*OrigAudioUnitSetParameter)(AudioUnit, AudioUnitParameterID,
    AudioUnitScope, AudioUnitElement, AudioUnitParameterValue, UInt32);

static BOOL IsNBandEQ(AudioUnit unit) {
    if (!unit) return NO;
    AudioComponent comp=AudioComponentInstanceGetComponent(unit);
    if (!comp) return NO;
    AudioComponentDescription d={0};
    if (AudioComponentGetDescription(comp,&d)!=noErr) return NO;
    return d.componentType==kAudioUnitType_Effect && d.componentSubType==kAudioUnitSubType_NBandEQ;
}

static void ConfigureBand(AudioUnit unit, int band) {
    // 2000+n FilterType, 3000+n Frequency, 5000+n Bandwidth
    Float32 type = (band==0) ? 7.0f : ((band==9) ? 8.0f : 0.0f); // low shelf / high shelf / parametric
    OrigAudioUnitSetParameter(unit,2000+band,kAudioUnitScope_Global,0,type,0);
    OrigAudioUnitSetParameter(unit,3000+band,kAudioUnitScope_Global,0,kFreqs[band],0);
    if (band>0 && band<9)
        OrigAudioUnitSetParameter(unit,5000+band,kAudioUnitScope_Global,0,0.70f,0);
}

static OSStatus EQAudioUnitSetParameter(AudioUnit unit, AudioUnitParameterID pid,
    AudioUnitScope scope, AudioUnitElement elem, AudioUnitParameterValue value, UInt32 offset) {

    if (!OrigAudioUnitSetParameter || !IsNBandEQ(unit))
        return OrigAudioUnitSetParameter(unit,pid,scope,elem,value,offset);

    if (pid>=4000 && pid<4000+BAND_COUNT) {
        int band=(int)(pid-4000);
        ConfigureBand(unit,band);

        // Spotify normally maps slider to -12...+12 dB.
        // Bottom 2% acts as a practical "kill".
        if (value <= -11.75f) value=-96.0f;
        else if (value > 0.0f) {
            // Aggressive but bounded: bass gets most expansion.
            Float32 mult = (band==0 || band==1) ? 2.0f :
                           (band==2 ? 1.6f : 1.35f);
            value *= mult;
            if (value>24.0f) value=24.0f;
        }
    }
    return OrigAudioUnitSetParameter(unit,pid,scope,elem,value,offset);
}

__attribute__((constructor))
static void SpotifyEQProInit(void) {
    @autoreleasepool {
        Class c=NSClassFromString(@"SPTEqualizerModel");
        if (c) {
            HookMethod(c,@"setValues:",(IMP)EQSetValues,&oSetValues);
            HookMethod(c,@"values",(IMP)EQValues,&oValues);
            HookMethod(c,@"bands",(IMP)EQBands,&oBands);
            HookMethod(c,@"initWithLocalSettings:audioDriverController:connectManager:remoteConfigurationProperties:preferences:",
                       (IMP)EQInit,&oInit);
        }
        MSHookFunction((void *)AudioUnitSetParameter,
                       (void *)EQAudioUnitSetParameter,
                       (void **)&OrigAudioUnitSetParameter);
        NSLog(@"[SpotifyEQPro] loaded");
    }
}
