// BlitzerAudioFix — jailed AVAudioSession correction for Lightning/USB audio.
#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <objc/runtime.h>

static BOOL (*OrigSetCategoryModeOptions)(AVAudioSession *, SEL, AVAudioSessionCategory, AVAudioSessionMode, AVAudioSessionCategoryOptions, NSError **);
static BOOL (*OrigSetCategoryOptions)(AVAudioSession *, SEL, AVAudioSessionCategory, AVAudioSessionCategoryOptions, NSError **);
static BOOL (*OrigSetCategory)(AVAudioSession *, SEL, AVAudioSessionCategory, NSError **);
static BOOL (*OrigSetMode)(AVAudioSession *, SEL, AVAudioSessionMode, NSError **);
static BOOL (*OrigOverrideOutput)(AVAudioSession *, SEL, AVAudioSessionPortOverride, NSError **);
static BOOL (*OrigSetActiveOptions)(AVAudioSession *, SEL, BOOL, AVAudioSessionSetActiveOptions, NSError **);
static BOOL (*OrigSetActive)(AVAudioSession *, SEL, BOOL, NSError **);

static AVAudioSessionCategoryOptions BlitzerMixOptions(void) {
    // Ducking includes mixing with other audio. Spotify keeps playing at reduced volume.
    return AVAudioSessionCategoryOptionDuckOthers;
}

static BOOL FixSetCategoryModeOptions(AVAudioSession *session, SEL command,
                                      AVAudioSessionCategory category,
                                      AVAudioSessionMode mode,
                                      AVAudioSessionCategoryOptions options,
                                      NSError **error) {
    return OrigSetCategoryModeOptions(session, command,
                                      AVAudioSessionCategoryPlayback,
                                      AVAudioSessionModeSpokenAudio,
                                      BlitzerMixOptions(), error);
}

static BOOL FixSetCategoryOptions(AVAudioSession *session, SEL command,
                                  AVAudioSessionCategory category,
                                  AVAudioSessionCategoryOptions options,
                                  NSError **error) {
    if (OrigSetCategoryModeOptions) {
        return OrigSetCategoryModeOptions(session,
                                          @selector(setCategory:mode:options:error:),
                                          AVAudioSessionCategoryPlayback,
                                          AVAudioSessionModeSpokenAudio,
                                          BlitzerMixOptions(), error);
    }
    return OrigSetCategoryOptions(session, command,
                                  AVAudioSessionCategoryPlayback,
                                  BlitzerMixOptions(), error);
}

static BOOL FixSetCategory(AVAudioSession *session, SEL command,
                           AVAudioSessionCategory category, NSError **error) {
    if (OrigSetCategoryModeOptions) {
        return OrigSetCategoryModeOptions(session,
                                          @selector(setCategory:mode:options:error:),
                                          AVAudioSessionCategoryPlayback,
                                          AVAudioSessionModeSpokenAudio,
                                          BlitzerMixOptions(), error);
    }
    return OrigSetCategory(session, command, AVAudioSessionCategoryPlayback, error);
}

static BOOL FixSetMode(AVAudioSession *session, SEL command,
                       AVAudioSessionMode mode, NSError **error) {
    return OrigSetMode(session, command, AVAudioSessionModeSpokenAudio, error);
}

static BOOL FixOverrideOutput(AVAudioSession *session, SEL command,
                              AVAudioSessionPortOverride output,
                              NSError **error) {
    // None means use iOS's selected route. With the user's adapter that is USB/Lightning audio.
    return OrigOverrideOutput(session, command, AVAudioSessionPortOverrideNone, error);
}

static BOOL FixSetActiveOptions(AVAudioSession *session, SEL command,
                                BOOL active,
                                AVAudioSessionSetActiveOptions options,
                                NSError **error) {
    if (!active) options |= AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation;
    return OrigSetActiveOptions(session, command, active, options, error);
}

static BOOL FixSetActive(AVAudioSession *session, SEL command,
                         BOOL active, NSError **error) {
    if (!active && OrigSetActiveOptions) {
        return OrigSetActiveOptions(session,
                                    @selector(setActive:withOptions:error:),
                                    NO,
                                    AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation,
                                    error);
    }
    return OrigSetActive(session, command, active, error);
}

static BOOL ReplaceInstanceMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

__attribute__((constructor))
static void BlitzerAudioFixInit(void) {
    @autoreleasepool {
        Class cls = AVAudioSession.class;
        BOOL categoryHook = ReplaceInstanceMethod(cls,
            @selector(setCategory:mode:options:error:),
            (IMP)FixSetCategoryModeOptions, (IMP *)&OrigSetCategoryModeOptions);
        ReplaceInstanceMethod(cls, @selector(setCategory:withOptions:error:),
                              (IMP)FixSetCategoryOptions, (IMP *)&OrigSetCategoryOptions);
        ReplaceInstanceMethod(cls, @selector(setCategory:error:),
                              (IMP)FixSetCategory, (IMP *)&OrigSetCategory);
        ReplaceInstanceMethod(cls, @selector(setMode:error:),
                              (IMP)FixSetMode, (IMP *)&OrigSetMode);
        BOOL routeHook = ReplaceInstanceMethod(cls, @selector(overrideOutputAudioPort:error:),
                                               (IMP)FixOverrideOutput, (IMP *)&OrigOverrideOutput);
        ReplaceInstanceMethod(cls, @selector(setActive:withOptions:error:),
                              (IMP)FixSetActiveOptions, (IMP *)&OrigSetActiveOptions);
        ReplaceInstanceMethod(cls, @selector(setActive:error:),
                              (IMP)FixSetActive, (IMP *)&OrigSetActive);

        // Configure the inactive session once; the app controls activation around announcements.
        NSError *error = nil;
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback
                                              mode:AVAudioSessionModeSpokenAudio
                                           options:BlitzerMixOptions()
                                             error:&error];
        [AVAudioSession.sharedInstance overrideOutputAudioPort:AVAudioSessionPortOverrideNone
                                                          error:&error];
        NSLog(@"[BlitzerAudioFix] loaded category=%d route=%d error=%@",
              categoryHook, routeHook, error);
    }
}
