//
//  main.m
//  Toneferry iOS
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "TFViewController.h"

@interface TFAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation TFAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 锁屏继续出声的第一层：会话类别必须是 .playback（配合 Info.plist 的 UIBackgroundModes=audio）
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&err];
    if (err) NSLog(@"[tf] category error: %@", err);
    err = nil;
    [session setActive:YES error:&err];
    if (err) NSLog(@"[tf] active error: %@", err);

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = [[TFViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // 不在这里做任何"暂停"动作 —— 后台音频由 UIBackgroundModes=audio 保活
    NSLog(@"[tf] entered background, audio keeps running");
}

- (void)applicationWillTerminate:(UIApplication *)application {
    NSLog(@"[tf] terminating");
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TFAppDelegate class]));
    }
}
