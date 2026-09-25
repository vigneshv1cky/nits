#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef, io_service_t);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
extern int  DisplayServicesGetBrightness(CGDirectDisplayID, float *);
extern int  DisplayServicesSetBrightness(CGDirectDisplayID, float);
extern Boolean DisplayServicesCanChangeBrightness(CGDirectDisplayID);

#pragma mark - DDC (per external display)

typedef NS_ENUM(NSInteger, DDCState) { DDCOk = 0, DDCNoChannel = 1, DDCNoAnswer = 2 };

static NSString *regPath(io_service_t s) {
    io_string_t p;
    if (IORegistryEntryGetPath(s, kIOServicePlane, p) == KERN_SUCCESS) return @(p);
    return nil;
}

// "dispext0" / "disp0" token that both the framebuffer and its AV service share
static NSString *tokenInPath(NSString *path) {
    for (NSString *c in [path componentsSeparatedByString:@"/"]) {
        NSString *h = [[c componentsSeparatedByString:@"@"] firstObject];
        h = [[h componentsSeparatedByString:@":"] firstObject];
        if ([h hasPrefix:@"dispext"] || [h isEqualToString:@"disp0"]) return h;
    }
    return nil;
}

static NSString *tokenForDisplay(CGDirectDisplayID did) {
    uint32_t vend = CGDisplayVendorNumber(did), mod = CGDisplayModelNumber(did),
             ser  = CGDisplaySerialNumber(did);
    io_iterator_t it; io_service_t s; NSString *found = nil;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("AppleCLCD2"), &it) != KERN_SUCCESS) return nil;
    while ((s = IOIteratorNext(it))) {
        if (!found) {
            NSDictionary *da = CFBridgingRelease(IORegistryEntryCreateCFProperty(
                s, CFSTR("DisplayAttributes"), kCFAllocatorDefault, 0));
            NSDictionary *pa = da[@"ProductAttributes"];
            if (pa && [pa[@"LegacyManufacturerID"] unsignedIntValue] == vend
                   && [pa[@"ProductID"] unsignedIntValue] == mod
                   && [pa[@"SerialNumber"] unsignedIntValue] == ser) {
                found = tokenInPath(regPath(s));
            }
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return found;
}

static IOAVServiceRef avForToken(NSString *token) {
    if (!token) return NULL;
    io_iterator_t it; io_service_t s; IOAVServiceRef out = NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"), &it) != KERN_SUCCESS) return NULL;
    while ((s = IOIteratorNext(it))) {
        if (!out) {
            io_service_t parent = 0;
            if (IORegistryEntryGetParentEntry(s, kIOServicePlane, &parent) == KERN_SUCCESS && parent) {
                io_name_t pn = {0};
                IORegistryEntryGetName(parent, pn);
                NSString *ptok = [[@(pn) componentsSeparatedByString:@":"] firstObject];
                if ([ptok isEqualToString:token])
                    out = IOAVServiceCreateWithService(kCFAllocatorDefault, s);
                IOObjectRelease(parent);
            }
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return out;
}

static DDCState ddcSetOn(IOAVServiceRef av, uint8_t vcp, uint16_t v) {
    if (!av) return DDCNoChannel;
    uint8_t p[6] = {0x84,0x03,vcp,(uint8_t)(v>>8),(uint8_t)(v&0xFF),0};
    uint8_t c = 0x6E ^ 0x51; for (int i=0;i<5;i++) c ^= p[i]; p[5]=c;
    IOReturn r = IOAVServiceWriteI2C(av, 0x37, 0x51, p, 6);
    return (r == kIOReturnSuccess) ? DDCOk : DDCNoAnswer;
}

#pragma mark - model

@interface Disp : NSObject
@property CGDirectDisplayID did;
@property (strong) NSString *name;
@property BOOL builtin;
@property (assign) IOAVServiceRef av;
@property DDCState state;
@property (strong) NSTextField *wStatus;
// ui
@property (strong) NSSlider *wB, *wC, *mB, *mC;
@property (strong) NSTextField *wBVal, *wCVal, *wHint, *mBLab, *mCLab;
@end
@implementation Disp @end

#pragma mark - scroll support

@interface ScrollSlider : NSSlider @end
@implementation ScrollSlider { CGFloat _acc; }
- (void)scrollWheel:(NSEvent *)e {
    if (!self.isEnabled) return;
    int step = 0;
    if (e.hasPreciseScrollingDeltas) {          // trackpad
        _acc += e.scrollingDeltaY;
        if (fabs(_acc) < 3.0) return;
        step = (_acc > 0) ? 1 : -1;
        _acc = 0;
    } else {                                     // mouse wheel
        if (e.scrollingDeltaY == 0) return;
        step = (e.scrollingDeltaY > 0) ? 1 : -1;
    }
    int nv = self.intValue + step * 2;
    if (nv < (int)self.minValue) nv = (int)self.minValue;
    if (nv > (int)self.maxValue) nv = (int)self.maxValue;
    if (nv == self.intValue) return;
    self.intValue = nv;
    [NSApp sendAction:self.action to:self.target from:self];
}
@end

@interface ScrollCatcher : NSView
@property (weak) id handler;
@end
@implementation ScrollCatcher { CGFloat _acc; }
- (void)scrollWheel:(NSEvent *)e {
    int step = 0;
    if (e.hasPreciseScrollingDeltas) {
        _acc += e.scrollingDeltaY;
        if (fabs(_acc) < 3.0) return;
        step = (_acc > 0) ? 1 : -1; _acc = 0;
    } else {
        if (e.scrollingDeltaY == 0) return;
        step = (e.scrollingDeltaY > 0) ? 1 : -1;
    }
    if ([self.handler respondsToSelector:@selector(scrollStep:)])
        [self.handler performSelector:@selector(scrollStep:) withObject:@(step * 2)];
}
- (void)mouseDown:(NSEvent *)e { [self.superview mouseDown:e]; }
@end


static NSArray<Disp *> *enumerateDisplays(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSScreen *s in [NSScreen screens]) {
        NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
        if (!n) continue;
        Disp *d = [Disp new];
        d.did = n.unsignedIntValue;
        d.builtin = CGDisplayIsBuiltin(d.did);
        d.name = s.localizedName ?: (d.builtin ? @"Built-in Display" : @"External Display");
        if (!d.builtin) {
            d.av = avForToken(tokenForDisplay(d.did));
            d.state = d.av ? DDCOk : DDCNoChannel;
        }
        [out addObject:d];
    }
    [out sortUsingComparator:^NSComparisonResult(Disp *a, Disp *b) {
        if (a.builtin == b.builtin) return NSOrderedSame;
        return a.builtin ? NSOrderedAscending : NSOrderedDescending; }];
    return out;
}

#pragma mark - controller

@interface AppCtl : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *win;
@property (strong) NSStatusItem *item;
@property (strong) NSArray<Disp *> *displays;
@property CGFloat contentHeight;
@end

@implementation AppCtl

- (NSString *)keyFor:(Disp *)d suffix:(NSString *)s {
    return [NSString stringWithFormat:@"%@.%u.%@", d.builtin?@"int":@"ext", d.did, s];
}

- (void)applyBrightness:(int)v to:(Disp *)d {
    if (v<0) v=0; if (v>100) v=100;
    if (d.builtin) DisplayServicesSetBrightness(d.did, v/100.0f);
    else { d.state = ddcSetOn(d.av, 0x10, v); [self refreshStatus:d]; }
    d.wB.intValue=v; d.mB.intValue=v;
    d.wBVal.stringValue=[NSString stringWithFormat:@"%d",v];
    d.mBLab.stringValue=[NSString stringWithFormat:@"Brightness   %d",v];
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:[self keyFor:d suffix:@"b"]];
}

- (void)applyContrast:(int)v to:(Disp *)d {
    if (d.builtin) return;
    if (v<0) v=0; if (v>100) v=100;
    d.state = ddcSetOn(d.av, 0x12, v); [self refreshStatus:d];
    d.wC.intValue=v; d.mC.intValue=v;
    d.wCVal.stringValue=[NSString stringWithFormat:@"%d",v];
    d.mCLab.stringValue=[NSString stringWithFormat:@"Contrast   %d%@",v,v==75?@"":@"   ·   native 75"];
    d.wHint.hidden=(v==75);
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:[self keyFor:d suffix:@"c"]];
}

- (void)refreshStatus:(Disp *)d {
    if (!d.wStatus) return;
    switch (d.state) {
        case DDCOk:
            d.wStatus.stringValue = @"";
            d.wStatus.hidden = YES;
            break;
        case DDCNoChannel:
            d.wStatus.stringValue = @"No control channel — the cable or adapter is not carrying it";
            d.wStatus.textColor = [NSColor systemRedColor];
            d.wStatus.hidden = NO;
            break;
        case DDCNoAnswer:
            d.wStatus.stringValue = @"Monitor is not answering — check DDC/CI is enabled in its menu";
            d.wStatus.textColor = [NSColor systemRedColor];
            d.wStatus.hidden = NO;
            break;
    }
}

- (void)bMoved:(NSSlider *)s { [self applyBrightness:s.intValue to:(Disp *)objc_getAssociatedObject(s,"d")]; }
- (void)cMoved:(NSSlider *)s { [self applyContrast:s.intValue to:(Disp *)objc_getAssociatedObject(s,"d")]; }
- (void)preset:(id)s {
    Disp *d = (Disp *)objc_getAssociatedObject(s,"d");
    [self applyBrightness:(int)[(NSControl *)s tag] to:d];
}
- (void)resetC:(id)s { [self applyContrast:75 to:(Disp *)objc_getAssociatedObject(s,"d")]; }
- (void)allPreset:(NSMenuItem *)mi { for (Disp *d in self.displays) [self applyBrightness:(int)mi.tag to:d]; }
- (void)scrollStep:(NSNumber *)n {
    Disp *t = nil;
    for (Disp *d in self.displays) if (!d.builtin && d.state==DDCOk) { t = d; break; }
    if (!t) for (Disp *d in self.displays) if (!d.builtin) { t = d; break; }
    if (!t) t = self.displays.firstObject;
    if (!t) return;
    [self applyBrightness:t.wB.intValue + n.intValue to:t];
}

- (void)showWindow:(id)s { [self.win makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
- (void)quit:(id)s { [NSApp terminate:nil]; }

#pragma mark helpers

- (NSTextField *)lab:(NSString *)t f:(NSRect)r sz:(CGFloat)z w:(NSFontWeight)fw
                 col:(NSColor *)c al:(NSTextAlignment)a {
    NSTextField *l=[[NSTextField alloc] initWithFrame:r];
    l.stringValue=t?:@""; l.editable=NO; l.bordered=NO; l.drawsBackground=NO;
    l.font=[NSFont systemFontOfSize:z weight:fw]; l.textColor=c; l.alignment=a; return l;
}
- (NSSlider *)sl:(NSRect)r act:(SEL)a for:(Disp *)d {
    NSSlider *s=[[ScrollSlider alloc] initWithFrame:r];
    s.autoresizingMask=NSViewWidthSizable;
    s.minValue=0; s.maxValue=100; s.continuous=YES; s.target=self; s.action=a;
    objc_setAssociatedObject(s,"d",d,OBJC_ASSOCIATION_RETAIN); return s;
}
- (int)storedB:(Disp *)d {
    NSUserDefaults *u=[NSUserDefaults standardUserDefaults];
    NSString *k=[self keyFor:d suffix:@"b"];
    if ([u objectForKey:k]) return (int)[u integerForKey:k];
    if (d.builtin) { float f=0.5f; DisplayServicesGetBrightness(d.did,&f); return (int)roundf(f*100); }
    return 40;
}
- (int)storedC:(Disp *)d {
    NSUserDefaults *u=[NSUserDefaults standardUserDefaults];
    NSString *k=[self keyFor:d suffix:@"c"];
    return [u objectForKey:k] ? (int)[u integerForKey:k] : 75;
}

#pragma mark window

- (void)buildWindow {
    self.displays = enumerateDisplays();
    CGFloat W=440, M=28, CW=W-M*2;
    CGFloat CH=20;
    for (Disp *d in self.displays) CH += d.builtin ? 140 : 300;
    if (CH<220) CH=220;
    CGFloat H = CH;

    if (self.win) [self.win orderOut:nil];
    self.win=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,W,H)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable
                 |NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
          backing:NSBackingStoreBuffered defer:NO];
    self.win.title=@"Nits"; self.win.titlebarAppearsTransparent=YES;
    self.win.delegate=self; self.win.releasedWhenClosed=NO;
    self.win.minSize=NSMakeSize(W,H);
    self.win.maxSize=NSMakeSize(900,H);
    [self.win center];

    NSVisualEffectView *bg=[[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,W,H)];
    bg.material=NSVisualEffectMaterialWindowBackground;
    bg.blendingMode=NSVisualEffectBlendingModeBehindWindow;
    bg.state=NSVisualEffectStateActive;
    bg.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.win.contentView=bg;

    NSView *doc = bg;
    self.contentHeight=CH;

    if (self.displays.count==0) {
        [doc addSubview:[self lab:@"No displays detected" f:NSMakeRect(M,CH/2,CW,20) sz:13
                              w:NSFontWeightMedium col:[NSColor secondaryLabelColor] al:NSTextAlignmentCenter]];
        return;
    }

    CGFloat y=CH-30;
    for (Disp *d in self.displays) {
        [doc addSubview:[self lab:d.name f:NSMakeRect(M,y,CW,19) sz:14 w:NSFontWeightSemibold
                             col:[NSColor labelColor] al:NSTextAlignmentLeft]];
        y-=20;
        NSString *sub = d.builtin ? @"Built-in  ·  native macOS control"
                                  : @"External  ·  hardware backlight over DDC";
        [doc addSubview:[self lab:sub f:NSMakeRect(M,y,CW,15) sz:11 w:NSFontWeightRegular
                             col:[NSColor secondaryLabelColor] al:NSTextAlignmentLeft]];
        y-=16;
        d.wStatus=[self lab:@"" f:NSMakeRect(M,y,CW,15) sz:11 w:NSFontWeightMedium
                         col:[NSColor systemRedColor] al:NSTextAlignmentLeft];
        d.wStatus.hidden=YES; [doc addSubview:d.wStatus];
        [self refreshStatus:d];
        y-=20;

        [doc addSubview:[self lab:@"BRIGHTNESS" f:NSMakeRect(M,y,160,14) sz:10 w:NSFontWeightSemibold
                             col:[NSColor secondaryLabelColor] al:NSTextAlignmentLeft]];
        d.wBVal=[self lab:@"" f:NSMakeRect(W-M-60,y-4,60,20) sz:17 w:NSFontWeightMedium
                       col:[NSColor labelColor] al:NSTextAlignmentRight];
        [doc addSubview:d.wBVal];
        y-=28;
        d.wB=[self sl:NSMakeRect(M,y,CW,20) act:@selector(bMoved:) for:d];
        [doc addSubview:d.wB];
        y-=40;

        if (!d.builtin) {
            [doc addSubview:[self lab:@"CONTRAST" f:NSMakeRect(M,y,160,14) sz:10 w:NSFontWeightSemibold
                                 col:[NSColor secondaryLabelColor] al:NSTextAlignmentLeft]];
            d.wCVal=[self lab:@"" f:NSMakeRect(W-M-60,y-4,60,20) sz:17 w:NSFontWeightMedium
                           col:[NSColor labelColor] al:NSTextAlignmentRight];
            [doc addSubview:d.wCVal];
            y-=28;
            d.wC=[self sl:NSMakeRect(M,y,CW,20) act:@selector(cMoved:) for:d];
            [doc addSubview:d.wC];
            y-=20;
            d.wHint=[self lab:@"native is 75  ·  click to restore" f:NSMakeRect(M,y,CW,14) sz:10
                            w:NSFontWeightRegular col:[NSColor tertiaryLabelColor] al:NSTextAlignmentLeft];
            [doc addSubview:d.wHint];
            NSButton *hit=[[NSButton alloc] initWithFrame:NSMakeRect(M,y-2,190,18)];
            hit.title=@""; hit.bordered=NO; hit.transparent=YES;
            hit.target=self; hit.action=@selector(resetC:);
            objc_setAssociatedObject(hit,"d",d,OBJC_ASSOCIATION_RETAIN);
            [doc addSubview:hit];
            y-=40;
        }

        NSArray *t=@[@"Day",@"Evening",@"Night",@"Min"], *v=@[@70,@35,@10,@0];
        CGFloat gap=8, bw=(CW-gap*3)/4.0;
        for (int i=0;i<4;i++){
            NSButton *b=[[NSButton alloc] initWithFrame:NSMakeRect(M+i*(bw+gap),y,bw,28)];
            b.title=t[i]; b.bezelStyle=NSBezelStyleRounded;
            b.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
            b.tag=[v[i] integerValue]; b.target=self; b.action=@selector(preset:);
            objc_setAssociatedObject(b,"d",d,OBJC_ASSOCIATION_RETAIN);
            [doc addSubview:b];
        }
        y-=36;

        if (d != self.displays.lastObject) {
            NSBox *r=[[NSBox alloc] initWithFrame:NSMakeRect(M,y,CW,1)];
            r.boxType=NSBoxSeparator; [doc addSubview:r];
            y-=24;
        }
    }
}

#pragma mark menu bar

- (void)buildMenuBar {
    if (!self.item) {
        self.item=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        NSImage *i=[NSImage imageWithSystemSymbolName:@"sun.max" accessibilityDescription:@"Nits"];
        i.template=YES; self.item.button.image=i;
        ScrollCatcher *sc=[[ScrollCatcher alloc] initWithFrame:self.item.button.bounds];
        sc.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        sc.handler=self;
        [self.item.button addSubview:sc];
    }
    NSMenu *m=[[NSMenu alloc] init]; m.autoenablesItems=NO;
    CGFloat PW=272;

    for (Disp *d in self.displays) {
        CGFloat ph = d.builtin ? 116 : 164;
        NSView *p=[[NSView alloc] initWithFrame:NSMakeRect(0,0,PW,ph)];
        CGFloat py=ph-20;
        NSString *hdr=[NSString stringWithFormat:@"%@  ·  %@",
                       d.builtin?@"BUILT-IN":@"EXTERNAL", d.name.uppercaseString];
        [p addSubview:[self lab:hdr f:NSMakeRect(14,py,PW-28,15) sz:10 w:NSFontWeightSemibold
                            col:[NSColor secondaryLabelColor] al:NSTextAlignmentLeft]];
        py-=24;
        d.mBLab=[self lab:@"" f:NSMakeRect(14,py,PW-28,16) sz:12 w:NSFontWeightMedium
                       col:[NSColor labelColor] al:NSTextAlignmentLeft];
        [p addSubview:d.mBLab]; py-=24;
        d.mB=[self sl:NSMakeRect(14,py,PW-28,20) act:@selector(bMoved:) for:d];
        [p addSubview:d.mB]; py-=26;
        if (!d.builtin) {
            d.mCLab=[self lab:@"" f:NSMakeRect(14,py,PW-28,16) sz:12 w:NSFontWeightMedium
                           col:[NSColor labelColor] al:NSTextAlignmentLeft];
            [p addSubview:d.mCLab]; py-=24;
            d.mC=[self sl:NSMakeRect(14,py,PW-28,20) act:@selector(cMoved:) for:d];
            [p addSubview:d.mC];
        }
        NSArray *pt=@[@"Day",@"Evening",@"Night",@"Min"], *pv=@[@70,@35,@10,@0];
        CGFloat pg=6, pbw=(PW-28-pg*3)/4.0;
        for (int i=0;i<4;i++){
            NSButton *pb=[[NSButton alloc] initWithFrame:NSMakeRect(14+i*(pbw+pg),10,pbw,26)];
            pb.title=pt[i]; pb.bezelStyle=NSBezelStyleRounded;
            pb.font=[NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
            pb.tag=[pv[i] integerValue]; pb.target=self; pb.action=@selector(preset:);
            objc_setAssociatedObject(pb,"d",d,OBJC_ASSOCIATION_RETAIN);
            [p addSubview:pb];
        }
        NSMenuItem *pi=[[NSMenuItem alloc] init]; pi.view=p; [m addItem:pi];
        [m addItem:[NSMenuItem separatorItem]];
    }

    NSMenuItem *ow=[[NSMenuItem alloc] initWithTitle:@"Open Nits Window"
        action:@selector(showWindow:) keyEquivalent:@"o"];
    ow.target=self; ow.enabled=YES; [m addItem:ow];
    NSMenuItem *q=[[NSMenuItem alloc] initWithTitle:@"Quit Nits"
        action:@selector(quit:) keyEquivalent:@"q"];
    q.target=self; q.enabled=YES; [m addItem:q];
    self.item.menu=m;
}

- (void)loadValues {
    for (Disp *d in self.displays) {
        int b=[self storedB:d], c=[self storedC:d];
        d.wB.intValue=b; d.mB.intValue=b;
        d.wBVal.stringValue=[NSString stringWithFormat:@"%d",b];
        d.mBLab.stringValue=[NSString stringWithFormat:@"Brightness   %d",b];
        if (!d.builtin) {
            d.wC.intValue=c; d.mC.intValue=c;
            d.wCVal.stringValue=[NSString stringWithFormat:@"%d",c];
            d.mCLab.stringValue=[NSString stringWithFormat:@"Contrast   %d%@",c,c==75?@"":@"   ·   native 75"];
            d.wHint.hidden=(c==75);
        }
    }
}

- (void)screensChanged { [self buildWindow]; [self buildMenuBar]; [self loadValues]; [self showWindow:nil]; }

- (void)setAppIcon {
    // macOS icon grid: artwork occupies ~80% of the canvas, with transparent margins
    CGFloat C = 512, SQ = 412, OFF = (C - SQ) / 2.0, RAD = SQ * 0.225;
    NSImage *sym=[NSImage imageWithSystemSymbolName:@"sun.max.fill" accessibilityDescription:nil];
    sym=[sym imageWithSymbolConfiguration:
         [NSImageSymbolConfiguration configurationWithPointSize:SQ*0.56 weight:NSFontWeightRegular]];
    NSImage *ic=[[NSImage alloc] initWithSize:NSMakeSize(C,C)];
    [ic lockFocus];
    NSRect sq = NSMakeRect(OFF, OFF, SQ, SQ);
    NSGradient *g=[[NSGradient alloc] initWithStartingColor:
        [NSColor colorWithCalibratedRed:1.00 green:0.82 blue:0.35 alpha:1.0]
        endingColor:[NSColor colorWithCalibratedRed:0.96 green:0.66 blue:0.13 alpha:1.0]];
    NSBezierPath *rr=[NSBezierPath bezierPathWithRoundedRect:sq xRadius:RAD yRadius:RAD];
    [g drawInBezierPath:rr angle:-90];
    [[NSColor colorWithCalibratedWhite:0.16 alpha:1.0] set];
    CGFloat ss = SQ*0.56;
    [sym drawInRect:NSMakeRect(OFF+(SQ-ss)/2.0, OFF+(SQ-ss)/2.0, ss, ss)
           fromRect:NSZeroRect operation:NSCompositingOperationSourceAtop fraction:1.0];
    [ic unlockFocus]; NSApp.applicationIconImage=ic;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)s hasVisibleWindows:(BOOL)v {
    if(!v)[self showWindow:nil]; return YES; }
- (BOOL)windowShouldClose:(NSWindow *)w { [w orderOut:nil]; return NO; }

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [self setAppIcon]; [self buildWindow]; [self buildMenuBar]; [self loadValues];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [self showWindow:nil];
}
@end

int main(void){ @autoreleasepool {
    NSApplication *app=[NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    AppCtl *c=[[AppCtl alloc] init]; app.delegate=c;
    objc_setAssociatedObject(app,"ctl",c,OBJC_ASSOCIATION_RETAIN);
    [app run]; } return 0; }
