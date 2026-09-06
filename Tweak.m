// SpotifyEQPro diagnostic v5
// No Substrate, no global C hooks, no mutation of Spotify's EQ model.
// We only inspect and (when safe) pass-through-hook applyEqualizerToAudioUnit: via Objective-C runtime.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AudioToolbox/AudioToolbox.h>

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

static IMP gOrigApplyToUnit = NULL;
static NSString *gLastVCName = nil;

static UIViewController *TopVC(UIViewController *vc) {
    if (!vc) return nil;
    if (vc.presentedViewController) return TopVC(vc.presentedViewController);
    if ([vc isKindOfClass:[UINavigationController class]])
        return TopVC(((UINavigationController *)vc).visibleViewController);
    if ([vc isKindOfClass:[UITabBarController class]])
        return TopVC(((UITabBarController *)vc).selectedViewController);
    for (UIViewController *child in vc.children) {
        if (child.viewIfLoaded.window) {
            UIViewController *t = TopVC(child);
            if (t) return t;
        }
    }
    return vc;
}

static void LogVisibleController(void) {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (!key) key = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *top = TopVC(key.rootViewController);
    NSString *name = top ? NSStringFromClass(top.class) : @"(none)";
    if (![name isEqualToString:gLastVCName]) {
        gLastVCName = [name copy];
        LogLine([NSString stringWithFormat:@"visibleVC=%@", name]);
    }
}

static void DumpEqualizerRuntime(void) {
    Class c = NSClassFromString(@"SPTEqualizerModel");
    if (!c) { LogLine(@"SPTEqualizerModel NOT FOUND"); return; }
    LogLine(@"SPTEqualizerModel found");

    unsigned int count = 0;
    Method *methods = class_copyMethodList(c, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL s = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(s);
        if ([name localizedCaseInsensitiveContainsString:@"equalizer"] ||
            [name localizedCaseInsensitiveContainsString:@"apply"] ||
            [name localizedCaseInsensitiveContainsString:@"perform"] ||
            [name localizedCaseInsensitiveContainsString:@"audioUnit"]) {
            const char *types = method_getTypeEncoding(methods[i]);
            LogLine([NSString stringWithFormat:@"method %@ types=%s", name, types ?: "(null)"]);
        }
    }
    free(methods);

    Ivar *ivars = class_copyIvarList(c, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *n = ivar_getName(ivars[i]);
        const char *t = ivar_getTypeEncoding(ivars[i]);
        LogLine([NSString stringWithFormat:@"ivar %s type=%s", n ?: "?", t ?: "?"]);
    }
    free(ivars);
}

static void EQPApplyToUnit(id self, SEL cmd, void *unit) {
    LogLine([NSString stringWithFormat:@"applyEqualizerToAudioUnit ENTER unit=%p", unit]);
    if (gOrigApplyToUnit) ((void(*)(id,SEL,void *))gOrigApplyToUnit)(self, cmd, unit);
    LogLine([NSString stringWithFormat:@"applyEqualizerToAudioUnit EXIT unit=%p", unit]);
}

static void InstallSafeApplyHook(void) {
    Class c = NSClassFromString(@"SPTEqualizerModel");
    SEL s = NSSelectorFromString(@"applyEqualizerToAudioUnit:");
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) { LogLine(@"applyEqualizerToAudioUnit: method NOT FOUND"); return; }

    const char *types = method_getTypeEncoding(m);
    char *ret = method_copyReturnType(m);
    char *arg = method_copyArgumentType(m, 2);
    unsigned int argc = method_getNumberOfArguments(m);
    LogLine([NSString stringWithFormat:@"candidate applyEqualizerToAudioUnit types=%s return=%s arg2=%s argc=%u",
             types ?: "?", ret ?: "?", arg ?: "?", argc]);

    BOOL safe = (argc == 3 && ret && ret[0] == 'v' && arg && arg[0] == '^');
    if (safe) {
        gOrigApplyToUnit = method_setImplementation(m, (IMP)EQPApplyToUnit);
        LogLine(gOrigApplyToUnit ? @"PASS-THROUGH applyEqualizerToAudioUnit hook installed" : @"ERROR: original IMP NULL");
    } else {
        LogLine(@"SKIP hook: signature does not look like void(id,SEL,pointer)");
    }
    if (ret) free(ret); if (arg) free(arg);
}

__attribute__((constructor))
static void SpotifyEQProInit(void) {
    @autoreleasepool {
        LogLine(@"constructor entered - diagnostic v5 loaded (NO SUBSTRATE)");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DumpEqualizerRuntime();
            InstallSafeApplyHook();
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
                LogVisibleController();
            }];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LogLine(@"stage: survived 10 seconds v5");
        });
    }
}
