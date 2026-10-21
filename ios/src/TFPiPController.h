//
//  TFPiPController.h
//  Toneferry iOS 客户端
//
//  悬浮窗：用 AVKit 画中画承载一块 AVSampleBufferDisplayLayer，
//  把「延迟 / 缓冲 / 电平 / 连接状态」渲染成 CMSampleBuffer 持续喂进去。
//
//  为什么走画中画而不是窗口层级 hack：
//   - PiP 是 iOS 唯一官方允许「浮在其他 App 之上」的形态，不需要越狱；
//   - 它要求 App 挂着 UIBackgroundModes=audio 且 AVAudioSession 为 playback，
//     Toneferry 本来就在放音频，这个前提是免费的。
//
//  首次点击必须能起来：
//   - layer 与 controller 在 prepare 阶段就建好，不能等用户点；
//   - 空转时以 2fps 持续喂帧，让 layer 保持 readyForDisplay；
//   - isPictureInPicturePossible 是异步更新的，用 KVO 盯住，
//     点击时若还没就绪就先挂起请求，等 KVO 翻成 YES 再真正 start。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TFPiPController : NSObject

@property (nonatomic, readonly) BOOL isActive;
@property (nonatomic, readonly, getter=isPossible) BOOL possible;

@property (nonatomic, copy, nullable) void (^onStart)(void);
@property (nonatomic, copy, nullable) void (^onStop)(void);
@property (nonatomic, copy, nullable) void (^onFail)(NSString *reason);

/// hostView 会被放到屏幕角落（2x2，几乎不可见），只作为 layer 的宿主
- (instancetype)initWithHostView:(UIView *)hostView;

/// 提前建好 layer / controller 并开始低帧率预热，必须在用户点击前调用
- (void)prepare;

- (void)updateLatencyMs:(double)latencyMs
              backlogMs:(double)backlogMs
                  level:(float)level
              stateText:(NSString *)stateText
                   host:(NSString *)host;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
