// AutoClicker.m - in-process multi-target auto tapper for sideloaded (jailed) apps.
// Inject as a dylib (iGameGod / Sideloadly / ESign / TrollStore etc). No jailbreak needed.
//
// UI:  floating "AC" button  -> tap = start/stop, drag = move
//      gear button (or long-press AC) -> panel: click speed, clicks per tap,
//      number of targets, mode (Sequential / Simultaneous), More... (jitter, delays)
//      Presets… -> save / load / delete setups, optional auto-load when the game opens
//      red numbered crosshairs -> drag each one onto its target
//
// Sequential:   each tick taps target 1, 2, 3... with a small gap between them.
// Simultaneous: each tick sends ALL targets as one multi-touch event (like several fingers).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

// ---------- private API declarations ----------
typedef void *IOHIDEventRef;
typedef IOHIDEventRef (*CreateDigitizer_t)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                           uint32_t, uint32_t, double, double, double, double,
                                           double, boolean_t, boolean_t, uint32_t);
typedef IOHIDEventRef (*CreateFinger_t)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                        double, double, double, double, double, boolean_t,
                                        boolean_t, uint32_t);
typedef void (*AppendEvent_t)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*SetSenderID_t)(IOHIDEventRef, uint64_t);

static CreateDigitizer_t pCreateDigitizer;
static CreateFinger_t pCreateFinger;
static AppendEvent_t pAppend;
static SetSenderID_t pSetSender;

@interface UITouch (AC)
- (void)setWindow:(UIWindow *)w;
- (void)setView:(UIView *)v;
- (void)setTapCount:(NSUInteger)c;
- (void)setPhase:(UITouchPhase)p;
- (void)setTimestamp:(NSTimeInterval)t;
- (void)_setLocationInWindow:(CGPoint)p resetPrevLocation:(BOOL)r;
- (void)_setIsFirstTouchForView:(BOOL)f;
- (void)_setHidEvent:(IOHIDEventRef)e;
@end

@interface UIEvent (AC)
- (void)_setHIDEvent:(IOHIDEventRef)e;
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)t forDelayedDelivery:(BOOL)d;
@end

@interface UIApplication (AC)
- (UIEvent *)_touchesEvent;
@end

// ---------- HID event construction ----------
// Builds one digitizer parent event containing one finger child per point.
static IOHIDEventRef MakeHID(const CGPoint *pts, NSUInteger n, BOOL down) {
    if (!pCreateDigitizer || !pCreateFinger || !pAppend || n == 0) return NULL;
    CGSize s = [UIScreen mainScreen].bounds.size;
    uint64_t ts = mach_absolute_time();
    uint32_t mask = 0x1 | 0x2; // range | touch
    IOHIDEventRef parent = pCreateDigitizer(kCFAllocatorDefault, ts, 3, 0, 0, mask, 0,
                                            pts[0].x / s.width, pts[0].y / s.height, 0,
                                            0, 0, down, down, 0);
    for (NSUInteger i = 0; i < n; i++) {
        IOHIDEventRef f = pCreateFinger(kCFAllocatorDefault, ts, (uint32_t)(i + 1), (uint32_t)(i + 2),
                                        mask, pts[i].x / s.width, pts[i].y / s.height, 0,
                                        down ? 1.0 : 0.0, 0, down, down, 0);
        pAppend(parent, f, 0);
        CFRelease(f);
    }
    if (pSetSender) pSetSender(parent, 0xDEFACEDBEEFFECE5ULL);
    return parent;
}

static UIWindow *TargetWindow(void) {
    UIWindow *best = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.windowLevel > UIWindowLevelNormal + 1) continue; // skip our overlay / alerts
            if (w.isKeyWindow) return w;
            if (!best && !w.hidden) best = w;
        }
    }
    return best;
}

// iOS 16 has no -_setLocationInWindow:resetPrevLocation: on UITouch (or it was renamed),
// so fall back to writing UITouch's own location ivars directly.
static NSString *LocationMethodsHint(void) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList([UITouch class], &n);
    NSMutableArray *a = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        NSString *nm = NSStringFromSelector(method_getName(ms[i]));
        if ([nm.lowercaseString containsString:@"location"]) [a addObject:nm];
    }
    free(ms);
    return a.count ? [a componentsJoinedByString:@", "] : @"(none)";
}

static BOOL SetTouchLocation(UITouch *t, CGPoint p, BOOL reset) {
    SEL sel = @selector(_setLocationInWindow:resetPrevLocation:);
    if ([t respondsToSelector:sel]) {
        [t _setLocationInWindow:p resetPrevLocation:reset];
        return YES;
    }
    Ivar cur = class_getInstanceVariable([UITouch class], "_locationInWindow");
    Ivar prev = class_getInstanceVariable([UITouch class], "_previousLocationInWindow");
    if (!cur) return NO;
    const char *enc = ivar_getTypeEncoding(cur);
    if (!enc || strncmp(enc, "{CGPoint", 8) != 0) return NO;
    uint8_t *base = (uint8_t *)(__bridge void *)t;
    CGPoint *pc = (CGPoint *)(base + ivar_getOffset(cur));
    if (prev) {
        CGPoint *pp = (CGPoint *)(base + ivar_getOffset(prev));
        *pp = reset ? p : *pc;
    }
    *pc = p;
    return YES;
}

// Returns nil on success, or a short description of what went wrong.
#define NEED(obj, sel) if (![(obj) respondsToSelector:@selector(sel)]) { \
    return [NSString stringWithFormat:@"missing -[%@ %s]", NSStringFromClass([(obj) class]), #sel]; }

static NSString *SendTouches(UIWindow *win, NSArray<NSValue *> *points, NSArray<UITouch *> *touches,
                             UITouchPhase phase) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        NSUInteger n = points.count;
        CGPoint pts[n];
        for (NSUInteger i = 0; i < n; i++) pts[i] = points[i].CGPointValue;
        BOOL down = (phase != UITouchPhaseEnded);

        NEED(app, _touchesEvent)
        UIEvent *ev = [app _touchesEvent];
        if (!ev) return @"_touchesEvent returned nil";
        NEED(ev, _clearTouches)
        NEED(ev, _addTouch:forDelayedDelivery:)
        [ev _clearTouches];

        for (NSUInteger i = 0; i < n; i++) {
            UITouch *t = touches[i];
            NEED(t, setWindow:)
            NEED(t, setView:)
            NEED(t, setPhase:)
            UIView *view = [win hitTest:pts[i] withEvent:nil] ?: win;
            [t setWindow:win];
            [t setView:view];
            if ([t respondsToSelector:@selector(setTapCount:)]) [t setTapCount:1];
            [t setPhase:phase];
            if ([t respondsToSelector:@selector(setTimestamp:)])
                [t setTimestamp:[[NSProcessInfo processInfo] systemUptime]];
            if (!SetTouchLocation(t, pts[i], phase == UITouchPhaseBegan))
                return [NSString stringWithFormat:@"cannot set touch location. UITouch location methods: %@",
                        LocationMethodsHint()];
            if (phase == UITouchPhaseBegan && [t respondsToSelector:@selector(_setIsFirstTouchForView:)])
                [t _setIsFirstTouchForView:YES];

            IOHIDEventRef one = MakeHID(&pts[i], 1, down);
            if (one && [t respondsToSelector:@selector(_setHidEvent:)]) [t _setHidEvent:one];
            if (one) CFRelease(one);

            [ev _addTouch:t forDelayedDelivery:NO];
        }

        IOHIDEventRef all = MakeHID(pts, n, down);
        if (all && [ev respondsToSelector:@selector(_setHIDEvent:)]) [ev _setHIDEvent:all];
        [app sendEvent:ev];
        if (all) CFRelease(all);
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
}

static void ReportError(NSString *err);

// Tap = began, then ended 30ms later, for the given set of points (1 or many at once).
static void TapPoints(NSArray<NSValue *> *points) {
    UIWindow *win = TargetWindow();
    if (!win || points.count == 0) return;
    NSMutableArray *touches = [NSMutableArray array];
    for (NSUInteger i = 0; i < points.count; i++) [touches addObject:[[UITouch alloc] init]];
    NSString *err = SendTouches(win, points, touches, UITouchPhaseBegan);
    if (err) { ReportError(err); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *e2 = SendTouches(win, points, touches, UITouchPhaseEnded);
        if (e2) ReportError(e2);
    });
}

// ---------- overlay UI ----------
@interface ACWindow : UIWindow
@end
@implementation ACWindow
- (UIView *)hitTest:(CGPoint)pt withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:pt withEvent:e];
    return (v == self || v == self.rootViewController.view) ? nil : v; // pass-through
}
@end

static NSString *const kPresetsKey  = @"AutoClickerPresets";
static NSString *const kAutoLoadKey = @"AutoClickerAutoLoad";
#define kPanelH 276

static const double kCPS[] = {0.5, 1, 2, 3, 5, 8, 10, 15, 20, 30, 50};
#define kCPSCount ((NSInteger)(sizeof(kCPS) / sizeof(kCPS[0])))

@interface ACController : UIViewController
@property (nonatomic, strong) UIButton *toggle;
@property (nonatomic, strong) UIButton *gear;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, strong) UILabel *burstLabel;
@property (nonatomic, strong) UILabel *targetLabel;
@property (nonatomic, strong) UIButton *modeButton;
@property (nonatomic, strong) NSMutableArray<UILabel *> *targets;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) NSTimeInterval interval;   // seconds between ticks (1 / clicks-per-second)
@property (nonatomic) NSTimeInterval gap;        // delay between targets in sequential mode
@property (nonatomic) NSTimeInterval burstGap;   // max delay between the clicks of one burst
@property (nonatomic) NSInteger burst;           // clicks per target per tick (1-10)
@property (nonatomic) NSInteger jitter;          // px
@property (nonatomic) BOOL simultaneous;
@property (nonatomic) BOOL running;
@end

static ACController *gCtl;

@implementation ACController

- (void)viewDidLoad {
    [super viewDidLoad];
    gCtl = self;
    self.view.backgroundColor = UIColor.clearColor;
    self.interval = 0.1;
    self.gap = 0.01;
    self.burstGap = 0.06;
    self.burst = 1;
    self.targets = [NSMutableArray array];
    [self addTarget];

    self.toggle = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggle.frame = CGRectMake(20, 120, 52, 52);
    self.toggle.layer.cornerRadius = 26;
    self.toggle.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    [self.toggle setTitle:@"AC" forState:UIControlStateNormal];
    [self.toggle setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.toggle addTarget:self action:@selector(flip) forControlEvents:UIControlEventTouchUpInside];
    [self.toggle addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    [self.toggle addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)]];
    [self.view addSubview:self.toggle];

    self.gear = [UIButton buttonWithType:UIButtonTypeSystem];
    self.gear.frame = CGRectMake(0, 0, 40, 40);
    self.gear.layer.cornerRadius = 20;
    self.gear.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    [self.gear setTitle:@"⚙" forState:UIControlStateNormal];
    [self.gear setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.gear.titleLabel.font = [UIFont systemFontOfSize:20];
    [self.gear addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.gear];

    [self buildPanel];
    [self layoutDock];
    [self refreshUI];

    NSString *autoName = [[NSUserDefaults standardUserDefaults] stringForKey:kAutoLoadKey];
    if (autoName.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kPresetsKey];
            NSDictionary *p = all[autoName];
            if ([p isKindOfClass:[NSDictionary class]] && [self applyPreset:p])
                [self toast:[NSString stringWithFormat:@"Loaded preset: %@", autoName]];
        });
    }
}

// ----- panel -----
- (UIButton *)smallButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, 40, 34);
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    b.layer.cornerRadius = 8;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UILabel *)textLabel:(NSString *)text frame:(CGRect)f align:(NSTextAlignment)a {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = text;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    l.textAlignment = a;
    return l;
}

- (UILabel *)addRow:(NSString *)title y:(CGFloat)y minus:(SEL)minus plus:(SEL)plus {
    [self.panel addSubview:[self textLabel:title frame:CGRectMake(12, y, 92, 34) align:NSTextAlignmentLeft]];
    UIButton *m = [self smallButton:@"−" action:minus];
    m.frame = CGRectMake(104, y, 40, 34);
    [self.panel addSubview:m];
    UILabel *v = [self textLabel:@"" frame:CGRectMake(146, y, 54, 34) align:NSTextAlignmentCenter];
    v.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
    [self.panel addSubview:v];
    UIButton *p = [self smallButton:@"+" action:plus];
    p.frame = CGRectMake(202, y, 40, 34);
    [self.panel addSubview:p];
    return v;
}

- (void)buildPanel {
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 254, kPanelH)];
    self.panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    self.panel.layer.cornerRadius = 14;
    self.panel.hidden = YES;

    self.speedLabel  = [self addRow:@"Click speed" y:12  minus:@selector(speedDown) plus:@selector(speedUp)];
    self.burstLabel  = [self addRow:@"Clicks / tap" y:56  minus:@selector(burstDown) plus:@selector(burstUp)];
    self.targetLabel = [self addRow:@"Targets"      y:100 minus:@selector(targetDown) plus:@selector(targetUp)];

    self.modeButton = [self smallButton:@"" action:@selector(toggleMode)];
    self.modeButton.frame = CGRectMake(12, 144, 230, 34);
    self.modeButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.panel addSubview:self.modeButton];

    UIButton *presets = [self smallButton:@"Presets… (save / load)" action:@selector(openPresets)];
    presets.frame = CGRectMake(12, 188, 230, 34);
    presets.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.panel addSubview:presets];

    UIButton *more = [self smallButton:@"More… (jitter, delays)" action:@selector(openMore)];
    more.frame = CGRectMake(12, 232, 230, 34);
    more.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.panel addSubview:more];

    [self.view addSubview:self.panel];
}

- (void)layoutDock {
    CGSize v = self.view.bounds.size;
    CGFloat gx = CGRectGetMaxX(self.toggle.frame) + 26;
    if (gx + 22 > v.width) gx = CGRectGetMinX(self.toggle.frame) - 26;
    self.gear.center = CGPointMake(gx, self.toggle.center.y);
    CGFloat pw = 254, ph = kPanelH;
    CGFloat x = MAX(8, MIN(self.toggle.frame.origin.x, v.width - pw - 8));
    CGFloat y = CGRectGetMaxY(self.toggle.frame) + 8;
    if (y + ph > v.height - 8) y = MAX(8, self.toggle.frame.origin.y - ph - 8);
    self.panel.frame = CGRectMake(x, y, pw, ph);
}

- (void)refreshUI {
    self.speedLabel.text = [NSString stringWithFormat:@"%.3g/s", 1.0 / self.interval];
    self.burstLabel.text = [NSString stringWithFormat:@"x%ld", (long)self.burst];
    self.targetLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)self.targets.count];
    [self.modeButton setTitle:(self.simultaneous ? @"Mode: Simultaneous (tap to switch)"
                                                 : @"Mode: Sequential (tap to switch)")
                     forState:UIControlStateNormal];
}

- (void)togglePanel {
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) { [self layoutDock]; [self refreshUI]; }
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [self togglePanel];
}

// ----- panel actions -----
- (void)stepSpeed:(int)dir {
    double cps = 1.0 / self.interval;
    if (dir > 0 && cps >= kCPS[kCPSCount - 1]) return;
    if (dir < 0 && cps <= kCPS[0]) return;
    double next = cps;
    if (dir > 0) {
        for (NSInteger i = 0; i < kCPSCount; i++)
            if (kCPS[i] > cps * 1.001) { next = kCPS[i]; break; }
    } else {
        for (NSInteger i = kCPSCount - 1; i >= 0; i--)
            if (kCPS[i] < cps * 0.999) { next = kCPS[i]; break; }
    }
    self.interval = 1.0 / next;
    [self restartIfRunning];
    [self refreshUI];
}
- (void)speedUp   { [self stepSpeed:+1]; }
- (void)speedDown { [self stepSpeed:-1]; }

- (void)burstUp   { if (self.burst < 10) self.burst++; [self refreshUI]; }
- (void)burstDown { if (self.burst > 1)  self.burst--; [self refreshUI]; }

- (void)targetUp   { if (self.targets.count < 10) [self addTarget]; [self refreshUI]; }
- (void)targetDown { [self removeTarget]; [self refreshUI]; }

- (void)toggleMode { self.simultaneous = !self.simultaneous; [self refreshUI]; }

// ----- targets -----
- (void)addTarget {
    UILabel *c = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 56, 44)];
    c.font = [UIFont boldSystemFontOfSize:26];
    c.textAlignment = NSTextAlignmentCenter;
    c.textColor = UIColor.redColor;
    c.userInteractionEnabled = YES;
    // Every new target spawns at the center of the screen; drag it where you want it.
    CGSize vs = self.view.bounds.size;
    if (vs.width < 100) vs = [UIScreen mainScreen].bounds.size;
    c.center = CGPointMake(vs.width / 2, vs.height / 2);
    [c addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    if (self.toggle) [self.view insertSubview:c belowSubview:self.toggle];
    else [self.view addSubview:c];
    [self.targets addObject:c];
    [self relabel];
}

- (void)removeTarget {
    if (self.targets.count <= 1) return;
    [self.targets.lastObject removeFromSuperview];
    [self.targets removeLastObject];
    [self relabel];
}

- (void)relabel {
    for (NSUInteger i = 0; i < self.targets.count; i++)
        self.targets[i].text = [NSString stringWithFormat:@"⌖%lu", (unsigned long)(i + 1)];
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self.view];
    CGSize vs = self.view.bounds.size;
    CGFloat hw = g.view.bounds.size.width / 2, hh = g.view.bounds.size.height / 2;
    CGFloat nx = MAX(hw, MIN(vs.width - hw, g.view.center.x + d.x));   // keep fully on screen
    CGFloat ny = MAX(hh, MIN(vs.height - hh, g.view.center.y + d.y));
    g.view.center = CGPointMake(nx, ny);
    [g setTranslation:CGPointMake(0, 0) inView:self.view];
    if (g.view == self.toggle) [self layoutDock];
}

// ----- running -----
- (void)flip {
    self.running = !self.running;
    self.toggle.backgroundColor = self.running ? [UIColor colorWithRed:0.1 green:0.6 blue:0.2 alpha:0.85]
                                               : [UIColor colorWithWhite:0 alpha:0.6];
    [self.timer invalidate];
    self.timer = nil;
    if (self.running) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:self.interval target:self
                                                    selector:@selector(fire) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
}

- (CGPoint)jittered:(CGPoint)p {
    if (self.jitter > 0) {
        p.x += (int)arc4random_uniform((uint32_t)self.jitter * 2 + 1) - self.jitter;
        p.y += (int)arc4random_uniform((uint32_t)self.jitter * 2 + 1) - self.jitter;
    }
    return p;
}

static void RunAfter(NSTimeInterval delay, NSArray<NSValue *> *pts) {
    if (delay <= 0.0005) { TapPoints(pts); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ TapPoints(pts); });
}

- (void)fire {
    NSInteger n = MAX(1, self.burst);
    // Keep a whole burst inside one tick so bursts never pile up.
    NSTimeInterval bg = (n > 1) ? MAX(0.01, MIN(self.burstGap, self.interval / n)) : 0;

    for (NSInteger b = 0; b < n; b++) {
        NSTimeInterval base = b * bg;
        NSMutableArray<NSValue *> *pts = [NSMutableArray array];
        for (UILabel *t in self.targets)
            [pts addObject:[NSValue valueWithCGPoint:[self jittered:t.center]]];

        if (self.simultaneous) {
            RunAfter(base, pts); // all targets in one multi-touch event
        } else {
            for (NSUInteger i = 0; i < pts.count; i++)
                RunAfter(base + i * self.gap, @[pts[i]]);
        }
    }
}

- (void)failWith:(NSString *)err {
    if (self.running) [self flip];   // stop the clicker
    if (self.presentedViewController) return;
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"Auto Clicker stopped"
        message:[NSString stringWithFormat:@"%@\n\n(iOS %@) Send a screenshot of this.", err,
                 [UIDevice currentDevice].systemVersion]
        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)restartIfRunning {
    if (self.running) { [self flip]; [self flip]; }
}

// ----- presets (saved in the game's own NSUserDefaults) -----
- (CGSize)viewSize {
    CGSize vs = self.view.bounds.size;
    if (vs.width < 100) vs = [UIScreen mainScreen].bounds.size;
    return vs;
}

- (void)toast:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = [NSString stringWithFormat:@"  %@  ", text];
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont boldSystemFontOfSize:14];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    l.layer.cornerRadius = 15;
    l.clipsToBounds = YES;
    l.textAlignment = NSTextAlignmentCenter;
    [l sizeToFit];
    l.frame = CGRectMake(0, 0, l.frame.size.width + 10, 30);
    l.center = CGPointMake([self viewSize].width / 2, 70);
    [self.view addSubview:l];
    [UIView animateWithDuration:0.4 delay:1.6 options:0 animations:^{ l.alpha = 0; }
                     completion:^(BOOL done) { [l removeFromSuperview]; }];
}

- (NSDictionary *)currentPreset {
    CGSize vs = [self viewSize];
    NSMutableArray *pts = [NSMutableArray array];
    for (UILabel *t in self.targets)   // stored as screen fractions so they survive rotation / other devices
        [pts addObject:@[@(t.center.x / vs.width), @(t.center.y / vs.height)]];
    return @{ @"targets": pts,
              @"interval": @(self.interval),
              @"burst": @(self.burst),
              @"jitter": @(self.jitter),
              @"gap": @(self.gap),
              @"burstGap": @(self.burstGap),
              @"simultaneous": @(self.simultaneous) };
}

- (BOOL)applyPreset:(NSDictionary *)p {
    NSArray *pts = p[@"targets"];
    if (![pts isKindOfClass:[NSArray class]] || pts.count == 0) return NO;
    NSUInteger n = MIN((NSUInteger)10, pts.count);
    while (self.targets.count > n) [self removeTarget];
    while (self.targets.count < n) [self addTarget];

    CGSize vs = [self viewSize];
    for (NSUInteger i = 0; i < n; i++) {
        NSArray *xy = pts[i];
        if (![xy isKindOfClass:[NSArray class]] || xy.count < 2) continue;
        UILabel *t = self.targets[i];
        CGFloat hw = t.bounds.size.width / 2, hh = t.bounds.size.height / 2;
        CGFloat x = MAX(hw, MIN(vs.width - hw, [xy[0] doubleValue] * vs.width));
        CGFloat y = MAX(hh, MIN(vs.height - hh, [xy[1] doubleValue] * vs.height));
        t.center = CGPointMake(x, y);
    }
    double iv = [p[@"interval"] doubleValue];
    if (iv > 0) self.interval = MIN(10.0, MAX(0.02, iv));
    self.burst = MIN(10, MAX(1, [p[@"burst"] integerValue]));
    self.jitter = MAX(0, [p[@"jitter"] integerValue]);
    self.gap = MAX(0.0, [p[@"gap"] doubleValue]);
    double bg = [p[@"burstGap"] doubleValue];
    self.burstGap = bg > 0 ? MAX(0.01, bg) : 0.06;
    self.simultaneous = [p[@"simultaneous"] boolValue];
    [self restartIfRunning];
    [self refreshUI];
    return YES;
}

- (NSDictionary *)allPresets {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kPresetsKey];
    return d ?: @{};
}

- (NSArray<NSString *> *)presetNames {
    return [[self allPresets].allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

// Presents an alert on the next run-loop turn so it works when called from another alert's handler.
- (void)present:(UIAlertController *)a {
    dispatch_async(dispatch_get_main_queue(), ^{ [self presentViewController:a animated:YES completion:nil]; });
}

- (void)openPresets {
    NSArray *names = [self presetNames];
    NSString *autoName = [[NSUserDefaults standardUserDefaults] stringForKey:kAutoLoadKey];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Presets"
        message:(names.count ? @"Tap a preset to load it. ★ = loads automatically when the game opens."
                             : @"No presets saved yet. Set up your targets and speed, then save.")
        preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *name in names) {
        NSString *title = [name isEqualToString:autoName] ? [name stringByAppendingString:@" ★"] : name;
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSDictionary *p = [self allPresets][name];
            if ([p isKindOfClass:[NSDictionary class]] && [self applyPreset:p])
                [self toast:[NSString stringWithFormat:@"Loaded preset: %@", name]];
            else
                [self toast:@"Could not load preset"];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Save current as…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self promptSave];
    }]];
    if (names.count) {
        [a addAction:[UIAlertAction actionWithTitle:@"Auto-load on launch…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self promptAutoLoad];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Delete a preset…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [self promptDelete];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}

- (void)promptSave {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save preset"
        message:@"Saves target positions, speed, clicks per tap, mode, jitter and delays. Using an existing name overwrites it."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"preset name";
        tf.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *name = [a.textFields[0].text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length) name = [NSString stringWithFormat:@"Preset %lu", (unsigned long)([self allPresets].count + 1)];
        NSMutableDictionary *all = [[self allPresets] mutableCopy];
        all[name] = [self currentPreset];
        [[NSUserDefaults standardUserDefaults] setObject:all forKey:kPresetsKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [self toast:[NSString stringWithFormat:@"Saved preset: %@", name]];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}

- (void)promptDelete {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Delete which preset?" message:nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *name in [self presetNames]) {
        [a addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            NSMutableDictionary *all = [[self allPresets] mutableCopy];
            [all removeObjectForKey:name];
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            [ud setObject:all forKey:kPresetsKey];
            if ([[ud stringForKey:kAutoLoadKey] isEqualToString:name]) [ud removeObjectForKey:kAutoLoadKey];
            [ud synchronize];
            [self toast:[NSString stringWithFormat:@"Deleted preset: %@", name]];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}

- (void)promptAutoLoad {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Auto-load on launch"
        message:@"This preset is applied automatically a moment after the game opens."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Off" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAutoLoadKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [self toast:@"Auto-load: off"];
    }]];
    for (NSString *name in [self presetNames]) {
        [a addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [[NSUserDefaults standardUserDefaults] setObject:name forKey:kAutoLoadKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self toast:[NSString stringWithFormat:@"Auto-load: %@", name]];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a];
}

- (void)openMore {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"More settings"
                                                               message:@"Exact values (the panel buttons use presets)"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"clicks per second (0.1 - 50)"; tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.3g", 1.0 / self.interval];
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"jitter (px)"; tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%ld", (long)self.jitter];
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"delay between targets, sequential (s)"; tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.3f", self.gap];
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"delay between multi-clicks (s)"; tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.3f", self.burstGap];
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        double cps = a.textFields[0].text.doubleValue;
        if (cps > 0) self.interval = 1.0 / MIN(50.0, MAX(0.1, cps));
        self.jitter = MAX(0, a.textFields[1].text.integerValue);
        self.gap = MAX(0.0, a.textFields[2].text.doubleValue);
        self.burstGap = MAX(0.01, a.textFields[3].text.doubleValue);
        [self restartIfRunning];
        [self refreshUI];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

static void ReportError(NSString *err) {
    dispatch_async(dispatch_get_main_queue(), ^{ [gCtl failWith:err]; });
}

static ACWindow *gWin;

static void ShowOverlay(void) {
    if (gWin) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive)
            { scene = (UIWindowScene *)s; break; }
    if (!scene) return;
    gWin = [[ACWindow alloc] initWithWindowScene:scene];
    gWin.frame = scene.coordinateSpace.bounds;
    gWin.windowLevel = UIWindowLevelAlert + 100;
    gWin.backgroundColor = UIColor.clearColor;
    gWin.rootViewController = [ACController new];
    gWin.hidden = NO;
}

__attribute__((constructor)) static void ACInit(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    pCreateDigitizer = (CreateDigitizer_t)dlsym(h ?: RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
    pCreateFinger    = (CreateFinger_t)dlsym(h ?: RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
    pAppend          = (AppendEvent_t)dlsym(h ?: RTLD_DEFAULT, "IOHIDEventAppendEvent");
    pSetSender       = (SetSenderID_t)dlsym(h ?: RTLD_DEFAULT, "IOHIDEventSetSenderID");

    // Retry until a foreground scene exists (dylibs load before UI is up).
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            ShowOverlay();
            if (gWin) [t invalidate];
        }];
    });
}
