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

@end
