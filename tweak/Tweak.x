// GhostModeHome 1.1.2 — chạm theo cử chỉ TUỲ CHỈNH để ẩn/hiện toàn bộ icon
// màn hình chính, khoe trọn hình nền; chạm lại để hiện về.
// Mặc định: chạm 3 lần vào vùng trống (KHÔNG đụng DoubleTapToLock của anh).
// Mọi chuyển động dùng vật lý lò xo + trễ lan sóng theo khoảng cách từ điểm
// chạm để đạt độ mượt tối đa. Phong cách quen thuộc: dò class/phương thức
// lúc chạy, có đường lui an toàn, có log gỡ lỗi riêng.
// Target: SpringBoard, iOS 15/16 (máy test: iPhone 12 Pro, iOS 16.3.1).

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

static NSString *const GM_DOMAIN = @"com.vn.ghostmodehome";
static NSString *const GM_PREFS_NOTIFICATION = @"com.vn.ghostmodehome/prefsChanged";
static NSString *const GM_LOG_PATH = @"/var/mobile/Documents/GhostModeHome.log";

// ---------------------------------------------------------------- tuỳ chọn
static BOOL    pEnabled                 = YES;
static BOOL    pGestTripleTap           = YES;   // mặc định BẬT
static BOOL    pGestTwoFingerDoubleTap  = NO;
static BOOL    pGestPinch               = NO;
static BOOL    pGestTwoFingerSwipeDown  = NO;
static BOOL    pGestShake               = NO;
static BOOL    pGestStatusBarDoubleTap  = NO;
static BOOL    pHideDock                = YES;
static BOOL    pHidePageDots            = YES;
static BOOL    pHideSearchPill          = YES;
static BOOL    pAutoRestoreOnUnlock     = YES;
static BOOL    pStagger                 = YES;
static CGFloat pAnimDuration            = 0.45;
static CGFloat pAnimScale               = 0.85;
static BOOL    pDebug                   = NO;
// Chế độ khách: pref guestEnabled là công tắc VŨ TRANG danh sách app
// (guestApps). Khi đã vũ trang, cử chỉ (chạm 3 lần...) chỉ ẩn/hiện RIÊNG
// các app trong danh sách, icon khác giữ nguyên — kiểu B anh chốt. Trạng
// thái đang ẩn nằm ở gGuestHidden, lưu bền vào pref guestActive để qua
// khoá máy/respring vẫn giữ nguyên cho tới khi anh chạm lại hoặc tắt khách.
static BOOL    pGuestEnabled            = NO;
static NSSet<NSString *> *pGuestAppSet  = nil;

// ---------------------------------------------------------------- trạng thái
static BOOL gHidden      = NO; // Ghost: đang ẩn TOÀN BỘ icon
static BOOL gGuestHidden = NO; // Khách: đang ẩn RIÊNG các app trong danh sách
static BOOL gAnimating   = NO;

// ---------------------------------------------------------------- log
static void GMLog(NSString *fmt, ...) {
    if (!pDebug) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[GhostModeHome] %@", msg);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:GM_LOG_PATH];
        if (h) { @try { [h seekToEndOfFile]; [h writeData:data]; [h closeFile]; } @catch (__unused NSException *e) {} }
        else { [data writeToFile:GM_LOG_PATH atomically:YES]; }
    });
}

// ---------------------------------------------------------------- prefs
static id GMGetPref(NSString *key, id def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)GM_DOMAIN);
    if (v) return (__bridge_transfer id)v;
    return def;
}

static void GMLoadPrefs(void) {
    pEnabled                = [GMGetPref(@"enabled",                @YES) boolValue];
    pGestTripleTap          = [GMGetPref(@"gestureTripleTap",       @YES) boolValue];
    pGestTwoFingerDoubleTap = [GMGetPref(@"gestureTwoFingerDoubleTap", @NO) boolValue];
    pGestPinch              = [GMGetPref(@"gesturePinch",           @NO) boolValue];
    pGestTwoFingerSwipeDown = [GMGetPref(@"gestureTwoFingerSwipeDown", @NO) boolValue];
    pGestShake              = [GMGetPref(@"gestureShake",           @NO) boolValue];
    pGestStatusBarDoubleTap = [GMGetPref(@"gestureStatusBarDoubleTap", @NO) boolValue];
    pHideDock               = [GMGetPref(@"hideDock",               @YES) boolValue];
    pHidePageDots            = [GMGetPref(@"hidePageDots",           @YES) boolValue];
    pHideSearchPill         = [GMGetPref(@"hideSearchPill",         @YES) boolValue];
    pAutoRestoreOnUnlock    = [GMGetPref(@"autoRestoreOnUnlock",    @YES) boolValue];
    pStagger                = [GMGetPref(@"stagger",                @YES) boolValue];
    pAnimDuration           = MIN(0.90, MAX(0.15, [GMGetPref(@"animDuration", @(0.45)) doubleValue]));
    pAnimScale              = MIN(1.00, MAX(0.50, [GMGetPref(@"animScale",    @(0.85)) doubleValue]));
    pDebug                  = [GMGetPref(@"debug",                  @NO) boolValue];
    pGuestEnabled           = [GMGetPref(@"guestEnabled",           @NO) boolValue];
    id guestApps            = GMGetPref(@"guestApps", nil);
    pGuestAppSet            = [guestApps isKindOfClass:[NSArray class]]
                                ? [NSSet setWithArray:guestApps] : [NSSet set];
    // Trạng thái khách đang ẩn chỉ sống khi còn vũ trang; tắt vũ trang là xả.
    gGuestHidden            = pGuestEnabled && [GMGetPref(@"guestActive", @NO) boolValue];
}

// Lưu bền trạng thái khách đang ẩn (để qua respring vẫn giữ). Không post
// thông báo prefsChanged: chính tweak là nơi duy nhất ghi khoá này, và nó
// đã tự cập nhật gGuestHidden ngay lúc ghi.
static void GMSaveGuestActive(BOOL on) {
    CFPreferencesSetAppValue(CFSTR("guestActive"),
                             on ? kCFBooleanTrue : kCFBooleanFalse,
                             (__bridge CFStringRef)GM_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)GM_DOMAIN);
}

// ---------------------------------------------------------------- helpers
static BOOL GMIsClass(UIView *v, NSString *name) {
    Class c = NSClassFromString(name);
    return c && [v isKindOfClass:c];
}

static BOOL GMIsIconView(UIView *v) {
    if (GMIsClass(v, @"SBIconView")) return YES;
    NSString *cn = NSStringFromClass([v class]);
    return [cn hasPrefix:@"SB"] && [cn hasSuffix:@"IconView"];
}

static BOOL GMHasAncestorClass(UIView *v, NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) return NO;
    UIView *p = v.superview;
    while (p) { if ([p isKindOfClass:c]) return YES; p = p.superview; }
    return NO;
}

static BOOL GMIsLocked(void) {
    Class c = NSClassFromString(@"SBLockScreenManager");
    if (!c) return NO;
    id mgr = nil;
    @try { mgr = ((id (*)(id, SEL))objc_msgSend)(c, @selector(sharedInstance)); } @catch (__unused NSException *e) {}
    if (mgr && [mgr respondsToSelector:@selector(isUILocked)])
        return ((BOOL (*)(id, SEL))objc_msgSend)(mgr, @selector(isUILocked));
    return NO;
}

static BOOL GMIsEditing(void) {
    Class c = NSClassFromString(@"SBIconController");
    if (!c) return NO;
    id ic = nil;
    @try { ic = ((id (*)(id, SEL))objc_msgSend)(c, @selector(sharedInstance)); } @catch (__unused NSException *e) {}
    if (ic && [ic respondsToSelector:@selector(isEditing)])
        return ((BOOL (*)(id, SEL))objc_msgSend)(ic, @selector(isEditing));
    return NO;
}

static CGPoint GMDefaultOrigin(void) {
    CGRect b = [UIScreen mainScreen].bounds;
    return CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
}

static CGAffineTransform GMHiddenTransform(void) {
    CGAffineTransform t = CGAffineTransformMakeTranslation(0, 10);
    return CGAffineTransformScale(t, pAnimScale, pAnimScale);
}

static NSArray<UIWindow *> *GMAllWindows(void) {
    NSMutableArray *wins = [NSMutableArray array];
    @try {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]])
                [wins addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    } @catch (__unused NSException *e) {}
    if (wins.count == 0) {
        // Tránh property "windows" (deprecated, SDK mới biên dịch thành lỗi
        // với -Werror) — lấy qua KVC cho an toàn.
        @try {
            NSArray *w = [[UIApplication sharedApplication] valueForKey:@"windows"];
            if (w) [wins addObjectsFromArray:w];
        } @catch (__unused NSException *e) {}
    }
    return wins;
}

static void GMWalk(UIView *root, void (^visit)(UIView *)) {
    if (!root) return;
    visit(root);
    for (UIView *s in [root.subviews copy]) GMWalk(s, visit);
}

// Thu thập: icons = từng SBIconView (trừ icon trong dock — dock xử lý cả cụm);
// extras = dock / chấm trang / nút tìm kiếm (mờ cả khối, không lan sóng).
static void GMCollect(NSMutableArray<UIView *> *icons, NSMutableArray<UIView *> *extras) {
    for (UIWindow *w in GMAllWindows()) {
        GMWalk(w, ^(UIView *v) {
            if (GMIsIconView(v)) {
                if (!GMHasAncestorClass(v, @"SBDockView")) [icons addObject:v];
                return;
            }
            if (pHideDock && GMIsClass(v, @"SBDockView")) { [extras addObject:v]; return; }
            if (pHidePageDots && (GMIsClass(v, @"SBHPageDotsView") || GMIsClass(v, @"SBPageControl"))) { [extras addObject:v]; return; }
            if (pHideSearchPill && GMIsClass(v, @"SBHSearchPillView")) { [extras addObject:v]; return; }
        });
    }
}

// Bundle ID của một icon view — dò qua model SBIcon bằng các selector quen
// thuộc, có đường lui an toàn. Trả nil cho thư mục/widget lạ thì KHÔNG ẩn.
static NSString *GMIconBundleID(UIView *iconView) {
    @try {
        id icon = [iconView valueForKey:@"icon"];
        if (!icon) return nil;
        for (NSString *selName in @[@"applicationBundleID", @"bundleIdentifier", @"nodeIdentifier"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([icon respondsToSelector:sel]) {
                id v = ((id (*)(id, SEL))objc_msgSend)(icon, sel);
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

// Icon này có nằm trong danh sách khách không (chưa tính trạng thái ẩn).
static BOOL GMIconInGuestList(UIView *iconView) {
    if (pGuestAppSet.count == 0) return NO;
    NSString *bid = GMIconBundleID(iconView);
    return bid && [pGuestAppSet containsObject:bid];
}

// Chế độ khách có đang giấu RIÊNG icon này không (không tính trạng thái
// Ghost): phải đồng thời còn vũ trang VÀ đang ở trạng thái khách-ẩn.
static BOOL GMGuestHidesIcon(UIView *iconView) {
    return gGuestHidden && pGuestEnabled && GMIconInGuestList(iconView);
}

// Một icon có phải ẩn hay không = đang Ghost (ẩn tất cả) HOẶC đang bị
// khách giấu riêng. Đây là nơi duy nhất quyết định, để hai chế độ không
// bao giờ đánh nhau.
static BOOL GMShouldHideIcon(UIView *iconView) {
    if (gHidden) return YES;
    return GMGuestHidesIcon(iconView);
}

// Đánh dấu những icon đang bị ẩn BỞI Chế độ khách (khác với ẩn bởi Ghost),
// để khi tắt Chế độ khách / bỏ chọn app thì chỉ hiện lại đúng những icon
// mình đã ẩn, không đụng vào alpha mà SpringBoard tự quản lý vì việc khác.
static const void *kGMGuestHiddenKey = &kGMGuestHiddenKey;
static BOOL GMIsGuestHidden(UIView *v) {
    return [objc_getAssociatedObject(v, kGMGuestHiddenKey) boolValue];
}
static void GMSetGuestHiddenMark(UIView *v, BOOL m) {
    objc_setAssociatedObject(v, kGMGuestHiddenKey, m ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Ép trạng thái khách lên MỘT icon ngay lập tức, không hiệu ứng: icon
// thuộc diện khách giấu thì phải mờ; icon mình từng giấu mà nay không
// còn thuộc diện giấu thì trả lại. Chỉ chạy khi Ghost không giữ màn
// hình (gHidden/gAnimating) để hai chế độ không bao giờ đánh nhau.
static void GMEnforceGuestOnIcon(UIView *icon) {
    if (gHidden || gAnimating) return;
    if (GMGuestHidesIcon(icon)) {
        if (icon.alpha != 0.0) {
            icon.alpha = 0.0;
            icon.transform = GMHiddenTransform();
        }
        GMSetGuestHiddenMark(icon, YES);
    } else if (GMIsGuestHidden(icon)) {
        icon.alpha = 1.0;
        icon.transform = CGAffineTransformIdentity;
        GMSetGuestHiddenMark(icon, NO);
    }
}

static NSArray<UIView *> *GMAllIconViews(void) {
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    for (UIWindow *w in GMAllWindows())
        GMWalk(w, ^(UIView *v) { if (GMIsIconView(v)) [out addObject:v]; });
    return out;
}

// ---------------------------------------------------------------- lõi hiệu ứng
// Mượt mà là ưu tiên số 1: lò xo (spring) cho mọi view, độ trễ lan sóng tính
// theo khoảng cách thật từ điểm chạm, BeginFromCurrentState để bấm đảo chiều
// giữa chừng không bao giờ bị giật/nhảy hình.
static void GMSetHidden(BOOL hidden, BOOL animated, CGPoint origin) {
    if (gHidden == hidden) return;
    NSMutableArray<UIView *> *icons  = [NSMutableArray array];
    NSMutableArray<UIView *> *extras = [NSMutableArray array];
    GMCollect(icons, extras);
    GMLog(@"SetHidden=%d icons=%lu extras=%lu animated=%d",
          hidden, (unsigned long)icons.count, (unsigned long)extras.count, animated);
    gHidden = hidden;

    NSTimeInterval dur = animated ? pAnimDuration : 0.0;
    gAnimating = animated;
    if (animated) {
        NSTimeInterval total = dur + 0.35;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(total * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ gAnimating = NO; });
    }

    CGAffineTransform tHidden = GMHiddenTransform();
    UIViewAnimationOptions opts = UIViewAnimationOptionAllowUserInteraction |
                                  UIViewAnimationOptionBeginFromCurrentState |
                                  UIViewAnimationOptionCurveEaseInOut;

    for (UIView *icon in icons) {
        CGFloat delay = 0;
        if (animated && pStagger) {
            CGPoint c = icon.center;
            if (icon.superview) c = [icon.superview convertPoint:icon.center toView:nil];
            delay = MIN(0.30, hypot(c.x - origin.x, c.y - origin.y) / 2400.0);
        }
        BOOL hide = GMShouldHideIcon(icon); // tôn trọng cả Chế độ khách khi hiện lại
        if (!hidden) GMSetGuestHiddenMark(icon, hide && GMGuestHidesIcon(icon));
        void (^anim)(void) = ^{
            icon.alpha = hide ? 0.0 : 1.0;
            icon.transform = hide ? tHidden : CGAffineTransformIdentity;
        };
        if (animated)
            [UIView animateWithDuration:dur delay:delay
                 usingSpringWithDamping:0.88 initialSpringVelocity:0.45
                                options:opts animations:anim completion:nil];
        else anim();
    }
    for (UIView *ex in extras) {
        void (^anim)(void) = ^{
            ex.alpha = hidden ? 0.0 : 1.0;
            ex.transform = hidden ? CGAffineTransformMakeScale(0.98, 0.98) : CGAffineTransformIdentity;
        };
        if (animated)
            [UIView animateWithDuration:dur delay:0.02
                 usingSpringWithDamping:0.90 initialSpringVelocity:0.40
                                options:opts animations:anim completion:nil];
        else anim();
    }
}

// Ẩn/hiện RIÊNG các app trong danh sách khách, cùng công thức mượt như
// Ghost (lò xo + lan sóng từ điểm chạm) nhưng không đụng icon ngoài danh
// sách, cũng không đụng cả cụm Dock/chấm trang/nút tìm kiếm. App trong
// danh sách mà nằm ở Dock hay trong thư mục vẫn ẩn theo từng icon.
static void GMSetGuestHidden(BOOL hidden, BOOL animated, CGPoint origin) {
    if (gGuestHidden == hidden) return;
    gGuestHidden = hidden;
    GMSaveGuestActive(hidden);
    GMLog(@"SetGuestHidden=%d", hidden);

    NSTimeInterval dur = animated ? pAnimDuration : 0.0;
    gAnimating = animated;
    if (animated) {
        NSTimeInterval total = dur + 0.35;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(total * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ gAnimating = NO; });
    }

    CGAffineTransform tHidden = GMHiddenTransform();
    UIViewAnimationOptions opts = UIViewAnimationOptionAllowUserInteraction |
                                  UIViewAnimationOptionBeginFromCurrentState |
                                  UIViewAnimationOptionCurveEaseInOut;
    for (UIView *icon in GMAllIconViews()) {
        if (!GMIconInGuestList(icon)) continue;
        CGFloat delay = 0;
        if (animated && pStagger) {
            CGPoint c = icon.center;
            if (icon.superview) c = [icon.superview convertPoint:icon.center toView:nil];
            delay = MIN(0.30, hypot(c.x - origin.x, c.y - origin.y) / 2400.0);
        }
        GMSetGuestHiddenMark(icon, hidden);
        void (^anim)(void) = ^{
            icon.alpha = hidden ? 0.0 : 1.0;
            icon.transform = hidden ? tHidden : CGAffineTransformIdentity;
        };
        if (animated)
            [UIView animateWithDuration:dur delay:delay
                 usingSpringWithDamping:0.88 initialSpringVelocity:0.45
                                options:opts animations:anim completion:nil];
        else anim();
    }
}

static void GMToggleAt(CGPoint origin) {
    if (!pEnabled || GMIsLocked()) return;
    // Đang vũ trang Chế độ khách: cử chỉ chỉ đảo trạng thái của RIÊNG các
    // app trong danh sách, icon khác giữ nguyên (kiểu B anh chốt). Muốn
    // ẩn toàn bộ thì tắt Chế độ khách trong Cài đặt.
    if (pGuestEnabled && pGuestAppSet.count > 0) {
        GMLog(@"Toggle Guest -> %d", !gGuestHidden);
        GMSetGuestHidden(!gGuestHidden, YES, origin);
        return;
    }
    GMLog(@"Toggle -> %d", !gHidden);
    GMSetHidden(!gHidden, YES, origin);
}

// Đồng bộ trạng thái khách lên mọi icon (kể cả icon trong Dock) theo
// gGuestHidden hiện tại: app thuộc diện giấu thì mờ đi, còn lại trả về.
// Gọi khi đổi pref (đổi danh sách lúc đang ẩn, tắt vũ trang...) và một
// lần lúc SpringBoard vừa lên (áp bền sau respring).
static void GMApplyGuestState(BOOL animated) {
    NSTimeInterval dur = animated ? 0.35 : 0.0;
    CGAffineTransform tHidden = GMHiddenTransform();
    UIViewAnimationOptions opts = UIViewAnimationOptionAllowUserInteraction |
                                  UIViewAnimationOptionBeginFromCurrentState;
    for (UIView *icon in GMAllIconViews()) {
        BOOL hide = GMShouldHideIcon(icon);
        if (!gHidden) GMSetGuestHiddenMark(icon, GMGuestHidesIcon(icon));
        CGFloat target = hide ? 0.0 : 1.0;
        if (icon.alpha == target) continue;
        void (^anim)(void) = ^{
            icon.alpha = target;
            icon.transform = hide ? tHidden : CGAffineTransformIdentity;
        };
        if (animated)
            [UIView animateWithDuration:dur delay:0
                 usingSpringWithDamping:0.90 initialSpringVelocity:0.40
                                options:opts animations:anim completion:nil];
        else anim();
    }
    GMLog(@"ApplyGuestState enabled=%d soApp=%lu", pGuestEnabled, (unsigned long)pGuestAppSet.count);
}

// ---------------------------------------------------------------- cử chỉ
@interface GMGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)attachToRootView:(UIView *)root;
- (void)attachToStatusBarIfPossible;
- (void)refreshEnabledStates;
- (void)handleShake;
@end

@implementation GMGestureHandler {
    NSMutableDictionary<NSString *, UIGestureRecognizer *> *_recs;
    __weak UIView *_rootView;
    BOOL _statusBarAttached;
}

+ (instancetype)shared {
    static GMGestureHandler *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [GMGestureHandler new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) _recs = [NSMutableDictionary dictionary];
    return self;
}

- (void)attachToRootView:(UIView *)root {
    if (_rootView == root && _recs.count > 0) { [self refreshEnabledStates]; return; }
    _rootView = root;

    UITapGestureRecognizer *triple = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
    triple.numberOfTapsRequired = 3;
    triple.delegate = self;
    triple.cancelsTouchesInView = NO;
    [root addGestureRecognizer:triple];
    _recs[@"tripleTap"] = triple;

    UITapGestureRecognizer *twoFingerDouble = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
    twoFingerDouble.numberOfTapsRequired = 2;
    twoFingerDouble.numberOfTouchesRequired = 2;
    twoFingerDouble.delegate = self;
    twoFingerDouble.cancelsTouchesInView = NO;
    [root addGestureRecognizer:twoFingerDouble];
    _recs[@"twoFingerDoubleTap"] = twoFingerDouble;

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
    pinch.delegate = self;
    pinch.cancelsTouchesInView = NO;
    [root addGestureRecognizer:pinch];
    _recs[@"pinch"] = pinch;

    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(onSwipe:)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    swipe.numberOfTouchesRequired = 2;
    swipe.delegate = self;
    swipe.cancelsTouchesInView = NO;
    [root addGestureRecognizer:swipe];
    _recs[@"twoFingerSwipeDown"] = swipe;

    [self refreshEnabledStates];
    [self attachToStatusBarIfPossible];
    GMLog(@"Da gan cu chi vao root view %@", root);
}

- (void)attachToStatusBarIfPossible {
    if (_statusBarAttached) return;
    for (UIWindow *w in GMAllWindows()) {
        NSString *cn = NSStringFromClass([w class]);
        if ([cn rangeOfString:@"StatusBar"].location != NSNotFound) {
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
            tap.numberOfTapsRequired = 2;
            tap.delegate = self;
            tap.cancelsTouchesInView = NO;
            [w addGestureRecognizer:tap];
            _recs[@"statusBarDoubleTap"] = tap;
            _statusBarAttached = YES;
            [self refreshEnabledStates];
            GMLog(@"Da gan cu chi vao status bar window %@", cn);
            return;
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self attachToStatusBarIfPossible]; });
}

- (void)refreshEnabledStates {
    _recs[@"tripleTap"].enabled          = pEnabled && pGestTripleTap;
    _recs[@"twoFingerDoubleTap"].enabled = pEnabled && pGestTwoFingerDoubleTap;
    _recs[@"pinch"].enabled              = pEnabled && pGestPinch;
    _recs[@"twoFingerSwipeDown"].enabled = pEnabled && pGestTwoFingerSwipeDown;
    _recs[@"statusBarDoubleTap"].enabled = pEnabled && pGestStatusBarDoubleTap;
}

// Chỉ nhận chạm ở VÙNG TRỐNG: chạm trúng icon/dock thì nhường cho hệ thống
// (mở app, mở thư mục...) — đây là điều kiện sống còn để không phá thao tác gốc.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    if (!pEnabled || GMIsEditing() || GMIsLocked()) return NO;
    UIView *v = touch.view;
    while (v) {
        if (GMIsIconView(v)) return NO;
        v = v.superview;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES; // không bao giờ chặn cử chỉ của hệ thống / tweak khác (kể cả DoubleTapToLock)
}

- (void)onTap:(UITapGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded)
        GMToggleAt([g locationInView:nil]);
}

- (void)onSwipe:(UISwipeGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded)
        GMToggleAt(GMDefaultOrigin());
}

- (void)onPinch:(UIPinchGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    if (!pEnabled || GMIsLocked() || GMIsEditing()) return;
    BOOL guestArmed = pGuestEnabled && pGuestAppSet.count > 0;
    if (g.scale < 0.85) {
        if (guestArmed) { if (!gGuestHidden) GMSetGuestHidden(YES, YES, GMDefaultOrigin()); }
        else if (!gHidden) GMSetHidden(YES, YES, GMDefaultOrigin());
    } else if (g.scale > 1.15) {
        if (guestArmed) { if (gGuestHidden) GMSetGuestHidden(NO, YES, GMDefaultOrigin()); }
        else if (gHidden) GMSetHidden(NO, YES, GMDefaultOrigin());
    }
}

- (void)handleShake {
    if (pEnabled && pGestShake && !GMIsLocked() && !GMIsEditing())
        GMToggleAt(GMDefaultOrigin());
}
@end

// ---------------------------------------------------------------- callbacks
static void GMPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        GMLoadPrefs();
        [[GMGestureHandler shared] refreshEnabledStates];
        if (!pEnabled && gHidden) GMSetHidden(NO, YES, GMDefaultOrigin());
        if (!pGuestEnabled || !pEnabled) {
            // Xả vũ trang (hoặc tắt cả tweak): xoá trạng thái ẩn bền của
            // khách, GMApplyGuestState ngay dưới sẽ hiện các app lại. Khi
            // còn vũ trang, hàm này KHÔNG tự ẩn app — ẩn là việc của cử chỉ.
            gGuestHidden = NO;
            GMSaveGuestActive(NO);
        }
        GMApplyGuestState(YES);
        GMLog(@"Prefs reloaded. enabled=%d guest=%d", pEnabled, pGuestEnabled);
    });
}

static void GMLockStateChanged(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (pAutoRestoreOnUnlock && gHidden && !GMIsLocked()) {
            GMLog(@"Mo khoa -> tu hien lai icon");
            GMSetHidden(NO, YES, GMDefaultOrigin());
        }
        // Mở khoá xong, ép lại trạng thái khách một lượt (icon vừa được
        // SpringBoard trình bày lại sau màn hình khoá). Lưu ý: mở khoá
        // KHÔNG tự hiện app khách — trạng thái ẩn giữ nguyên cho người mượn.
        if (gGuestHidden && !gHidden && !GMIsLocked()) GMApplyGuestState(NO);
    });
}

// ---------------------------------------------------------------- hooks
%hook SBRootFolderView
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) {
        [[GMGestureHandler shared] attachToRootView:(UIView *)self];
        if (!gHidden) GMApplyGuestState(NO); // áp Chế độ khách ngay khi SpringBoard lên (bền sau respring), không hiệu ứng
    }
}
%end

// Icon mới xuất hiện (chuyển trang, cài app...) trong lúc đang ẩn: áp trạng
// thái ẩn NGAY, không hiệu ứng, để không bao giờ lộ icon — cho cả hai chế độ.
%hook SBIconListView
- (void)layoutSubviews {
    %orig;
    if (!gAnimating) {
        BOOL inDock = GMHasAncestorClass((UIView *)self, @"SBDockView");
        for (UIView *sub in ((UIView *)self).subviews) {
            if (!GMIsIconView(sub)) continue;
            if (gHidden) {
                BOOL hide = GMShouldHideIcon(sub);
                if (inDock && !pHideDock) hide = NO; // Ghost mà không ẩn Dock thì chừa icon Dock
                if (hide && sub.alpha != 0.0) {
                    sub.alpha = 0.0;
                    sub.transform = GMHiddenTransform();
                }
            } else {
                // Ghost đang tắt: ép trạng thái khách hiện tại (đã bật/tắt
                // bằng cử chỉ) ngay trong layout, hai chiều ẩn/hiện, để icon
                // mới trình bày lại không bao giờ lộ app thuộc diện giấu.
                GMEnforceGuestOnIcon(sub);
            }
        }
    }
}
%end

// Mỗi lần SpringBoard trình bày lại từng icon (về màn hình chính, mở khoá,
// chuyển trang...) ép lại quyết định của Chế độ khách lên chính icon đó.
%hook SBIconView
- (void)layoutSubviews {
    %orig;
    if (!gAnimating && !gHidden) GMEnforceGuestOnIcon((UIView *)self);
}
%end

// Vào chế độ sửa màn hình (jiggle) mà icon đang ẩn thì hiện lại ngay cho an toàn.
%hook SBIconController
- (void)setIsEditing:(BOOL)editing {
    if (editing && gHidden) GMSetHidden(NO, YES, GMDefaultOrigin());
    %orig;
}
%end

%hook UIWindow
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    %orig;
    if (motion == UIEventSubtypeMotionShake) [[GMGestureHandler shared] handleShake];
}
%end

// ---------------------------------------------------------------- ctor
%ctor {
    @autoreleasepool {
        GMLoadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            GMPrefsChanged, (__bridge CFStringRef)GM_PREFS_NOTIFICATION, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            GMLockStateChanged, CFSTR("com.apple.springboard.lockstate"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        %init;
        GMLog(@"GhostModeHome 1.1.2 loaded. enabled=%d", pEnabled);
    }
}
