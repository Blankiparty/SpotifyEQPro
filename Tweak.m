// SpotifyEQPro diagnostic v4
// Stability-first build: no SPTEqualizerModel mutation. We only probe/hook the AudioUnit symbol.

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>
#import <dlfcn.h>

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
        if (![[NSFileManager defaultManager] fileExistsAtPath:p])
            [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        [h seekToEndOfFile]; [h writeData:d]; [h closeFile];
        NSLog(@"[SpotifyEQPro] %@", s);
    }
}

static OSStatus (*OrigAudioUnitSetParameter)(AudioUnit,AudioUnitParameterID,AudioUnitScope,AudioUnitElement,AudioUnitParameterValue,UInt32) = NULL;

static BOOL IsNBandEQ(AudioUnit unit) {
    if (!unit) return NO;
    AudioComponent comp = AudioComponentInstanceGetComponent(unit);
    if (!comp) return NO;
    AudioComponentDescription d = {0};
    if (AudioComponentGetDescription(comp, &d) != noErr) return NO;
    return d.componentType == kAudioUnitType_Effect && d.componentSubType == kAudioUnitSubType_NBandEQ;
}

static OSStatus EQAudioUnitSetParameter(AudioUnit unit, AudioUnitParameterID pid,
    AudioUnitScope scope, AudioUnitElement elem, AudioUnitParameterValue value, UInt32 offset) {

    if (!OrigAudioUnitSetParameter) return kAudio_ParamError;

    if (IsNBandEQ(unit)) {
        // Log only the parameters Spotify actually drives; do not alter them in this diagnostic build.
        if ((pid >= 2000 && pid < 2020) || (pid >= 3000 && pid < 3020) ||
            (pid >= 4000 && pid < 4020) || (pid >= 5000 && pid < 5020)) {
            LogLine([NSString stringWithFormat:@"NBandEQ set pid=%u value=%.3f scope=%u elem=%u",
                     (unsigned)pid, value, (unsigned)scope, (unsigned)elem]);
        }
    }

    return OrigAudioUnitSetParameter(unit,pid,scope,elem,value,offset);
}

static void InstallAudioHook(void) {
    LogLine(@"stage: resolving AudioUnitSetParameter");

    void *sym = dlsym(RTLD_DEFAULT, "AudioUnitSetParameter");
    LogLine([NSString stringWithFormat:@"dlsym AudioUnitSetParameter=%p", sym]);

    if (!sym) {
        LogLine(@"ERROR: dlsym failed; leaving audio unhooked");
        return;
    }

    MSHookFunction(sym, (void *)EQAudioUnitSetParameter, (void **)&OrigAudioUnitSetParameter);
    if (OrigAudioUnitSetParameter)
        LogLine([NSString stringWithFormat:@"stage: AudioUnit hook installed original=%p", OrigAudioUnitSetParameter]);
    else
        LogLine(@"ERROR: MSHookFunction returned NULL original; leaving diagnostic only");
}

__attribute__((constructor))
static void SpotifyEQProInit(void) {
    @autoreleasepool {
        LogLine(@"constructor entered - diagnostic v4 loaded");
        LogLine(@"model hooks DISABLED to isolate prior crash loop");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ InstallAudioHook(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ LogLine(@"stage: survived 10 seconds"); });
    }
}
