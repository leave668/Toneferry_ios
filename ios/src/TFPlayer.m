//
//  TFPlayer.m
//
//  播放链路：WS(Float32 交错立体声) → 无锁环形缓冲 → AVAudioSourceNode(拉模式) → 扬声器
//
//  为什么用 AVAudioSourceNode 而不是 AVAudioPlayerNode：
//   - PlayerNode 是推模式，必须自己维护「已调度但未播完的帧数」，这个计数依赖
//     completion 回调，回调一旦滞后就会少调度 → 积压 → 追帧 → 计数再次滞后，形成振荡。
//     振荡的结果是波形被反复截断，听感就是沙哑、不清晰。
//   - SourceNode 由音频线程按硬件时钟主动拉数据，天然与播放时钟同步，不需要在飞计数，
//     也不需要定时器泵。网页端 AudioWorklet 用的就是这套机制，所以网页端清晰。
//
//  实时线程约束：renderBlock 里不能加锁、不能分配内存、不能 dispatch、不能调 objc_msgSend。
//  因此环形缓冲与全部播放状态放在纯 C 结构体 TFAudioPipe 里，用 C11 原子操作跨线程。
//

#import "TFPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <stdatomic.h>
#import <string.h>

// 环形缓冲容量（帧）。必须是 2 的幂，用位掩码代替取模。65536 @48k ≈ 1.36s
static const int64_t kPipeCapacity = 65536;
static const int64_t kPipeMask = kPipeCapacity - 1;
// 追帧/欠载恢复时的淡入帧数，避免波形跳变产生咔哒声（96 @48k ≈ 2ms）
static const int32_t kFadeFrames = 96;

#pragma mark - 无锁单生产者单消费者环形缓冲

typedef struct TFAudioPipe {
    float *buf;          // 交错立体声，cap * 2 个 float
    int64_t cap;
    int64_t mask;
    _Atomic int64_t w;   // 累计写入帧数（单调递增）
    _Atomic int64_t r;   // 累计读取帧数（单调递增）
    _Atomic int64_t dropped;
    _Atomic int64_t underruns;
    _Atomic int32_t started;
    _Atomic int64_t prebuffer;
    _Atomic int64_t highWater;
    _Atomic int64_t lowWater;
    _Atomic int32_t peakBits;  // float 的位模式，跨线程传电平
    int32_t fade;              // 仅音频线程读写
} TFAudioPipe;

static TFAudioPipe *pipeCreate(void) {
    TFAudioPipe *p = (TFAudioPipe *)calloc(1, sizeof(TFAudioPipe));
    if (!p) return NULL;
    p->cap = kPipeCapacity;
    p->mask = kPipeMask;
    p->buf = (float *)calloc((size_t)kPipeCapacity * 2, sizeof(float));
    if (!p->buf) {
        free(p);
        return NULL;
    }
    atomic_init(&p->w, 0);
    atomic_init(&p->r, 0);
    atomic_init(&p->dropped, 0);
    atomic_init(&p->underruns, 0);
    atomic_init(&p->started, 0);
    atomic_init(&p->prebuffer, 2400);
    atomic_init(&p->highWater, 6000);
    atomic_init(&p->lowWater, 3000);
    atomic_init(&p->peakBits, 0);
    p->fade = 0;
    return p;
}

static void pipeDestroy(TFAudioPipe *p) {
    if (!p) return;
    free(p->buf);
    free(p);
}

static void pipeReset(TFAudioPipe *p) {
    if (!p) return;
    atomic_store_explicit(&p->w, 0, memory_order_release);
    atomic_store_explicit(&p->r, 0, memory_order_release);
    atomic_store_explicit(&p->started, 0, memory_order_relaxed);
    atomic_store_explicit(&p->peakBits, 0, memory_order_relaxed);
    p->fade = 0;
}

/// 生产者（网络线程）。空间不足时丢弃新数据 —— 消费者侧会追帧，ring 不会长期满。
static void pipePush(TFAudioPipe *p, const float *src, int64_t frames) {
    if (!p || !src || frames <= 0) return;
    int64_t w = atomic_load_explicit(&p->w, memory_order_relaxed);
    int64_t r = atomic_load_explicit(&p->r, memory_order_acquire);
    int64_t avail = w - r;
    if (avail < 0) avail = 0;   // reset 瞬间的竞态，忽略

    int64_t room = p->cap - avail;
    if (room <= 0) {
        atomic_fetch_add_explicit(&p->dropped, frames, memory_order_relaxed);
        return;
    }
    int64_t n = frames < room ? frames : room;
    if (n < frames) {
        atomic_fetch_add_explicit(&p->dropped, frames - n, memory_order_relaxed);
    }

    for (int64_t i = 0; i < n; i++) {
        int64_t pos = (w + i) & p->mask;
        p->buf[pos * 2] = src[i * 2];
        p->buf[pos * 2 + 1] = src[i * 2 + 1];
    }
    atomic_store_explicit(&p->w, w + n, memory_order_release);
}

/**
 * 消费者（实时音频线程）。按硬件时钟拉数据，绝不阻塞。
 * outL/outR 支持 planar（stride 1）与 interleaved（stride 2）两种布局。
 */
static OSStatus pipeRender(TFAudioPipe *p,
                           int64_t frameCount,
                           float *outL, int64_t strideL,
                           float *outR, int64_t strideR,
                           BOOL *isSilence) {
    if (!p || !outL || !outR) {
        *isSilence = YES;
        return noErr;
    }

    int64_t r = atomic_load_explicit(&p->r, memory_order_relaxed);
    int64_t w = atomic_load_explicit(&p->w, memory_order_acquire);
    int64_t avail = w - r;
    if (avail < 0) avail = 0;

    if (!atomic_load_explicit(&p->started, memory_order_relaxed)) {
        if (avail < atomic_load_explicit(&p->prebuffer, memory_order_relaxed)) {
            for (int64_t i = 0; i < frameCount; i++) {
                outL[i * strideL] = 0;
                outR[i * strideR] = 0;
            }
            *isSilence = YES;
            return noErr;
        }
        atomic_store_explicit(&p->started, 1, memory_order_relaxed);
    }

    // 追帧：积压超过高水位就丢掉最老的，把延迟拉回低水位
    int64_t high = atomic_load_explicit(&p->highWater, memory_order_relaxed);
    if (avail > high) {
        int64_t low = atomic_load_explicit(&p->lowWater, memory_order_relaxed);
        int64_t skip = avail - low;
        if (skip > 0) {
            r += skip;
            avail -= skip;
            atomic_fetch_add_explicit(&p->dropped, skip, memory_order_relaxed);
            atomic_store_explicit(&p->r, r, memory_order_release);
            p->fade = kFadeFrames;   // 跳变处淡入，避免咔哒
        }
    }

    int64_t n = avail < frameCount ? avail : frameCount;
    float peak = 0;
    int32_t fade = p->fade;

    for (int64_t i = 0; i < n; i++) {
        int64_t pos = (r + i) & p->mask;
        float l = p->buf[pos * 2];
        float rr = p->buf[pos * 2 + 1];
        if (fade > 0) {
            float g = (float)(kFadeFrames - fade) / (float)kFadeFrames;
            l *= g;
            rr *= g;
            fade--;
        }
        outL[i * strideL] = l;
        outR[i * strideR] = rr;
        float a = fabsf(l) > fabsf(rr) ? fabsf(l) : fabsf(rr);
        if (a > peak) peak = a;
    }
    p->fade = fade;

    if (n < frameCount) {
        for (int64_t i = n; i < frameCount; i++) {
            outL[i * strideL] = 0;
            outR[i * strideR] = 0;
        }
        atomic_fetch_add_explicit(&p->underruns, 1, memory_order_relaxed);
        p->fade = kFadeFrames;   // 下次有数据时淡入
        *isSilence = (n == 0);
    }

    atomic_store_explicit(&p->r, r + n, memory_order_release);

    if (peak > 0) {
        int32_t prevBits = atomic_load_explicit(&p->peakBits, memory_order_relaxed);
        float prev = 0;
        memcpy(&prev, &prevBits, sizeof(float));
        if (peak > prev) {
            int32_t bits = 0;
            memcpy(&bits, &peak, sizeof(float));
            atomic_store_explicit(&p->peakBits, bits, memory_order_relaxed);
        }
    }
    return noErr;
}

#pragma mark - TFPlayer

@interface TFPlayer () <NSURLSessionWebSocketDelegate>
@end

/// 私有方法前置声明：这些方法在 @implementation 里定义得较晚，
/// 不声明会触发 "instance method not found" 警告。
@interface TFPlayer (Private)
- (void)activateSession;
- (void)restartGraphIfNeeded;
- (void)notifyMicState;
- (void)startMicEngine;
- (void)stopMicEngine;
- (void)failMicStart:(NSString *)reason;
- (void)sendJSON:(NSDictionary *)obj;
- (void)sendMicBuffer:(AVAudioPCMBuffer *)buffer;
- (void)setState:(TFPlayerState)state detail:(NSString *)detail;
@end

@implementation TFPlayer {
    TFAudioPipe *_pipe;

    BOOL _graphReady;
    BOOL _wantPlaying;
    BOOL _connecting;
    /// 电脑网页端的总闸状态（false 时服务端不下发音频）
    BOOL _streamEnabled;

    // ---- 手机麦克风上行 ----
    /// 用户是否点了「麦克风」开关
    BOOL _micEnabled;
    /// 电脑端是否已授权
    BOOL _micGranted;
    /// 已请求、正在等电脑授权
    BOOL _micWaiting;
    AVAudioEngine *_micEngine;
    AVAudioConverter *_micConverter;
    AVAudioFormat *_micOutFormat;
    unsigned long long _micFrames;
    /// session 已切到 playAndRecord（开过麦就常驻，避免来回切类别反复打断播放引擎）
    BOOL _micSession;
    /// 采集启动失败（权限被拒 / 无输入设备），不再自动重试，等用户手动重开
    BOOL _micStartFailed;
    /// 防止配置变更回调重入
    BOOL _restartingGraph;
    /// 配置修复节流（类别切换会连环触发通知，1 秒内只修一次）
    NSTimeInterval _lastConfigFix;
    BOOL _reconnectPending;
    NSUInteger _reconnectAttempt;
    double _streamRate;
    double _ioBufferMs;

    // 诊断计数
    uint64_t _rxPackets;
    uint64_t _rxBytes;
    uint64_t _dupPackets;
    uint64_t _graphRebuilds;
    uint64_t _rxPacketsAtStats;
    NSData *_lastPacket;

    NSURLSession *_session;
    NSURLSessionWebSocketTask *_task;
    AVAudioEngine *_engine;
    AVAudioSourceNode *_source;
    AVAudioFormat *_fmt;
    dispatch_queue_t _workQueue;
    dispatch_source_t _statsTimer;
    dispatch_source_t _heartbeatTimer;
    NSTimeInterval _lastNowPlayingUpdate;
}

@synthesize targetLatencyMs = _targetLatencyMs;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _streamRate = 48000;
    _ioBufferMs = 5.0;
    _state = TFPlayerStateIdle;
    _host = @"";
    _targetLatencyMs = 120;
    _pipe = pipeCreate();

    _workQueue = dispatch_queue_create("toneferry.player", DISPATCH_QUEUE_SERIAL);

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15;
    // 让服务端能在日志里区分「原生 App」与「浏览器页面」，便于排查双路播放
    cfg.HTTPAdditionalHeaders = @{@"User-Agent": @"Toneferry-iOS/1.2 (native)"};
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRouteChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMediaServicesReset:)
                                                 name:AVAudioSessionMediaServicesWereResetNotification
                                               object:nil];
    // 关键：切换 AVAudioSession 类别（.playback ↔ .playAndRecord）会让 AVAudioEngine 停止运行，
    // 系统只发这条通知，不注册就永远收不到 —— 表现就是「一开麦克风下行就彻底没声」。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleEngineConfigChange:)
                                                 name:AVAudioEngineConfigurationChangeNotification
                                               object:nil];

    [self setupRemoteCommands];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopTimers];
    if (_engine) {
        [_engine stop];
        _engine = nil;
    }
    if (_pipe) {
        pipeDestroy(_pipe);
        _pipe = NULL;
    }
}

- (void)setTargetLatencyMs:(NSInteger)ms {
    if (ms < 60) ms = 60;
    if (ms > 600) ms = 600;
    _targetLatencyMs = ms;
    [self applyWatermarks];
}

#pragma mark - 水位参数

// 预缓冲 = 低水位 = 0.6 × 目标；高水位 = 1.1 × 目标。
// 稳态积压就停在低水位附近，端到端延迟 ≈ 目标值。
- (void)applyWatermarks {
    if (!_pipe) return;
    double rate = _streamRate > 0 ? _streamRate : 48000;
    double pre = _targetLatencyMs * 0.0006;
    double high = _targetLatencyMs * 0.0011;
    int64_t preFrames = (int64_t)(rate * pre);
    if (preFrames < 1024) preFrames = 1024;
    int64_t highFrames = (int64_t)(rate * high);
    if (highFrames < preFrames * 3 / 2) highFrames = preFrames * 3 / 2;
    atomic_store_explicit(&_pipe->prebuffer, preFrames, memory_order_relaxed);
    atomic_store_explicit(&_pipe->lowWater, preFrames, memory_order_relaxed);
    atomic_store_explicit(&_pipe->highWater, highFrames, memory_order_relaxed);
}

#pragma mark - 对外接口

- (void)start {
    dispatch_async(_workQueue, ^{
        if (self->_wantPlaying) return;
        self->_wantPlaying = YES;
        self->_reconnectAttempt = 0;
        self->_reconnectPending = NO;
        self->_graphRebuilds = 0;
        self->_dupPackets = 0;
        if (self->_pipe) {
            atomic_store_explicit(&self->_pipe->dropped, 0, memory_order_relaxed);
            atomic_store_explicit(&self->_pipe->underruns, 0, memory_order_relaxed);
            pipeReset(self->_pipe);
        }
        [self activateSession];
        [self startTimers];
        [self connect];
    });
}

- (void)stop {
    dispatch_async(_workQueue, ^{
        self->_wantPlaying = NO;
        self->_reconnectPending = NO;
        self->_connecting = NO;
        self->_micEnabled = NO;
        self->_micGranted = NO;
        self->_micWaiting = NO;
        [self stopMicEngine];
        // 整条链路停止时把会话偏好复位，下次「开始收听」回到纯 .playback
        self->_micSession = NO;
        self->_micStartFailed = NO;
        [self closeTask];
        [self stopTimers];
        [self teardownGraph];
        if (self->_pipe) pipeReset(self->_pipe);
        self->_lastPacket = nil;
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
        [self setState:TFPlayerStateIdle detail:@"已停止"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
            [MPNowPlayingInfoCenter defaultCenter].playbackState = MPNowPlayingPlaybackStateStopped;
        });
    });
}

#pragma mark - 麦克风（手机 → 电脑）

- (BOOL)micEnabled { return _micEnabled; }
- (BOOL)micGranted { return _micGranted; }
- (BOOL)micWaiting { return _micWaiting; }

- (void)setMicEnabled:(BOOL)on {
    dispatch_async(_workQueue, ^{
        self->_micEnabled = on;
        if (!on) {
            self->_micGranted = NO;
            self->_micWaiting = NO;
            [self stopMicEngine];
            [self sendJSON:@{ @"type": @"mic-close" }];
            [self notifyMicState];
            return;
        }
        // 请求开麦：未授权时服务端会回 mic-state(granted:NO,pending:YES)
        // 用户手动重开 = 一次明确的重试机会，清掉上次的失败标记
        self->_micStartFailed = NO;
        self->_micWaiting = YES;
        [self sendJSON:@{ @"type": @"mic-open" }];
        [self notifyMicState];
    });
}

- (void)notifyMicState {
    dispatch_async(dispatch_get_main_queue(), ^{
        id<TFPlayerDelegate> d = self.delegate;
        if ([d respondsToSelector:@selector(player:didChangeMicState:granted:waiting:)]) {
            [d player:self didChangeMicState:self->_micEnabled granted:self->_micGranted waiting:self->_micWaiting];
        }
    });
}

- (void)applyMicState:(NSDictionary *)msg {
    BOOL granted = [msg[@"granted"] boolValue];
    BOOL active = [msg[@"active"] boolValue];
    BOOL pending = [msg[@"pending"] boolValue];
    BOOL wasGranted = _micGranted;
    _micGranted = granted;
    _micWaiting = !granted && pending;

    // 电脑端撤销授权后，开关本身也要复位：
    // 否则 _micEnabled 还是 YES，用户再点一下会走「关闭」分支，要连点两次才能重开。
    if (!granted && !pending) {
        _micEnabled = NO;
    }

    if (_micEnabled && granted && (!wasGranted || (active && !_micEngine))) {
        [self startMicEngine];
    }
    if (!granted) {
        [self stopMicEngine];
    }
    [self notifyMicState];
}

- (void)failMicStart:(NSString *)reason {
    NSLog(@"[mic] 采集不可用：%@", reason);
    _micStartFailed = YES;
    _micGranted = NO;
    _micWaiting = NO;
    // 不回切类别：playAndRecord 一样能正常播放，少一次打断就少一次哑火
    [self restartGraphIfNeeded];
    [self notifyMicState];
}

- (void)startMicEngine {
    if (_micEngine) return;
    // 上次失败过就不再自动重试：否则每收到一条 mic-state 都会重切一次类别，
    // 播放引擎被反复打断，表现就是「越点越没声」。
    if (_micStartFailed) return;

    AVAudioSession *session = [AVAudioSession sharedInstance];

    // 必须先显式请求录音权限。不请求时 inputNode 能连上、引擎能启动，
    // 但缓冲区永远是静音 —— 电脑端表现为「授权了、一点声音都没有」。
    if (session.recordPermission == AVAudioSessionRecordPermissionUndetermined) {
        __weak typeof(self) weakSelf = self;
        [session requestRecordPermission:^(BOOL granted) {
            dispatch_async(self->_workQueue, ^{
                TFPlayer *s = weakSelf;
                if (!s) return;
                if (granted) {
                    s->_micStartFailed = NO;
                    [s startMicEngine];
                } else {
                    [s failMicStart:@"用户拒绝了录音权限（设置 → Toneferry → 麦克风）"];
                }
            });
        }];
        return;
    }
    if (session.recordPermission == AVAudioSessionRecordPermissionDenied) {
        [self failMicStart:@"录音权限被拒（设置 → Toneferry → 麦克风）"];
        return;
    }

    // 播放 + 录音必须用 playAndRecord，否则 inputNode 拿不到数据。
    // 类别与选项统一走 activateSession，只在一处维护。
    _micSession = YES;
    [self activateSession];

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *inFormat = [input outputFormatForBus:0];
    if (!inFormat || inFormat.sampleRate <= 0 || inFormat.channelCount == 0) {
        NSLog(@"[mic] 输入格式不可用: %@", inFormat);
        [self failMicStart:@"没有可用的麦克风输入"];
        return;
    }

    // 关掉系统 AEC：它会把下行声音从麦克风信号里减掉，还会把输出路由拉到语音模式，
    // 让下行音质明显变闷。Toneferry 的上行就是「对着手机说话」，不需要 AEC。
    if ([input respondsToSelector:@selector(setVoiceProcessingEnabled:error:)]) {
        NSError *vpErr = nil;
        if (![input setVoiceProcessingEnabled:NO error:&vpErr]) {
            NSLog(@"[mic] 关闭 AEC 失败（忽略）: %@", vpErr);
        }
    }

    _micOutFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                     sampleRate:48000
                                                       channels:1
                                                    interleaved:NO];
    _micConverter = [[AVAudioConverter alloc] initFromFormat:inFormat toFormat:_micOutFormat];
    if (!_micConverter) {
        NSLog(@"[mic] 无法创建重采样器 %@ → 48000", inFormat);
        [self failMicStart:@"重采样器创建失败"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    AVAudioConverter *converter = _micConverter;
    AVAudioFormat *outFormat = _micOutFormat;
    double inRate = inFormat.sampleRate;

    [input installTapOnBus:0
                bufferSize:960
                    format:inFormat
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        TFPlayer *s = weakSelf;
        if (!s || !converter || !outFormat) return;
        AVAudioFrameCount cap = (AVAudioFrameCount)(buffer.frameLength * 48000.0 / inRate) + 64;
        AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFormat
                                                            frameCapacity:cap];
        __block BOOL supplied = NO;
        NSError *err = nil;
        AVAudioConverterOutputStatus st = [converter convertToBuffer:out
                                                               error:&err
                                                  withInputFromBlock:^AVAudioBuffer *(
                                                      AVAudioPacketCount inPackets,
                                                      AVAudioConverterInputStatus *outStatus) {
            if (supplied) {
                *outStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }
            supplied = YES;
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return buffer;
        }];
        if (st == AVAudioConverterOutputStatus_HaveData && out.frameLength > 0) {
            [s sendMicBuffer:out];
        }
    }];

    [engine prepare];
    NSError *startErr = nil;
    if (![engine startAndReturnError:&startErr]) {
        NSLog(@"[mic] 采集启动失败: %@", startErr);
        [input removeTapOnBus:0];
        [self failMicStart:@"麦克风启动失败"];
        return;
    }
    _micEngine = engine;
    NSLog(@"[mic] 上行采集已启动 %.0fHz → 48000Hz", inRate);

    // 压低下行音量，打断「手机扬声器 → 手机麦克风 → 电脑扬声器 → loopback」的声学环路
    if (_engine) _engine.mainMixerNode.outputVolume = 0.2;

    // 切类别刚刚打断了播放引擎，立刻把它拉回来
    [self restartGraphIfNeeded];
}

- (void)stopMicEngine {
    if (_micEngine) {
        [_micEngine.inputNode removeTapOnBus:0];
        [_micEngine stop];
        _micEngine = nil;
    }
    _micConverter = nil;
    _micOutFormat = nil;
    _micStartFailed = NO;
    // 麦克风关了，下行音量恢复正常
    if (_engine) _engine.mainMixerNode.outputVolume = 1.0;

    // 关键：不再把类别切回 .playback。
    // 切回去又是一次配置变更，播放引擎会再被打断一次 ——
    // 这正是「关掉麦克风之后照样没声音，非得停止收听再重开」的根因。
    // 保持 .playAndRecord（DefaultToSpeaker）完全可以正常播放。
    [self restartGraphIfNeeded];
}

- (void)sendMicBuffer:(AVAudioPCMBuffer *)buffer {
    if (!_micGranted) return;
    NSURLSessionWebSocketTask *task = _task;
    if (!task || task.state != NSURLSessionTaskStateRunning) return;
    float *src = buffer.floatChannelData ? buffer.floatChannelData[0] : NULL;
    if (!src) return;
    NSUInteger frames = buffer.frameLength;
    if (frames == 0) return;

    // 4 字节小端通道号（1 = 麦克风）+ 裸 Float32 PCM
    NSMutableData *data = [NSMutableData dataWithCapacity:4 + frames * 4];
    uint32_t channel = 1;
    [data appendBytes:&channel length:4];
    [data appendBytes:src length:frames * 4];

    [task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:data]
    completionHandler:^(NSError *error) {
        if (error) {
            dispatch_async(self->_workQueue, ^{
                NSLog(@"[mic] 上行发送失败: %@", error.localizedDescription);
            });
        }
    }];
    _micFrames += 1;
}

#pragma mark - 状态

- (void)setState:(TFPlayerState)state detail:(NSString *)detail {
    _state = state;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<TFPlayerDelegate> d = self.delegate;
        if ([d respondsToSelector:@selector(player:didChangeState:detail:)]) {
            [d player:self didChangeState:state detail:detail ?: @""];
        }
    });
}

#pragma mark - 音频会话

- (void)activateSession {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *err = nil;

    // 开过麦克风之后 session 常驻 .playAndRecord：来回切类别会二次打断播放引擎，
    // 每次打断都要重建整张音频图，既费时又容易在切换瞬间吞掉声音。
    AVAudioSessionCategory category = _micSession
        ? AVAudioSessionCategoryPlayAndRecord
        : AVAudioSessionCategoryPlayback;
    AVAudioSessionCategoryOptions opts = 0;
    if (_micSession) {
        // .playAndRecord 默认输出走听筒，不指定 DefaultToSpeaker 会「几乎听不见」；
        // 蓝牙用 A2DP 而不是 HFP，否则输出会被降到 8k/16k 单声道，下行直接变闷。
        opts = AVAudioSessionCategoryOptionDefaultToSpeaker |
               AVAudioSessionCategoryOptionAllowBluetoothA2DP;
    }

    // mode 用 default 保证纯直通，不引入系统侧语音 DSP
    if (![s setCategory:category mode:AVAudioSessionModeDefault options:opts error:&err]) {
        NSLog(@"[tf] setCategory failed: %@", err);
    }
    if (![s setPreferredIOBufferDuration:0.005 error:nil]) {
        NSLog(@"[tf] 5ms IO buffer rejected, keep default");
    }
    [s setPreferredSampleRate:48000 error:nil];

    err = nil;
    if (![s setActive:YES error:&err]) {
        NSLog(@"[tf] setActive failed: %@", err);
    }
    NSTimeInterval io = s.IOBufferDuration;
    if (io > 0) _ioBufferMs = io * 1000.0;
}

/**
 * AVAudioEngine 因会话配置变化而停止时的自救。
 *
 * 切 .playAndRecord、插拔耳机、蓝牙切换都会触发。不处理的话引擎就此停摆，
 * 而 _wantPlaying 仍是 YES，界面显示「播放中」但没有一点声音。
 */
- (void)handleEngineConfigChange:(NSNotification *)note {
    dispatch_async(_workQueue, ^{
        if (!self->_wantPlaying) return;
        if (!self->_graphReady) return;   // 图还没建好，start 流程会自己处理
        NSTimeInterval now = CACurrentMediaTime();
        if (now - self->_lastConfigFix < 1.0) return;   // 连环通知只修一次

        // 一切正常就别折腾：恢复动作本身也可能触发新的配置变更，形成抖动
        BOOL playOk = self->_engine && self->_engine.isRunning;
        BOOL micOk = !self->_micEngine || self->_micEngine.isRunning;
        if (playOk && micOk) return;

        self->_lastConfigFix = now;
        NSLog(@"[tf] 音频引擎配置变更，尝试恢复");
        [self activateSession];
        [self restartGraphIfNeeded];

        // 采集引擎同样会被打断，能重启就重启，不行就置失败位等用户重开
        if (self->_micEngine && !self->_micEngine.isRunning) {
            NSError *e = nil;
            if (![self->_micEngine startAndReturnError:&e]) {
                NSLog(@"[mic] 配置变更后重启采集失败: %@", e);
                [self stopMicEngine];
                self->_micStartFailed = YES;
                [self notifyMicState];
            }
        }
    });
}

- (void)handleInterruption:(NSNotification *)note {
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.integerValue == AVAudioSessionInterruptionTypeBegan) {
        dispatch_async(_workQueue, ^{
            if (self->_engine.isRunning) [self->_engine pause];
        });
    } else {
        NSNumber *opt = note.userInfo[AVAudioSessionInterruptionOptionKey];
        dispatch_async(_workQueue, ^{
            if (!self->_wantPlaying) return;
            [self activateSession];
            if (opt.integerValue & AVAudioSessionInterruptionOptionShouldResume) {
                [self restartGraphIfNeeded];
            }
        });
    }
}

- (void)handleRouteChange:(NSNotification *)note {
    NSNumber *reason = note.userInfo[AVAudioSessionRouteChangeReasonKey];
    if (reason.integerValue != AVAudioSessionRouteChangeReasonOldDeviceUnavailable) return;
    dispatch_async(_workQueue, ^{
        if (!self->_wantPlaying) return;
        [self activateSession];
        [self restartGraphIfNeeded];
    });
}

- (void)handleMediaServicesReset:(NSNotification *)note {
    dispatch_async(_workQueue, ^{
        if (!self->_wantPlaying) return;
        [self teardownGraph];
        [self activateSession];
        if (![self setupGraph:self->_streamRate]) {
            [self setState:TFPlayerStateFailed detail:@"音频服务重置后重建失败"];
        }
    });
}

- (void)restartGraphIfNeeded {
    if (!_wantPlaying) return;
    if (_restartingGraph) return;
    if (!_graphReady || !_engine) return;
    if (_engine.isRunning) return;
    _restartingGraph = YES;
    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) {
        NSLog(@"[tf] 引擎重启失败，重建音频图: %@", err);
        [self teardownGraph];
        if (![self setupGraph:_streamRate]) {
            [self setState:TFPlayerStateFailed detail:@"音频图重建失败"];
        }
    } else {
        NSLog(@"[tf] 引擎已恢复运行");
    }
    _restartingGraph = NO;
}

#pragma mark - 音频图

- (BOOL)setupGraph:(double)sampleRate {
    double rate = sampleRate > 0 ? sampleRate : 48000;
    if (_graphReady && fabs(_streamRate - rate) < 1.0) return YES;

    [self teardownGraph];
    _streamRate = rate;
    // 采样率变了，缓冲里是旧速率的帧，直接清掉重新预缓冲
    if (_pipe) pipeReset(_pipe);
    [self applyWatermarks];

    _fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                            sampleRate:_streamRate
                                              channels:2
                                           interleaved:NO];
    if (!_fmt) return NO;

    _engine = [[AVAudioEngine alloc] init];
    TFAudioPipe *pipe = _pipe;   // 裸指针，block 只捕获它，不捕获 self

    _source = [[AVAudioSourceNode alloc] initWithFormat:_fmt
        renderBlock:^OSStatus(BOOL *isSilence,
                              const AudioTimeStamp *timestamp,
                              AVAudioFrameCount frameCount,
                              AudioBufferList *outputData) {
            if (!outputData || outputData->mNumberBuffers == 0) {
                *isSilence = YES;
                return noErr;
            }
            float *base = (float *)outputData->mBuffers[0].mData;
            if (!base) {
                *isSilence = YES;
                return noErr;
            }
            if (outputData->mNumberBuffers >= 2) {
                float *right = (float *)outputData->mBuffers[1].mData;
                if (!right) right = base;
                return pipeRender(pipe, (int64_t)frameCount, base, 1, right, 1, isSilence);
            }
            // interleaved 兜底：同一块内存，步长 2
            return pipeRender(pipe, (int64_t)frameCount, base, 2, base + 1, 2, isSilence);
        }];

    if (!_source) {
        [self teardownGraph];
        return NO;
    }

    [_engine attachNode:_source];
    [_engine connect:_source to:_engine.mainMixerNode format:_fmt];
    // 开麦时把下行压低：手机扬声器放出来的声音会被手机麦克风采回去，
    // 再经电脑扬声器 → WASAPI loopback → 手机，形成完整声学环路（啸叫）。
    // 0.2 的增益把环路增益压到远小于 1，既能听见又不啸叫。
    _engine.mainMixerNode.outputVolume = _micEngine ? 0.2 : 1.0;

    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) {
        NSLog(@"[tf] engine start failed: %@", err);
        [self teardownGraph];
        return NO;
    }
    _graphReady = YES;
    _graphRebuilds++;
    NSLog(@"[tf] graph ready rate=%.0f prebuffer=%lld high=%lld",
          _streamRate,
          (long long)atomic_load_explicit(&_pipe->prebuffer, memory_order_relaxed),
          (long long)atomic_load_explicit(&_pipe->highWater, memory_order_relaxed));
    return YES;
}

- (void)teardownGraph {
    // 顺序要紧：先停引擎确保 renderBlock 不再被调用，再释放 pipe 引用
    if (_engine) {
        [_engine stop];
        [_engine reset];
        if (_source) {
            [_engine detachNode:_source];
        }
        _engine = nil;
    }
    _source = nil;
    _fmt = nil;
    _graphReady = NO;
}

#pragma mark - 定时器

- (void)startTimers {
    if (!_statsTimer) {
        _statsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _workQueue);
        dispatch_source_set_timer(_statsTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                                  250 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_statsTimer, ^{ [weakSelf emitStats]; });
        dispatch_resume(_statsTimer);
    }
    if (!_heartbeatTimer) {
        _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _workQueue);
        dispatch_source_set_timer(_heartbeatTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
                                  20 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_heartbeatTimer, ^{ [weakSelf sendJSON:@{@"type": @"ping"}]; });
        dispatch_resume(_heartbeatTimer);
    }
}

- (void)stopTimers {
    if (_statsTimer) {
        dispatch_source_cancel(_statsTimer);
        _statsTimer = nil;
    }
    if (_heartbeatTimer) {
        dispatch_source_cancel(_heartbeatTimer);
        _heartbeatTimer = nil;
    }
}

#pragma mark - 统计 / 诊断

- (void)emitStats {
    if (!_pipe) return;
    double rate = _streamRate > 0 ? _streamRate : 48000;

    int64_t w = atomic_load_explicit(&_pipe->w, memory_order_acquire);
    int64_t r = atomic_load_explicit(&_pipe->r, memory_order_acquire);
    int64_t avail = w - r;
    if (avail < 0) avail = 0;

    double bufferedSec = (double)avail / rate;
    double backlogMs = bufferedSec * 1000.0;
    uint64_t dropped = (uint64_t)atomic_load_explicit(&_pipe->dropped, memory_order_relaxed);
    uint64_t underruns = (uint64_t)atomic_load_explicit(&_pipe->underruns, memory_order_relaxed);

    uint64_t delta = _rxPackets - _rxPacketsAtStats;
    _rxPacketsAtStats = _rxPackets;
    double pps = delta / 0.25;

    int32_t peakBits = atomic_load_explicit(&_pipe->peakBits, memory_order_relaxed);
    float level = 0;
    memcpy(&level, &peakBits, sizeof(float));
    atomic_store_explicit(&_pipe->peakBits, 0, memory_order_relaxed);

    double totalMs = backlogMs + _ioBufferMs;

    // renderBlock 在实时线程，不能回调 delegate，所以「开始出声」在这里判定
    int32_t started = atomic_load_explicit(&_pipe->started, memory_order_relaxed);
    if (started && _wantPlaying && _state != TFPlayerStatePlaying) {
        [self setState:TFPlayerStatePlaying detail:@"播放中"];
        [self updateNowPlayingWithLatency:totalMs backlog:backlogMs];
        _lastNowPlayingUpdate = CACurrentMediaTime();
    }

    // 锁屏媒体卡片每秒刷一次，把实时延迟写进副标题。刷太快系统会丢弃。
    if (started && _wantPlaying) {
        NSTimeInterval now = CACurrentMediaTime();
        if (now - _lastNowPlayingUpdate >= 1.0) {
            _lastNowPlayingUpdate = now;
            [self updateNowPlayingWithLatency:totalMs backlog:backlogMs];
        }
    }

    NSDictionary *diag = @{
        @"packetRate": @(pps),
        @"backlogMs": @(backlogMs),
        @"inFlightMs": @(_ioBufferMs),
        @"dropped": @(dropped),
        @"underruns": @(underruns),
        @"duplicates": @(_dupPackets),
        @"packets": @(_rxPackets),
        @"rebuilds": @(_graphRebuilds),
        @"latencyMs": @(totalMs),
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        id<TFPlayerDelegate> d = self.delegate;
        if ([d respondsToSelector:@selector(player:didUpdateStats:level:)]) {
            [d player:self didUpdateStats:bufferedSec level:level];
        }
        if ([d respondsToSelector:@selector(player:didUpdateDiagnostics:)]) {
            [d player:self didUpdateDiagnostics:diag];
        }
    });
}

#pragma mark - WebSocket

- (NSURL *)wsURL {
    NSString *host = [_host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (host.length == 0) return nil;
    if ([host hasPrefix:@"http://"]) host = [host substringFromIndex:7];
    if ([host hasPrefix:@"https://"]) host = [host substringFromIndex:8];
    if ([host hasPrefix:@"ws://"]) host = [host substringFromIndex:5];
    if ([host hasPrefix:@"wss://"]) host = [host substringFromIndex:6];
    if ([host rangeOfString:@"/"].location != NSNotFound) {
        host = [host componentsSeparatedByString:@"/"].firstObject;
    }
    if ([host rangeOfString:@":"].location == NSNotFound) host = [host stringByAppendingString:@":3088"];
    return [NSURL URLWithString:[NSString stringWithFormat:@"ws://%@/audio", host]];
}

- (void)connect {
    // 防重入：start 与断线重连可能同时触发，重复建连会让两份音频同时出声
    if (_connecting) return;
    [self closeTask];
    NSURL *url = [self wsURL];
    if (!url) {
        [self setState:TFPlayerStateFailed detail:@"地址无效，示例 192.168.0.80:3088"];
        _wantPlaying = NO;
        return;
    }

    _connecting = YES;
    [self setState:TFPlayerStateConnecting detail:@"连接中…"];
    NSURLSessionWebSocketTask *task = [_session webSocketTaskWithURL:url];
    _task = task;
    [task resume];
    [self receiveLoopForTask:task];
    [self sendJSON:@{@"type": @"get-config"}];
}

- (void)closeTask {
    _connecting = NO;
    if (_task) {
        [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
        _task = nil;
    }
}

/// 只处理「当前这条」task 的消息；旧 task 被 cancel 后的回调直接丢弃，避免误触发重连
- (void)receiveLoopForTask:(NSURLSessionWebSocketTask *)task {
    if (!task || task != _task) return;
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        TFPlayer *s = weakSelf;
        if (!s) return;
        if (task != s->_task) return;
        if (error) {
            [s handleDisconnect:error.localizedDescription];
            return;
        }
        s->_connecting = NO;
        if (message.type == NSURLSessionWebSocketMessageTypeData) {
            NSData *data = message.data;
            dispatch_async(s->_workQueue, ^{ [s handlePCM:data]; });
        } else if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSString *text = message.string;
            dispatch_async(s->_workQueue, ^{ [s handleText:text]; });
        }
        [s receiveLoopForTask:task];
    }];
}

- (void)handlePCM:(NSData *)data {
    if (!_graphReady || !_wantPlaying || !_pipe) return;
    if (data.length < 8) return;

    _rxPackets++;
    _rxBytes += data.length;

    const float *f = (const float *)data.bytes;
    NSInteger total = (NSInteger)(data.length / sizeof(float));

    // 重复包过滤：服务端若把同一帧发了两遍，叠加起来是梳状滤波（听感即回声）。
    // 全零包（静音）不参与判定，避免误丢正常静音段。
    BOOL allZero = YES;
    for (NSInteger i = 0; i < total; i++) {
        if (f[i] != 0.0f) {
            allZero = NO;
            break;
        }
    }
    if (!allZero && _lastPacket.length == data.length &&
        memcmp(_lastPacket.bytes, data.bytes, data.length) == 0) {
        _dupPackets++;
        return;
    }
    if (!allZero) _lastPacket = [data copy];

    NSInteger frames = total / 2;
    if (frames <= 0) return;
    pipePush(_pipe, f, (int64_t)frames);
}

- (void)handleText:(NSString *)text {
    if (!text.length) return;
    NSData *raw = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
    if (![msg isKindOfClass:[NSDictionary class]]) return;

    NSString *type = msg[@"type"];
    if ([type isEqualToString:@"audio-config"]) {
        double sr = [msg[@"sampleRate"] doubleValue];
        if (sr <= 0) sr = 48000;
        if (![self setupGraph:sr]) {
            [self setState:TFPlayerStateFailed detail:@"音频引擎初始化失败"];
            return;
        }
        if (_pipe && !atomic_load_explicit(&_pipe->started, memory_order_relaxed)) {
            [self setState:TFPlayerStateBuffering detail:@"缓冲中…"];
        }
    } else if ([type isEqualToString:@"stream-state"]) {
        // 电脑网页端的「开始收听」是总开关。没点时服务端一帧都不发，
        // 这里要明确告诉用户「去电脑上点一下」，否则看起来就像连不上。
        _streamEnabled = [msg[@"enabled"] boolValue];
        if (!_streamEnabled) {
            if (_pipe) pipeReset(_pipe);
            [self setState:TFPlayerStateBuffering detail:@"等待电脑端点击「开始收听」…"];
        } else if (_pipe && !atomic_load_explicit(&_pipe->started, memory_order_relaxed)) {
            [self setState:TFPlayerStateBuffering detail:@"缓冲中…"];
        }
    } else if ([type isEqualToString:@"mic-state"]) {
        [self applyMicState:msg];
    } else if ([type isEqualToString:@"error"]) {
        NSString *m = msg[@"message"];
        [self setState:TFPlayerStateFailed detail:(m.length ? m : @"服务端错误")];
    }
}

- (void)sendJSON:(NSDictionary *)obj {
    NSURLSessionWebSocketTask *task = _task;
    if (!task || task.state != NSURLSessionTaskStateRunning) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text]
    completionHandler:^(NSError *error) {
        if (error) {
            dispatch_async(self->_workQueue, ^{
                [self handleDisconnect:error.localizedDescription];
            });
        }
    }];
}

- (void)handleDisconnect:(NSString *)reason {
    if (!_wantPlaying || _reconnectPending) return;
    [self closeTask];
    if (_pipe) pipeReset(_pipe);   // 清空缓冲 + 复位起播标志，重连后重新预缓冲
    _lastPacket = nil;

    _reconnectPending = YES;
    _reconnectAttempt++;
    double delay = 0.5 * pow(2.0, (double)MIN(_reconnectAttempt - 1, 4));
    if (delay > 8.0) delay = 8.0;
    [self setState:TFPlayerStateReconnecting
            detail:[NSString stringWithFormat:@"连接断开，%.0fs 后重连", delay]];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _workQueue, ^{
        TFPlayer *s = weakSelf;
        if (!s) return;
        s->_reconnectPending = NO;
        if (s->_wantPlaying) [s connect];
    });
}

#pragma mark - 锁屏控制 / 正在播放

- (void)setupRemoteCommands {
    MPRemoteCommandCenter *c = [MPRemoteCommandCenter sharedCommandCenter];
    __weak typeof(self) weakSelf = self;

    [c.playCommand setEnabled:YES];
    [c.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        TFPlayer *s = weakSelf;
        if (!s) return MPRemoteCommandHandlerStatusCommandFailed;
        dispatch_async(s->_workQueue, ^{
            if (!s->_wantPlaying) [s start];
            else [s restartGraphIfNeeded];
        });
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [c.pauseCommand setEnabled:YES];
    [c.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf stop];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [c.togglePlayPauseCommand setEnabled:YES];
    [c.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        TFPlayer *s = weakSelf;
        if (!s) return MPRemoteCommandHandlerStatusCommandFailed;
        dispatch_async(s->_workQueue, ^{
            if (s->_wantPlaying) [s stop];
            else [s start];
        });
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [c.stopCommand setEnabled:YES];
    [c.stopCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [weakSelf stop];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

/// 锁屏 / 控制中心封面的缩略图：深色底 + 绿色波形柱，一次生成后缓存
+ (UIImage *)sharedArtwork {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize size = CGSizeMake(512, 512);
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            CGContextRef c = ctx.CGContext;
            CGContextSetRGBFillColor(c, 0.043, 0.043, 0.118, 1);
            CGContextFillRect(c, CGRectMake(0, 0, 512, 512));

            const int bars = 13;
            CGFloat bw = 22, gap = 12;
            CGFloat totalW = bars * bw + (bars - 1) * gap;
            CGFloat x0 = (512 - totalW) / 2.0;
            CGFloat hs[13] = {0.18, 0.34, 0.52, 0.78, 0.96, 0.70, 0.44,
                              0.62, 0.88, 0.54, 0.36, 0.24, 0.14};
            CGContextSetRGBFillColor(c, 0.13, 0.77, 0.37, 1);
            for (int i = 0; i < bars; i++) {
                CGFloat h = hs[i] * 240.0;
                CGRect bar = CGRectMake(x0 + i * (bw + gap), 256 - h / 2.0, bw, h);
                UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:bw / 2.0];
                CGContextAddPath(c, p.CGPath);
                CGContextFillPath(c);
            }
        }];
    });
    return img;
}

- (void)updateNowPlaying {
    [self updateNowPlayingWithLatency:-1 backlog:0];
}

- (void)updateNowPlayingWithLatency:(double)latencyMs backlog:(double)backlogMs {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = @"Toneferry 系统音频";
    if (latencyMs >= 0) {
        // 锁屏卡片第二行直接显示实时延迟，锁屏状态下也能看到链路状况
        info[MPMediaItemPropertyArtist] =
            [NSString stringWithFormat:@"延迟 %.0fms · 缓冲 %.0fms", latencyMs, backlogMs];
    } else {
        info[MPMediaItemPropertyArtist] = _host.length ? _host : @"PC 音频推流";
    }
    info[MPMediaItemPropertyAlbumTitle] = _host.length ? _host : @"WASAPI Loopback";
    info[MPNowPlayingInfoPropertyIsLiveStream] = @YES;
    info[MPNowPlayingInfoPropertyPlaybackRate] = @1.0;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIImage *art = [TFPlayer sharedArtwork];
        if (art) {
            info[MPMediaItemPropertyArtwork] =
                [[MPMediaItemArtwork alloc] initWithBoundsSize:art.size
                                                requestHandler:^UIImage *(CGSize s) { return art; }];
        }
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
        if (@available(iOS 13.0, *)) {
            [MPNowPlayingInfoCenter defaultCenter].playbackState = MPNowPlayingPlaybackStatePlaying;
        }
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    });
}

@end
