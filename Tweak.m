// SpotifyEQPro diagnostic build
// Writes detailed stage markers to Documents/SpotifyEQPro.log and delays risky hooks.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>
#import <signal.h>
#import <unistd.h>

#define BAND_COUNT 10
static const Float32 kFreqs[BAND_COUNT] = {31,63,125,250,500,1000,2000,4000,8000,16000};

static NSString *LogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"SpotifyEQPro.log"];
}

static void LogLine(NSString *s) {
    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s ?: @"(null)"];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSString *p = LogPath();
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        [h seekToEndOfFile];
        [h writeData:d];
        [h closeFile];
        NSLog(@"[SpotifyEQPro] %@", s);
    }
}

static void Uncaught(NSException *e) {
    LogLine([NSString stringWithFormat:@"UNCAUGHT EXCEPTION: %@ | %@ | stack=%@", e.name, e.reason, e.callStackSymbols]);
}

static void SignalHandler(int sig) {
    const char *msg = "SpotifyEQPro caught fatal signal\n";
    write(STDERR_FILENO, msg, strlen(msg));
    signal(sig, SIG_DFL);
    raise(sig);
}

static NSArray *Expand10(NSArray *input) {
    NSMutableArray *a=[NSMutableArray arrayWithCapacity:BAND_COUNT];
    for (NSUInteger i=0;i<BAND_COUNT;i++) [a addObject:(input && i<input.count)?input[i]:@(0.0)];
    return [a copy];
}

static IMP oSetValues,oValues,oBands,oInit;
static void EQSetValues(id self,SEL cmd,NSArray *values){ LogLine(@"EQSetValues called"); NSArray *v=Expand10(values); if(oSetValues)((void(*)(id,SEL,NSArray*))oSetValues)(self,cmd,v); Ivar iv=class_getInstanceVariable([self class],"_values"); if(iv)object_setIvar(self,iv,v); }
static NSArray *EQValues(id self,SEL cmd){ LogLine(@"EQValues called"); NSArray *v=nil; Ivar iv=class_getInstanceVariable([self class],"_values"); if(iv)v=object_getIvar(self,iv); if(!v&&oValues)v=((NSArray*(*)(id,SEL))oValues)(self,cmd); v=Expand10(v); if(iv)object_setIvar(self,iv,v); return v; }
static NSArray *EQBands(id self,SEL cmd){ LogLine(@"EQBands called"); NSArray *f=@[@31,@63,@125,@250,@500,@1000,@2000,@4000,@8000,@16000]; Ivar iv=class_getInstanceVariable([self class],"_bands"); if(iv)object_setIvar(self,iv,f); return f; }
static id EQInit(id self,SEL cmd,id a,id b,id c,id d,id e){ LogLine(@"EQInit called"); id r=oInit?((id(*)(id,SEL,id,id,id,id,id))oInit)(self,cmd,a,b,c,d,e):self; if(r){ Ivar iv=class_getInstanceVariable([r class],"_values"); if(iv)object_setIvar(r,iv,Expand10(object_getIvar(r,iv))); (void)EQBands(r,@selector(bands)); } return r; }
static void HookMethod(Class c,NSString *s,IMP n,IMP *o){ Method m=class_getInstanceMethod(c,NSSelectorFromString(s)); if(m){ *o=method_setImplementation(m,n); LogLine([NSString stringWithFormat:@"hooked %@",s]); } else LogLine([NSString stringWithFormat:@"missing selector %@",s]); }

static OSStatus (*OrigAudioUnitSetParameter)(AudioUnit,AudioUnitParameterID,AudioUnitScope,AudioUnitElement,AudioUnitParameterValue,UInt32);
static BOOL IsNBandEQ(AudioUnit unit){ if(!unit)return NO; AudioComponent comp=AudioComponentInstanceGetComponent(unit); if(!comp)return NO; AudioComponentDescription d={0}; if(AudioComponentGetDescription(comp,&d)!=noErr)return NO; return d.componentType==kAudioUnitType_Effect && d.componentSubType==kAudioUnitSubType_NBandEQ; }
static void ConfigureBand(AudioUnit unit,int band){ if(!OrigAudioUnitSetParameter)return; Float32 type=(band==0)?7.0f:((band==9)?8.0f:0.0f); OrigAudioUnitSetParameter(unit,2000+band,kAudioUnitScope_Global,0,type,0); OrigAudioUnitSetParameter(unit,3000+band,kAudioUnitScope_Global,0,kFreqs[band],0); if(band>0&&band<9)OrigAudioUnitSetParameter(unit,5000+band,kAudioUnitScope_Global,0,0.70f,0); }
static OSStatus EQAudioUnitSetParameter(AudioUnit unit,AudioUnitParameterID pid,AudioUnitScope scope,AudioUnitElement elem,AudioUnitParameterValue value,UInt32 offset){
    if(!OrigAudioUnitSetParameter) return kAudio_ParamError;
    if(IsNBandEQ(unit) && pid>=4000 && pid<4000+BAND_COUNT){ int band=(int)(pid-4000); ConfigureBand(unit,band); if(value<=-11.75f)value=-96.0f; else if(value>0.0f){ Float32 mult=(band==0||band==1)?2.0f:(band==2?1.6f:1.35f); value*=mult; if(value>24.0f)value=24.0f; } }
    return OrigAudioUnitSetParameter(unit,pid,scope,elem,value,offset);
}

static void InstallModelHooks(void){
    LogLine(@"stage: installing model hooks");
    Class c=NSClassFromString(@"SPTEqualizerModel");
    if(!c){ LogLine(@"SPTEqualizerModel NOT FOUND"); return; }
    LogLine(@"SPTEqualizerModel found");
    HookMethod(c,@"setValues:",(IMP)EQSetValues,&oSetValues);
    HookMethod(c,@"values",(IMP)EQValues,&oValues);
    HookMethod(c,@"bands",(IMP)EQBands,&oBands);
    HookMethod(c,@"initWithLocalSettings:audioDriverController:connectManager:remoteConfigurationProperties:preferences:",(IMP)EQInit,&oInit);
    LogLine(@"stage: model hooks installed");
}

static void InstallAudioHook(void){
    LogLine(@"stage: installing AudioUnit hook");
    MSHookFunction((void*)AudioUnitSetParameter,(void*)EQAudioUnitSetParameter,(void**)&OrigAudioUnitSetParameter);
    LogLine(OrigAudioUnitSetParameter?@"stage: AudioUnit hook installed":@"ERROR: OrigAudioUnitSetParameter is NULL");
}

__attribute__((constructor)) static void SpotifyEQProInit(void){
    @autoreleasepool {
        NSSetUncaughtExceptionHandler(&Uncaught);
        signal(SIGABRT,SignalHandler); signal(SIGSEGV,SignalHandler); signal(SIGBUS,SignalHandler); signal(SIGILL,SignalHandler); signal(SIGTRAP,SignalHandler);
        LogLine(@"constructor entered - dylib loaded successfully");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ InstallModelHooks(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ InstallAudioHook(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(9*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ LogLine(@"stage: survived 9 seconds"); });
    }
}
