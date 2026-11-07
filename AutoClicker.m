// AutoClicker.m - in-process multi-target auto tapper for sideloaded (jailed) apps.
// Inject as a dylib (iGameGod / Sideloadly / ESign / TrollStore etc). No jailbreak needed.
//
// UI:  floating "AC" button  -> tap = start/stop, long-press = settings
//      red numbered crosshairs -> drag each one onto its target
// Settings (long-press AC): interval, jitter, gap between sequential taps,
//      Add target, Remove target, Mode (Sequential <-> Simultaneous).
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

// Sends one UIEvent carrying N touches (N == 1 is a plain tap, N > 1 is true multi-touch).
static void SendTouches(UIWindow *win, NSArray<NSValue *> *points, NSArray<UITouch *> *touches,
                        UITouchPhase phase) {
    UIApplication *app = [UIApplication sharedApplication];
    NSUInteger n = points.count;
    CGPoint pts[n];
    for (NSUInteger i = 0; i < n; i++) pts[i] = points[i].CGPointValue;
    BOOL down = (phase != UITouchPhaseEnded);

    UIEvent *ev = [app _touchesEvent];
    [ev _clearTouches];

    for (NSUInteger i = 0; i < n; i++) {
        UITouch *t = touches[i];
        UIView *view = [win hitTest:pts[i] withEvent:nil] ?: win;
        [t setWindow:win];
        [t setView:view];
        [t setTapCount:1];
        [t setPhase:phase];
        [t setTimestamp:[[NSProcessInfo processInfo] systemUptime]];
        [t _setLocationInWindow:pts[i] resetPrevLocation:(phase == UITouchPhaseBegan)];
        if (phase == UITouchPhaseBegan) [t _setIsFirstTouchForView:YES];

        // Each touch gets its own single-finger HID event.
        IOHIDEventRef one = MakeHID(&pts[i], 1, down);
        if (one && [t respondsToSelector:@selector(_setHidEvent:)]) [t _setHidEvent:one];
        if (one) CFRelease(one);

        [ev _addTouch:t forDelayedDelivery:NO];
    }

    // The event itself carries the combined multi-finger HID event.
    IOHIDEventRef all = MakeHID(pts, n, down);
    if (all && [ev respondsToSelector:@selector(_setHIDEvent:)]) [ev _setHIDEvent:all];
    [app sendEvent:ev];
    if (all) CFRelease(all);
}

// Tap = began, then ended 30ms later, for the given set of points (1 or many at once).
static void TapPoints(NSArray<NSValue *> *points) {
    UIWindow *win = TargetWindow();
    if (!win || points.count == 0) return;
    NSMutableArray *touches = [NSMutableArray array];
    for (NSUInteger i = 0; i < points.count; i++) [touches addObject:[[UITouch alloc] init]];
    SendTouches(win, points, touches, UITouchPhaseBegan);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SendTouches(win, points, touches, UITouchPhaseEnded);
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

@interface ACController : UIViewController
@property (nonatomic, strong) UIButton *toggle;
@property (nonatomic, strong) NSMutableArray<UILabel *> *targets;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) NSTimeInterval interval;
@property (nonatomic) NSTimeInterval gap;      // delay between taps in sequential mode
@property (nonatomic) NSInteger jitter;        // px
@property (nonatomic) BOOL simultaneous;
@property (nonatomic) BOOL running;
@end

@implementation ACController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.interval = 0.1;
    self.gap = 0.01;
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
    [self.toggle addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(settings:)]];
    [self.view addSubview:self.toggle];
}

- (void)addTarget {
    UILabel *c = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 56, 44)];
    c.font = [UIFont boldSystemFontOfSize:26];
    c.textAlignment = NSTextAlignmentCenter;
    c.textColor = UIColor.redColor;
    c.userInteractionEnabled = YES;
    CGFloat off = self.targets.count * 40;
    c.center = CGPointMake(self.view.bounds.size.width / 2 + off, self.view.bounds.size.height / 2 + off);
    [c addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    [self.view addSubview:c];
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
    g.view.center = CGPointMake(g.view.center.x + d.x, g.view.center.y + d.y);
    [g setTranslation:CGPointZero inView:self.view];
}

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

- (void)fire {
    NSMutableArray<NSValue *> *pts = [NSMutableArray array];
    for (UILabel *t in self.targets)
        [pts addObject:[NSValue valueWithCGPoint:[self jittered:t.center]]];

    if (self.simultaneous) {
        TapPoints(pts); // all fingers in one event
    } else {
        for (NSUInteger i = 0; i < pts.count; i++) {
            NSValue *p = pts[i];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * self.gap * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ TapPoints(@[p]); });
        }
    }
}

- (void)restartIfRunning {
    if (self.running) { [self flip]; [self flip]; }
}

- (void)settings:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSString *msg = [NSString stringWithFormat:@"%lu target(s), mode: %@",
                     (unsigned long)self.targets.count,
                     self.simultaneous ? @"Simultaneous" : @"Sequential"];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Auto Clicker"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"interval (s)"; tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.3f", self.interval];
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"jitter (px)"; tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%ld", (long)self.jitter];
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"gap between sequential taps (s)"; tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.3f", self.gap];
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        self.interval = MAX(0.02, a.textFields[0].text.doubleValue);
        self.jitter = MAX(0, a.textFields[1].text.integerValue);
        self.gap = MAX(0.0, a.textFields[2].text.doubleValue);
        [self restartIfRunning];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Add target" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        if (self.targets.count < 10) [self addTarget];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Remove last target" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self removeTarget];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:(self.simultaneous ? @"Switch to Sequential" : @"Switch to Simultaneous")
                                          style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        self.simultaneous = !self.simultaneous;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

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
