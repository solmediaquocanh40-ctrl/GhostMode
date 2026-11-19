// Danh sách toàn bộ app đã cài để tick chọn app bị ẩn trong Chế độ khách.
// Dữ liệu lưu ở pref "guestApps" (mảng bundle ID) trong domain
// com.vn.ghostmodehome — tweak đọc cùng khoá đó. Mọi truy cập API riêng
// (LSApplicationWorkspace, icon app) đều đi qua objc_msgSend + kiểm tra
// respondsToSelector, không dùng performSelector.
#import "GMRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const GM_DOMAIN = @"com.vn.ghostmodehome";
static NSString *const GM_PREFS_NOTIFICATION = @"com.vn.ghostmodehome/prefsChanged";

static id GMMsg(id obj, SEL sel) {
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static NSMutableArray<NSString *> *GMReadGuestApps(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("guestApps"),
                                                    (__bridge CFStringRef)GM_DOMAIN);
    NSArray *arr = (__bridge_transfer NSArray *)v;
    return [arr isKindOfClass:[NSArray class]] ? [arr mutableCopy] : [NSMutableArray array];
}

static void GMWriteGuestApps(NSArray<NSString *> *apps) {
    CFPreferencesSetAppValue(CFSTR("guestApps"), (__bridge CFPropertyListRef)apps,
                             (__bridge CFStringRef)GM_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)GM_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)GM_PREFS_NOTIFICATION,
                                         NULL, NULL, true);
}

@implementation GMAppListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"CHỌN APP BỊ ẨN KHI BẬT CHẾ ĐỘ KHÁCH"];
        [group setProperty:@"App được bật ở đây sẽ biến mất khỏi màn hình chính (cả trong thư mục và Dock) chừng nào Chế độ khách còn bật — kể cả sau khi khoá máy hay respring. Tắt Chế độ khách hoặc bỏ chọn là app hiện lại."
                    forKey:@"footerText"];
        [specs addObject:group];

        // Lấy danh sách app qua LSApplicationWorkspace (runtime, an toàn)
        NSMutableArray *apps = [NSMutableArray array];
        @try {
            Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
            if (wsClass && [wsClass respondsToSelector:@selector(defaultWorkspace)]) {
                id ws = GMMsg(wsClass, @selector(defaultWorkspace));
                NSArray *proxies = [ws respondsToSelector:@selector(allInstalledApplications)]
                    ? GMMsg(ws, @selector(allInstalledApplications)) : nil;
                for (id proxy in proxies ?: @[]) {
                    NSString *bid = [proxy respondsToSelector:@selector(applicationIdentifier)]
                        ? GMMsg(proxy, @selector(applicationIdentifier)) : nil;
                    NSString *name = [proxy respondsToSelector:@selector(localizedName)]
                        ? GMMsg(proxy, @selector(localizedName)) : nil;
                    if (bid.length && name.length)
                        [apps addObject:@{ @"id": bid, @"name": name }];
                }
            }
        } @catch (__unused NSException *e) {}

        [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];

        CGFloat scale = [UIScreen mainScreen].scale;
        SEL iconSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        BOOL hasIconAPI = [UIImage respondsToSelector:iconSel];

        for (NSDictionary *app in apps) {
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:app[@"name"]
                                                             target:self
                                                                set:@selector(setGuestApp:forSpecifier:)
                                                                get:@selector(guestAppForSpecifier:)
                                                             detail:nil
                                                               cell:PSSwitchCell
                                                               edit:nil];
            [s setProperty:app[@"id"] forKey:@"bundleID"];
            if (hasIconAPI) {
                @try {
                    UIImage *icon = ((UIImage *(*)(id, SEL, id, NSInteger, CGFloat))objc_msgSend)(
                        [UIImage class], iconSel, app[@"id"], (NSInteger)0, scale);
                    if (icon) [s setProperty:icon forKey:@"iconImage"];
                } @catch (__unused NSException *e) {}
            }
            [specs addObject:s];
        }

        if (apps.count == 0) {
            PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"Không đọc được danh sách app"
                                                                target:nil set:nil get:nil
                                                                detail:nil cell:PSStaticTextCell edit:nil];
            [specs addObject:empty];
        }

        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (id)guestAppForSpecifier:(PSSpecifier *)specifier {
    NSString *bid = [specifier propertyForKey:@"bundleID"];
    return @([GMReadGuestApps() containsObject:bid]);
}

- (void)setGuestApp:(id)value forSpecifier:(PSSpecifier *)specifier {
    NSString *bid = [specifier propertyForKey:@"bundleID"];
    if (!bid) return;
    NSMutableArray<NSString *> *apps = GMReadGuestApps();
    if ([value boolValue]) { if (![apps containsObject:bid]) [apps addObject:bid]; }
    else { [apps removeObject:bid]; }
    GMWriteGuestApps(apps);
}

@end
