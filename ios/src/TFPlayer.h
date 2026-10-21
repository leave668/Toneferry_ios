//
//  TFPlayer.h
//  Toneferry iOS 客户端
//
//  职责：连接 PC 端 WebSocket（/audio），收 Float32 交错 PCM，用 AVAudioEngine 播放。
//  关键：AVAudioSession 必须是 .playback，且 Info.plist 声明 UIBackgroundModes=audio，
//        锁屏/切后台后进程不被挂起，socket 与音频管线都继续工作。
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TFPlayerState) {
    TFPlayerStateIdle = 0,
    TFPlayerStateConnecting,
    TFPlayerStateBuffering,
    TFPlayerStatePlaying,
    TFPlayerStateReconnecting,
    TFPlayerStateFailed,
};

@class TFPlayer;

@protocol TFPlayerDelegate <NSObject>
- (void)player:(TFPlayer *)player didChangeState:(TFPlayerState)state detail:(NSString *)detail;
- (void)player:(TFPlayer *)player didUpdateStats:(double)bufferedSeconds level:(float)level;
@optional
/// 诊断数据：packetRate / backlogMs / inFlightMs / dropped / underruns / packets
- (void)player:(TFPlayer *)player didUpdateDiagnostics:(NSDictionary<NSString *, NSNumber *> *)diag;
/// 麦克风状态变化：enabled=用户开了开关，granted=电脑已授权，waiting=在等电脑授权
- (void)player:(TFPlayer *)player didChangeMicState:(BOOL)enabled granted:(BOOL)granted waiting:(BOOL)waiting;
@end

@interface TFPlayer : NSObject

@property (nonatomic, weak) id<TFPlayerDelegate> delegate;
@property (nonatomic, readonly) TFPlayerState state;
/// "192.168.0.80:3088"
@property (nonatomic, copy) NSString *host;

/// 端到端延迟目标（毫秒）。越小越跟手，但更容易被网络抖动打断。
/// 默认 120。范围会被夹到 60~600。
@property (nonatomic, assign) NSInteger targetLatencyMs;

- (void)start;
- (void)stop;

/// 手机当电脑麦克风：开启/关闭上行采集。
/// 真正开麦要等电脑端授权（收到 mic-state.granted=YES），未授权时只是「请求中」。
- (void)setMicEnabled:(BOOL)on;
@property (nonatomic, readonly) BOOL micEnabled;
@property (nonatomic, readonly) BOOL micGranted;
@property (nonatomic, readonly) BOOL micWaiting;

@end
