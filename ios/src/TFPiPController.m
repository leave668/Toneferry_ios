//
//  TFPiPController.m
//

#import "TFPiPController.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreText/CoreText.h>
#import <math.h>

static const CGFloat kCanvasW = 480;
static const CGFloat kCanvasH = 270;
static const NSTimeInterval kRateActive = 0.125;   // 8 fps，浮窗可见时
static const NSTimeInterval kRateWarm = 0.5;       // 2 fps，空转预热
static const NSTimeInterval kStartTimeout = 4.0;

#pragma mark - 绘图工具

static CGColorRef TFColor(CGFloat r, CGFloat g, CGFloat b) {
    return CGColorCreateGenericRGB(r / 255.0, g / 255.0, b / 255.0, 1.0);
}

static CTFontRef TFMakeFont(CGFloat size, BOOL bold) {
    CTFontRef base = CTFontCreateUIFontForLanguage(bold ? kCTFontUIFontEmphasizedSystem
                                                        : kCTFontUIFontSystem, size, NULL);
    if (!base) base = CTFontCreateWithName(CFSTR("Helvetica"), size, NULL);
    return base;
}

static CGFloat TFTextWidth(NSString *text, CGFloat size, BOOL bold) {
    if (text.length == 0) return 0;
    CTFontRef font = TFMakeFont(size, bold);
    NSDictionary *attrs = @{ (id)kCTFontAttributeName: (__bridge id)font };
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGFloat w = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    CFRelease(font);
    return w;
}

/// y 为基线位置，坐标系已翻转为「左上原点、y 向下」
static void TFDrawText(CGContextRef ctx, NSString *text, CGFloat x, CGFloat y,
                       CGFloat size, BOOL bold, CGColorRef color) {
    if (text.length == 0) return;
    CTFontRef font = TFMakeFont(size, bold);
    NSDictionary *attrs = @{
        (id)kCTFontAttributeName: (__bridge id)font,
        (id)kCTForegroundColorAttributeName: (__bridge id)color,
    };
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, x, y);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextSetTextPosition(ctx, 0, 0);
    CTLineDraw(line, ctx);
    CGContextRestoreGState(ctx);
    CFRelease(line);
    CFRelease(font);
}

static void TFDrawTextRight(CGContextRef ctx, NSString *text, CGFloat rightX, CGFloat y,
                            CGFloat size, BOOL bold, CGColorRef color) {
    CGFloat w = TFTextWidth(text, size, bold);
    TFDrawText(ctx, text, rightX - w, y, size, bold, color);
}

#pragma mark - TFPiPController

@interface TFPiPController () <AVPictureInPictureControllerDelegate,
                               AVPictureInPictureSampleBufferPlaybackDelegate>
@end

@implementation TFPiPController {
    UIView *_hostView;
    AVSampleBufferDisplayLayer *_layer;
    AVPictureInPictureController *_pip;
    CVPixelBufferRef _pixelBuffer;
    NSTimer *_timer;
    NSTimer *_timeoutTimer;
    NSTimeInterval _rate;

    double _latencyMs;
    double _backlogMs;
    float _level;
    NSString *_stateText;
    NSString *_hostText;

    BOOL _prepared;
    BOOL _isActive;
    BOOL _possible;
    BOOL _pendingStart;
}

- (instancetype)initWithHostView:(UIView *)hostView {
    self = [super init];
    if (!self) return nil;
    _hostView = hostView;
    _latencyMs = -1;
    _backlogMs = 0;
    _level = 0;
    _stateText = @"未连接";
    _hostText = @"";
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    [_timeoutTimer invalidate];
    if (_pip) {
        @try {
            [_pip removeObserver:self forKeyPath:@"pictureInPicturePossible"];
        } @catch (__unused NSException *e) {
        }
        _pip.delegate = nil;
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
}

- (BOOL)isActive { return _isActive; }
- (BOOL)isPossible { return _possible; }

#pragma mark - 数据

- (void)updateLatencyMs:(double)latencyMs
              backlogMs:(double)backlogMs
                  level:(float)level
              stateText:(NSString *)stateText
                   host:(NSString *)host {
    _latencyMs = latencyMs;
    _backlogMs = backlogMs;
    _level = level;
    if (stateText.length) _stateText = [stateText copy];
    if (host.length) _hostText = [host copy];
}

#pragma mark - 生命周期

/// 必须在用户点击前调用：把 layer / controller 建好，并开始空转预热
- (void)prepare {
    if (_prepared) return;
    _prepared = YES;
    [self setupIfNeeded];
    [self renderFrame];
    [self setRenderRate:kRateWarm];
}

- (void)setupIfNeeded {
    if (_pip) return;

    _layer = [AVSampleBufferDisplayLayer layer];
    _layer.videoGravity = AVLayerVideoGravityResizeAspect;
    _layer.frame = _hostView.bounds;
    _layer.backgroundColor = [UIColor blackColor].CGColor;
    [_hostView.layer addSublayer:_layer];

    AVPictureInPictureControllerContentSource *src =
        [[AVPictureInPictureControllerContentSource alloc]
            initWithSampleBufferDisplayLayer:_layer
                            playbackDelegate:self];
    _pip = [[AVPictureInPictureController alloc] initWithContentSource:src];
    _pip.delegate = self;
    if (@available(iOS 14.2, *)) {
        _pip.canStartPictureInPictureAutomaticallyFromInline = NO;
    }

    // isPictureInPicturePossible 是异步更新的，同步读会拿到过期的 NO
    [_pip addObserver:self
           forKeyPath:@"pictureInPicturePossible"
              options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial
              context:NULL];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"pictureInPicturePossible"]) {
        _possible = _pip.isPictureInPicturePossible;
        if (_possible && _pendingStart) {
            _pendingStart = NO;
            [_timeoutTimer invalidate];
            _timeoutTimer = nil;
            [_pip startPictureInPicture];
        }
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)setRenderRate:(NSTimeInterval)rate {
    if (_timer && fabs(_rate - rate) < 0.001) return;
    _rate = rate;
    [_timer invalidate];
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:rate repeats:YES block:^(NSTimer *t) {
        [weakSelf renderFrame];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)start {
    [self prepare];
    if (!_pip) return;
    if (_pip.isPictureInPictureActive) return;

    [self renderFrame];
    _possible = _pip.isPictureInPicturePossible;

    if (_possible) {
        [_pip startPictureInPicture];
        return;
    }

    // 还没就绪：挂起请求，等 KVO 翻成 YES 自动起播
    _pendingStart = YES;
    [_timeoutTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:kStartTimeout
                                                    repeats:NO
                                                      block:^(NSTimer *t) {
        TFPiPController *s = weakSelf;
        if (!s) return;
        if (s->_pendingStart) {
            s->_pendingStart = NO;
            if (s.onFail) s.onFail(@"系统未就绪（isPictureInPicturePossible=NO）");
        }
    }];
}

- (void)stop {
    _pendingStart = NO;
    [_timeoutTimer invalidate];
    _timeoutTimer = nil;
    if (_pip && _pip.isPictureInPictureActive) {
        [_pip stopPictureInPicture];
    }
}

#pragma mark - 渲染

- (void)renderFrame {
    if (!_layer) return;

    if (!_pixelBuffer) {
        NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
        CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault,
                                         (size_t)kCanvasW, (size_t)kCanvasH,
                                         kCVPixelFormatType_32BGRA,
                                         (__bridge CFDictionaryRef)attrs,
                                         &_pixelBuffer);
        if (r != kCVReturnSuccess || !_pixelBuffer) return;
    }

    CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
    void *base = CVPixelBufferGetBaseAddress(_pixelBuffer);
    size_t bpr = CVPixelBufferGetBytesPerRow(_pixelBuffer);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, (size_t)kCanvasW, (size_t)kCanvasH,
                                             8, bpr, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);

    if (ctx) {
        [self drawInto:ctx];
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);

    [self enqueue];
}

- (void)drawInto:(CGContextRef)ctx {
    CGColorRef bg = TFColor(11, 11, 30);
    CGColorRef dim = TFColor(139, 147, 167);
    CGColorRef body = TFColor(199, 204, 216);
    CGColorRef white = TFColor(255, 255, 255);
    CGColorRef green = TFColor(34, 197, 94);
    CGColorRef track = TFColor(30, 30, 56);

    // 翻转成左上原点
    CGContextTranslateCTM(ctx, 0, kCanvasH);
    CGContextScaleCTM(ctx, 1, -1);

    CGContextSetFillColorWithColor(ctx, bg);
    CGContextFillRect(ctx, CGRectMake(0, 0, kCanvasW, kCanvasH));

    TFDrawText(ctx, @"Toneferry · 系统音频", 24, 26, 13, NO, dim);

    // 右上角状态：小圆点 + 文案
    BOOL playing = [_stateText isEqualToString:@"播放中"];
    CGFloat stateW = TFTextWidth(_stateText, 13, NO);
    TFDrawText(ctx, _stateText, kCanvasW - 24 - stateW, 26, 13, NO, playing ? green : dim);
    CGContextSetFillColorWithColor(ctx, playing ? green : dim);
    CGContextFillEllipseInRect(ctx, CGRectMake(kCanvasW - 24 - stateW - 14, 17, 6, 6));

    // 大数字：延迟
    TFDrawText(ctx, @"端到端延迟", 24, 58, 12, NO, dim);
    NSString *big = _latencyMs >= 0 ? [NSString stringWithFormat:@"%.0f", _latencyMs] : @"--";
    TFDrawText(ctx, big, 24, 132, 72, YES, white);
    CGFloat bigW = TFTextWidth(big, 72, YES);
    TFDrawText(ctx, @"ms", 24 + bigW + 8, 132, 22, NO, dim);

    // 缓冲 / 主机
    TFDrawText(ctx, [NSString stringWithFormat:@"缓冲 %.0fms", _backlogMs], 24, 170, 13, NO, body);
    TFDrawText(ctx, _hostText.length ? _hostText : @"--", 24, 194, 12, NO, dim);
    TFDrawTextRight(ctx, @"画中画 · 悬浮显示", kCanvasW - 24, 194, 12, NO, dim);

    // 电平条
    CGFloat barX = 24, barY = 216, barW = kCanvasW - 48, barH = 8;
    UIBezierPath *trackPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(barX, barY, barW, barH)
                                                             cornerRadius:barH / 2];
    CGContextSetFillColorWithColor(ctx, track);
    CGContextAddPath(ctx, trackPath.CGPath);
    CGContextFillPath(ctx);

    CGFloat lv = _level * 1.6f;
    if (lv > 1) lv = 1;
    if (lv < 0.02) lv = 0.02;
    UIBezierPath *fillPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(barX, barY, barW * lv, barH)
                                                           cornerRadius:barH / 2];
    CGContextSetFillColorWithColor(ctx, green);
    CGContextAddPath(ctx, fillPath.CGPath);
    CGContextFillPath(ctx);

    CGColorRelease(bg);
    CGColorRelease(dim);
    CGColorRelease(body);
    CGColorRelease(white);
    CGColorRelease(green);
    CGColorRelease(track);
}

- (void)enqueue {
    if (!_pixelBuffer || !_layer) return;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, _pixelBuffer, &fmt) != noErr) return;

    CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid };
    CMSampleBufferRef sbuf = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, _pixelBuffer,
                                                           fmt, &timing, &sbuf);
    CFRelease(fmt);
    if (st != noErr || !sbuf) return;

    if (_layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [_layer flush];
    }
    [_layer enqueueSampleBuffer:sbuf];
    CFRelease(sbuf);
}

#pragma mark - AVPictureInPictureSampleBufferPlaybackDelegate

// 返回无限时长的直播区间：系统据此隐藏进度条与快进按钮
- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)c {
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)c {
    return NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c setPlaying:(BOOL)playing {
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c
              didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c
                    skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler {
    if (completionHandler) completionHandler();
}

#pragma mark - AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)c {
    _isActive = YES;
    [self setRenderRate:kRateActive];
    [self renderFrame];
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)c {
    _isActive = YES;
    _pendingStart = NO;
    [_timeoutTimer invalidate];
    _timeoutTimer = nil;
    [self setRenderRate:kRateActive];
    NSLog(@"[tf] PiP 已启动");
    if (self.onStart) self.onStart();
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c
    failedToStartPictureInPictureWithError:(NSError *)error {
    _isActive = NO;
    _pendingStart = NO;
    [self setRenderRate:kRateWarm];
    NSLog(@"[tf] PiP 启动失败: %@", error.localizedDescription);
    if (self.onFail) self.onFail(error.localizedDescription ?: @"启动失败");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)c {
    _isActive = NO;
    [self setRenderRate:kRateWarm];
    NSLog(@"[tf] PiP 已关闭");
    if (self.onStop) self.onStop();
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    if (completionHandler) completionHandler(YES);
}

@end
