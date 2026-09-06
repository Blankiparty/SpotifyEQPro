// SpotifyEQPro 0.2 — jailed, in-process Objective-C integration only.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <math.h>

#import "EQPAudio.h"
static NSString *const EQPChanged = @"SpotifyEQPro.Changed";
static NSString *const EQPDefaultsKey = @"SpotifyEQPro.v2";
static os_unfair_lock EQPLock = OS_UNFAIR_LOCK_INIT;
static EQPSettings EQPState;
static EQPStatus EQPAudioStatus = {.minGain=-96, .maxGain=24};
// UI objects are accessed exclusively on the main queue; no AudioUnit pointer is retained.
static __weak id EQPModel;
static NSMutableArray<NSDictionary *> *EQPPresets;
static NSString *EQPSelected;
static BOOL EQPHooksReady;
static const void *EQPButtonKey = &EQPButtonKey;
static const void *EQPCapturedKey = &EQPCapturedKey;
static IMP EQPOriginalApply;

static EQPSettings EQPSnapshot(void) {
    os_unfair_lock_lock(&EQPLock); EQPSettings s=EQPState; os_unfair_lock_unlock(&EQPLock); return s;
}
static EQPStatus EQPReadStatus(void) {
    os_unfair_lock_lock(&EQPLock); EQPStatus s=EQPAudioStatus; os_unfair_lock_unlock(&EQPLock); return s;
}
static void EQPWriteState(EQPSettings s) {
    os_unfair_lock_lock(&EQPLock); EQPState=s; os_unfair_lock_unlock(&EQPLock);
}
static NSArray *EQPValues(EQPSettings s) {
    NSMutableArray *a=[NSMutableArray arrayWithCapacity:EQP_BANDS];
    for (int i=0;i<EQP_BANDS;i++) [a addObject:@(s.gains[i])]; return a;
}
static BOOL EQPValidValues(id values) {
    if (![values isKindOfClass:NSArray.class] || [values count]!=EQP_BANDS) return NO;
    for (id n in values) if (![n isKindOfClass:NSNumber.class] || !isfinite([n floatValue])) return NO;
    return YES;
}
static id EQPGet(id object, NSString *name) {
    SEL sel=NSSelectorFromString(name);
    return [object respondsToSelector:sel]?((id(*)(id,SEL))objc_msgSend)(object,sel):nil;
}
static void EQPBool(id object, NSString *name, BOOL value) {
    SEL sel=NSSelectorFromString(name);
    if ([object respondsToSelector:sel]) ((void(*)(id,SEL,BOOL))objc_msgSend)(object,sel,value);
}
static BOOL EQPGetBool(id object, NSString *name) {
    SEL sel=NSSelectorFromString(name);
    return [object respondsToSelector:sel] && ((BOOL(*)(id,SEL))objc_msgSend)(object,sel);
}
static NSURL *EQPLogURL(void) {
    return [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"SpotifyEQPro.log"];
}
static void EQPLog(NSString *message) {
    // Only main-queue diagnostics; never synchronous file I/O in the audio callback.
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{EQPLog(message);}); return; }
    NSURL *url=EQPLogURL();
    if (!url) return;
    NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if ([attrs fileSize]>256*1024) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) [NSData.data writeToURL:url atomically:YES];
    NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:url.path];
    @try {
        [h seekToEndOfFile];
        [h writeData:[[NSString stringWithFormat:@"%@ %@\n",NSDate.date,message] dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } @catch (__unused NSException *e) {}
}
static void EQPLoad(void) {
    EQPState=(EQPSettings){.enabled=YES,.headroom=YES};
    EQPPresets=[@[
        @{@"name":@"Neutral",@"gains":@[@0,@0,@0,@0,@0,@0,@0,@0,@0,@0]},
        @{@"name":@"Sub Bass",@"gains":@[@8,@6,@3,@0,@-2,@-1,@0,@1,@2,@1]},
        @{@"name":@"Punch",@"gains":@[@3,@6,@4,@1,@-2,@0,@2,@3,@2,@0]},
        @{@"name":@"Stimmen",@"gains":@[@-5,@-3,@-2,@0,@2,@3,@4,@2,@0,@-1]},
        @{@"name":@"Brillant",@"gains":@[@0,@0,@-1,@-1,@0,@1,@2,@3,@5,@4]}
    ] mutableCopy];
    EQPSelected=@"Neutral";
    id saved=[NSUserDefaults.standardUserDefaults objectForKey:EQPDefaultsKey];
    if (![saved isKindOfClass:NSDictionary.class]) return;
    if (EQPValidValues(saved[@"gains"])) for (int i=0;i<EQP_BANDS;i++) EQPState.gains[i]=EQPClamp([saved[@"gains"][i] floatValue],-96,24);
    if ([saved[@"enabled"] isKindOfClass:NSNumber.class]) EQPState.enabled=[saved[@"enabled"] boolValue];
    if ([saved[@"headroom"] isKindOfClass:NSNumber.class]) EQPState.headroom=[saved[@"headroom"] boolValue];
    if ([saved[@"selected"] isKindOfClass:NSString.class]) EQPSelected=saved[@"selected"];
    if ([saved[@"presets"] isKindOfClass:NSArray.class]) {
        [EQPPresets removeAllObjects];
        for (id p in saved[@"presets"]) {
            if ([p isKindOfClass:NSDictionary.class] && [p[@"name"] isKindOfClass:NSString.class] && [p[@"name"] length] && EQPValidValues(p[@"gains"])) {
                EQPSettings s={0};
                for (int i=0;i<EQP_BANDS;i++) s.gains[i]=EQPClamp([p[@"gains"][i] floatValue],-96,24);
                [EQPPresets addObject:@{@"name":p[@"name"],@"gains":EQPValues(s)}];
            }
        }
    }
}
static void EQPSave(void) {
    EQPSettings s=EQPSnapshot();
    [NSUserDefaults.standardUserDefaults setObject:@{@"gains":EQPValues(s),@"enabled":@(s.enabled),@"headroom":@(s.headroom),@"selected":EQPSelected?:@"",@"presets":EQPPresets} forKey:EQPDefaultsKey];
}
static void EQPApplyCurrent(void) {
    id model=EQPModel;
    if (model) {
        EQPBool(model,@"setUseCoreEqualizer:",NO);
        EQPBool(model,@"setOn:",EQPSnapshot().enabled);
        EQPBool(model,@"applyEqualizer:",NO); // Spotify schedules work through its driver API.
    }
}
static void EQPCommit(void) {
    EQPSave(); EQPApplyCurrent();
    [NSNotificationCenter.defaultCenter postNotificationName:EQPChanged object:nil];
}
static void EQPCaptureModel(id model) {
    if (!model) return;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{EQPCaptureModel(model);}); return; }
    EQPModel=model;
    if (!objc_getAssociatedObject(model,EQPCapturedKey)) {
        objc_setAssociatedObject(model,EQPCapturedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Defer until the caller (possibly Spotify's initializer) has returned.
        dispatch_async(dispatch_get_main_queue(), ^{EQPApplyCurrent();});
        EQPLog(@"Spotify model captured; using driver-owned AudioUnit callbacks");
    }
}
static void EQPApplyUnit(id model, SEL command, AudioUnit unit) {
    EQPCaptureModel(model);
    if (!unit) return;
    AudioComponentDescription desc={0};
    AudioComponent component=AudioComponentInstanceGetComponent(unit);
    if (!component || AudioComponentGetDescription(component,&desc)!=noErr || desc.componentSubType!=kAudioUnitSubType_NBandEQ || desc.componentType!=kAudioUnitType_Effect) {
        if (EQPOriginalApply) ((void(*)(id,SEL,AudioUnit))EQPOriginalApply)(model,command,unit);
        return;
    }
    EQPStatus status=EQPConfigure(unit,EQPSnapshot(),EQPReadStatus());
    os_unfair_lock_lock(&EQPLock); EQPAudioStatus=status; os_unfair_lock_unlock(&EQPLock);
}

static UIColor *EQPGreen(void) {return [UIColor colorWithRed:0.12 green:0.84 blue:0.40 alpha:1];}
static NSString *EQPFrequencyName(int i) {return i<5?[NSString stringWithFormat:@"%.0f Hz",EQPFrequencies[i]]:[NSString stringWithFormat:@"%.0f kHz",EQPFrequencies[i]/1000];}
static void EQPChoosePreset(NSUInteger index) {
    if (index>=EQPPresets.count) return;
    NSDictionary *p=EQPPresets[index]; EQPSettings s=EQPSnapshot();
    for (int i=0;i<EQP_BANDS;i++) s.gains[i]=[p[@"gains"][i] floatValue];
    s.enabled=YES; EQPWriteState(s); EQPSelected=p[@"name"]; EQPCommit();
}
@interface EQPBandCell : UITableViewCell
@property(nonatomic,strong) UISlider *slider;
@property(nonatomic,strong) UILabel *frequencyLabel;
@property(nonatomic,strong) UILabel *gainLabel;
@end
@implementation EQPBandCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self=[super initWithStyle:style reuseIdentifier:identifier]; if (!self) return nil;
    self.selectionStyle=UITableViewCellSelectionStyleNone;
    _frequencyLabel=[UILabel new]; _frequencyLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _gainLabel=[UILabel new]; _gainLabel.font=[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium]; _gainLabel.textAlignment=NSTextAlignmentRight;
    _slider=[UISlider new]; _slider.minimumTrackTintColor=EQPGreen();
    for (UIView *v in @[_frequencyLabel,_gainLabel,_slider]) {v.translatesAutoresizingMaskIntoConstraints=NO;[self.contentView addSubview:v];}
    [NSLayoutConstraint activateConstraints:@[
        [_frequencyLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_frequencyLabel.widthAnchor constraintEqualToConstant:58],
        [_frequencyLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_gainLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_gainLabel.widthAnchor constraintEqualToConstant:68],
        [_gainLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_slider.leadingAnchor constraintEqualToAnchor:_frequencyLabel.trailingAnchor constant:8],
        [_slider.trailingAnchor constraintEqualToAnchor:_gainLabel.leadingAnchor constant:-8],
        [_slider.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]]];
    return self;
}
@end
@interface EQPController : UITableViewController
@property(nonatomic,strong) NSTimer *statusTimer;
@end
static void EQPOpenEditor(UIViewController *source) {
    EQPController *editor=[[EQPController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle=UIModalPresentationPageSheet;
    [source presentViewController:nav animated:YES completion:nil];
}
@implementation EQPController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"SpotifyEQPro"; self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.view.tintColor=EQPGreen(); self.tableView.rowHeight=54;
    [self.tableView registerClass:EQPBandCell.class forCellReuseIdentifier:@"band"];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(savePreset)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel=@"Preset speichern";
    if (self.navigationController.viewControllers.firstObject==self) self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:EQPChanged object:nil];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; EQPApplyCurrent();
    __weak typeof(self) weakSelf=self;
    self.statusTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer){
        EQPController *s=weakSelf;
        if (s && !s.tableView.tracking && !s.tableView.dragging) [s.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:2 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
    }];
}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];[self.statusTimer invalidate];self.statusTimer=nil;}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)close {[self dismissViewControllerAnimated:YES completion:nil];}
- (void)changed:(NSNotification *)note { [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 4;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?3:(section==1?EQP_BANDS:(section==2?(NSInteger)EQPPresets.count+1:2));}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Wiedergabe",@"10 Bänder",@"Meine Presets",@"Werkzeuge"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section==0) return @"Headroom senkt den Gesamtpegel bei Anhebungen (max. 96 dB). Bei extremen Kombinationen ist Clipping weiterhin möglich. EQ wirkt nur auf die Wiedergabe auf diesem Gerät.";
    if (section==1) {EQPStatus s=EQPReadStatus();return [NSString stringWithFormat:@"%.0f bis %+.0f dB · 0,5-dB-Schritte. Band gedrückt halten für Min / 0 / Max. −96 dB ist eine starke Bandabsenkung, kein vollständiger Frequenz-Mute.",s.minGain,s.maxGain];}
    if (section==2) return @"Antippen zum Anwenden. Gedrückt halten zum Umbenennen, Überschreiben oder Löschen. Alle Presets sind bearbeitbar.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    EQPSettings s=EQPSnapshot();
    if (path.section==1) {
        EQPBandCell *cell=[tableView dequeueReusableCellWithIdentifier:@"band" forIndexPath:path];
        int i=(int)path.row; EQPStatus status=EQPReadStatus();
        cell.frequencyLabel.text=EQPFrequencyName(i); cell.gainLabel.text=[NSString stringWithFormat:@"%+.1f dB",s.gains[i]];
        cell.slider.minimumValue=status.minGain;cell.slider.maximumValue=status.maxGain;cell.slider.value=s.gains[i];cell.slider.tag=i;
        cell.slider.accessibilityLabel=EQPFrequencyName(i);cell.slider.accessibilityValue=cell.gainLabel.text;
        [cell.slider removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.slider addTarget:self action:@selector(sliderEnded:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
        return cell;
    }
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
    if (path.section==0 && path.row<2) {
        cell.textLabel.text=path.row==0?@"Equalizer aktiv":@"Automatischer Headroom";
        UISwitch *toggle=[UISwitch new];toggle.on=path.row==0?s.enabled:s.headroom;toggle.tag=path.row;toggle.onTintColor=EQPGreen();
        [toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;cell.selectionStyle=UITableViewCellSelectionStyleNone;
    } else if (path.section==0) {
        EQPStatus status=EQPReadStatus();
        if (!EQPHooksReady) cell.textLabel.text=@"Diese Spotify-Version wird noch nicht unterstützt";
        else if (EQPGetBool(EQPModel,@"connectActive")) cell.textLabel.text=@"Spotify Connect: EQ nur auf diesem Gerät";
        else if (status.error) cell.textLabel.text=[NSString stringWithFormat:@"Audio-EQ pausiert · Fehler %d",(int)status.error];
        else if (!status.updates) cell.textLabel.text=@"Warte auf lokale Audiowiedergabe …";
        else cell.textLabel.text=s.enabled?@"10-Band-EQ verbunden":@"EQ ausgeschaltet";
        cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · Vorverstärkung %+.1f dB",EQPSelected.length?EQPSelected:@"Ungespeichert",status.preamp];
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    } else if (path.section==2) {
        if (path.row==(NSInteger)EQPPresets.count) {cell.textLabel.text=@"＋ Aktuelle Einstellungen speichern";cell.textLabel.textColor=EQPGreen();}
        else {NSDictionary *p=EQPPresets[path.row];cell.textLabel.text=p[@"name"];if ([EQPSelected isEqualToString:p[@"name"]]) cell.accessoryType=UITableViewCellAccessoryCheckmark;}
    } else {cell.textLabel.text=path.row==0?@"Alle Bänder einstellen":@"Diagnose teilen";cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    return cell;
}
- (void)sliderChanged:(UISlider *)slider {
    EQPSettings s=EQPSnapshot();s.gains[slider.tag]=roundf(slider.value*2)/2;EQPWriteState(s);EQPSelected=@"";
    EQPBandCell *cell=(EQPBandCell *)[self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:slider.tag inSection:1]];
    cell.gainLabel.text=[NSString stringWithFormat:@"%+.1f dB",s.gains[slider.tag]];slider.accessibilityValue=cell.gainLabel.text;
    // Throttle driver reconfiguration during a drag; the final event always applies.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyDrag) object:nil];
    [self performSelector:@selector(applyDrag) withObject:nil afterDelay:0.04 inModes:@[NSRunLoopCommonModes]];
    EQPSave();
}
- (void)applyDrag {EQPApplyCurrent();}
- (void)sliderEnded:(UISlider *)slider {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyDrag) object:nil];EQPCommit();
}
- (void)toggle:(UISwitch *)toggle {EQPSettings s=EQPSnapshot();if (toggle.tag==0) s.enabled=toggle.on;else s.headroom=toggle.on;EQPWriteState(s);EQPCommit();}
- (void)savePreset {[self namePresetAtIndex:NSNotFound renameOnly:NO];}
- (void)namePresetAtIndex:(NSUInteger)index renameOnly:(BOOL)rename {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:rename?@"Preset umbenennen":@"Preset speichern" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"Name";if (index<EQPPresets.count) field.text=EQPPresets[index][@"name"];}];
    [alert addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Speichern" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
        NSString *name=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        for (NSUInteger i=0;i<EQPPresets.count;i++) if (i!=index && [EQPPresets[i][@"name"] caseInsensitiveCompare:name]==NSOrderedSame) {
            UIAlertController *duplicate=[UIAlertController alertControllerWithTitle:@"Name bereits vorhanden" message:@"Wähle einen anderen Namen oder überschreibe das vorhandene Preset über sein Menü." preferredStyle:UIAlertControllerStyleAlert];
            [duplicate addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:duplicate animated:YES completion:nil];return;
        }
        NSArray *gains=(rename && index<EQPPresets.count)?EQPPresets[index][@"gains"]:EQPValues(EQPSnapshot());
        BOOL wasSelected=index<EQPPresets.count && [EQPSelected isEqualToString:EQPPresets[index][@"name"]];
        NSDictionary *preset=@{@"name":name,@"gains":gains};
        if (index<EQPPresets.count) EQPPresets[index]=preset;else [EQPPresets addObject:preset];
        if (!rename || wasSelected) EQPSelected=name;
        EQPSave();[self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {
    if (path.section==1) return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(__unused NSArray *suggested){
        EQPStatus status=EQPReadStatus();NSMutableArray *actions=[NSMutableArray new];
        for (NSNumber *v in @[@(status.minGain),@0,@(status.maxGain)]) [actions addObject:[UIAction actionWithTitle:[NSString stringWithFormat:@"%+.0f dB",v.floatValue] image:nil identifier:nil handler:^(__unused UIAction *a){EQPSettings s=EQPSnapshot();s.gains[path.row]=v.floatValue;EQPWriteState(s);EQPSelected=@"";EQPCommit();}]];
        return [UIMenu menuWithTitle:EQPFrequencyName((int)path.row) children:actions];
    }];
    if (path.section!=2 || path.row>=(NSInteger)EQPPresets.count) return nil;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(__unused NSArray *suggested){
        UIAction *rename=[UIAction actionWithTitle:@"Umbenennen" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(__unused UIAction *a){[self namePresetAtIndex:path.row renameOnly:YES];}];
        UIAction *overwrite=[UIAction actionWithTitle:@"Mit aktuellen Reglern überschreiben" image:nil identifier:nil handler:^(__unused UIAction *a){
            if (path.row>=(NSInteger)EQPPresets.count) return;
            EQPSelected=EQPPresets[path.row][@"name"];EQPPresets[path.row]=@{@"name":EQPSelected,@"gains":EQPValues(EQPSnapshot())};EQPSave();[self.tableView reloadData];
        }];
        UIAction *remove=[UIAction actionWithTitle:@"Löschen" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *a){
            if (path.row>=(NSInteger)EQPPresets.count) return;
            if ([EQPSelected isEqualToString:EQPPresets[path.row][@"name"]]) EQPSelected=@"";
            [EQPPresets removeObjectAtIndex:path.row];EQPSave();[self.tableView reloadData];
        }];remove.attributes=UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:@"Preset" children:@[rename,overwrite,remove]];
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section==2) {if (path.row==(NSInteger)EQPPresets.count) [self savePreset];else EQPChoosePreset(path.row);}
    if (path.section!=3) return;
    if (path.row==1) {
        EQPStatus s=EQPReadStatus();EQPLog([NSString stringWithFormat:@"build=0.2 hooks=%d updates=%lu bands=%u error=%d range=%.1f..%.1f preamp=%.1f",EQPHooksReady,s.updates,(unsigned)s.bands,(int)s.error,s.minGain,s.maxGain,s.preamp]);
        UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[EQPLogURL()] applicationActivities:nil];
        share.popoverPresentationController.sourceView=[tableView cellForRowAtIndexPath:path];
        [self presentViewController:share animated:YES completion:nil];return;
    }
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Alle zehn Bänder" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    EQPStatus status=EQPReadStatus();
    for (NSNumber *v in @[@(status.minGain),@0,@(status.maxGain)]) [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Alle auf %+.0f dB",v.floatValue] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){EQPSettings s=EQPSnapshot();for (int i=0;i<EQP_BANDS;i++) s.gains[i]=v.floatValue;EQPWriteState(s);EQPSelected=@"";EQPCommit();}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView=[tableView cellForRowAtIndexPath:path];[self presentViewController:menu animated:YES completion:nil];
}
@end

static void EQPShowPresets(UIViewController *source, UIButton *button) {
    if (source.presentedViewController) return;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"EQ Presets" message:EQPSelected.length?EQPSelected:@"Ungespeichert" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i=0;i<EQPPresets.count;i++) {
        NSString *name=EQPPresets[i][@"name"];
        [sheet addAction:[UIAlertAction actionWithTitle:[EQPSelected isEqualToString:name]?[@"✓ " stringByAppendingString:name]:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){EQPChoosePreset(i);}]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Equalizer bearbeiten …" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        dispatch_async(dispatch_get_main_queue(), ^{EQPOpenEditor(source);});
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=button;sheet.popoverPresentationController.sourceRect=button.bounds;
    [source presentViewController:sheet animated:YES completion:nil];
}
static void EQPAttachButton(UIViewController *vc) {
    if (!vc.isViewLoaded) return;
    UIButton *button=objc_getAssociatedObject(vc,EQPButtonKey);
    if (!button) {
        button=[UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *config=[UIButtonConfiguration filledButtonConfiguration];
        config.title=@"EQ";config.image=[UIImage systemImageNamed:@"slider.horizontal.3"];config.imagePadding=6;
        config.baseBackgroundColor=[UIColor colorWithWhite:0.10 alpha:0.94];config.baseForegroundColor=EQPGreen();config.cornerStyle=UIButtonConfigurationCornerStyleCapsule;
        button.configuration=config;button.accessibilityLabel=@"EQ Presets auswählen";button.translatesAutoresizingMaskIntoConstraints=NO;
        __weak UIViewController *weakVC=vc;__weak UIButton *weakButton=button;
        [button addAction:[UIAction actionWithHandler:^(__unused UIAction *a){UIViewController *source=weakVC;if (source) EQPShowPresets(source,weakButton);}] forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:button];
        [NSLayoutConstraint activateConstraints:@[[button.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-16],[button.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-58],[button.heightAnchor constraintEqualToConstant:44],[button.widthAnchor constraintGreaterThanOrEqualToConstant:76]]];
        objc_setAssociatedObject(vc,EQPButtonKey,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [vc.view bringSubviewToFront:button];
}
static BOOL EQPMatches(Class cls, SEL sel, const char *ret, const char *arg, unsigned count) {
    Method m=class_getInstanceMethod(cls,sel);if (!m || method_getNumberOfArguments(m)!=count) return NO;
    char *r=method_copyReturnType(m);BOOL ok=r && !strcmp(r,ret);free(r);
    if (arg) {char *a=method_copyArgumentType(m,2);ok=ok && a && !strcmp(a,arg);free(a);}return ok;
}
static void EQPInstall(void) {
    Class model=NSClassFromString(@"SPTEqualizerModel");Class config=NSClassFromString(@"SPTEqualizer_EqualizerImplProperties");
    SEL apply=NSSelectorFromString(@"applyEqualizerToAudioUnit:");
    if (!EQPMatches(model,apply,"v","^{OpaqueAudioComponentInstance=}",3) || !EQPMatches(config,NSSelectorFromString(@"useCoreEqualizer"),"B",NULL,2) || !EQPMatches(model,NSSelectorFromString(@"applyEqualizer:"),"v","B",3)) return;
    EQPOriginalApply=method_setImplementation(class_getInstanceMethod(model,apply),(IMP)EQPApplyUnit);
    // The supplied Spotify binary reads this getter before choosing its audio path.
    method_setImplementation(class_getInstanceMethod(config,NSSelectorFromString(@"useCoreEqualizer")),imp_implementationWithBlock(^BOOL(__unused id self){return NO;}));
    // Capture fully owned models without hooking init/dealloc or writing private ivars.
    Class feature=NSClassFromString(@"SPTEqualizerFeatureImplementation");SEL getter=NSSelectorFromString(@"equalizerModel");
    if (EQPMatches(feature,getter,"@",NULL,2)) {
        IMP old=class_getMethodImplementation(feature,getter);
        method_setImplementation(class_getInstanceMethod(feature,getter),imp_implementationWithBlock(^id(id self){id m=((id(*)(id,SEL))old)(self,getter);EQPCaptureModel(m);return m;}));
    }
    SEL provide=NSSelectorFromString(@"provideEqualizerViewController");
    if (EQPMatches(feature,provide,"@",NULL,2)) method_setImplementation(class_getInstanceMethod(feature,provide),imp_implementationWithBlock(^id(id self){EQPCaptureModel(EQPGet(self,@"equalizerModel"));return [[EQPController alloc] initWithStyle:UITableViewStyleInsetGrouped];}));
    Class nowPlaying=NSClassFromString(@"_TtC19NowPlaying_ViewImpl24NowPlayingViewController");
    SEL appear=@selector(viewDidAppear:);
    if (EQPMatches(nowPlaying,appear,"v","B",3)) {
        IMP old=class_getMethodImplementation(nowPlaying,appear);
        method_setImplementation(class_getInstanceMethod(nowPlaying,appear),imp_implementationWithBlock(^(UIViewController *self,BOOL animated){((void(*)(id,SEL,BOOL))old)(self,appear,animated);EQPAttachButton(self);}));
    }
    SEL layout=@selector(viewDidLayoutSubviews);
    if (EQPMatches(nowPlaying,layout,"v",NULL,2)) {
        IMP old=class_getMethodImplementation(nowPlaying,layout);
        method_setImplementation(class_getInstanceMethod(nowPlaying,layout),imp_implementationWithBlock(^(UIViewController *self){((void(*)(id,SEL))old)(self,layout);EQPAttachButton(self);}));
    }
    EQPHooksReady=YES;
}
__attribute__((constructor)) static void SpotifyEQProInit(void) {
    @autoreleasepool {
        EQPLoad();EQPInstall();
        dispatch_async(dispatch_get_main_queue(), ^{EQPLog([NSString stringWithFormat:@"SpotifyEQPro 0.2 loaded; jailed Objective-C hooks=%d",EQPHooksReady]);});
    }
}
