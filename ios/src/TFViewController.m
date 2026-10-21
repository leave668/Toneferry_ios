//
//  TFViewController.m
//

#import "TFViewController.h"
#import "TFPlayer.h"
#import "TFPiPController.h"

@interface TFViewController () <TFPlayerDelegate, UITextFieldDelegate>
@end

@implementation TFViewController {
    UILabel *_titleLabel;
    UILabel *_subLabel;
    UITextField *_hostField;
    UIButton *_startButton;
    UIButton *_stopButton;
    UILabel *_statusLabel;
    UILabel *_statsLabel;
    UIView *_levelTrack;
    UIView *_levelFill;
    UILabel *_diagLabel;
    UISegmentedControl *_latencySegment;
    UILabel *_hintLabel;
    UIButton *_pipButton;
    UIView *_pipHostView;
    TFPiPController *_pipController;
    TFPlayer *_player;
    CGFloat _fillRatio;
    float _lastLevel;
    unsigned long long _prevDropped;
}

static const NSInteger kLatencyOptions[3] = {80, 120, 200};
static NSString *const kLatencyKey = @"tf.latency";

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.059 green:0.059 blue:0.137 alpha:1.0];

    // 画中画的宿主：2x2 放在屏幕角落，只为了让 AVSampleBufferDisplayLayer 挂在窗口里
    _pipHostView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 2, 2)];
    _pipHostView.backgroundColor = [UIColor blackColor];
    _pipHostView.userInteractionEnabled = NO;
    [self.view addSubview:_pipHostView];

    _titleLabel = [self labelWithSize:30 weight:UIFontWeightBold color:[UIColor whiteColor]];
    _titleLabel.text = @"Toneferry";

    _subLabel = [self labelWithSize:13 weight:UIFontWeightRegular
                              color:[UIColor colorWithRed:0.58 green:0.64 blue:0.72 alpha:1.0]];
    _subLabel.text = @"PC 系统音频 · 锁屏继续播放";

    _hostField = [[UITextField alloc] init];
    _hostField.backgroundColor = [UIColor colorWithRed:0.106 green:0.106 blue:0.188 alpha:1.0];
    _hostField.textColor = [UIColor whiteColor];
    _hostField.tintColor = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0];
    _hostField.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _hostField.layer.cornerRadius = 12;
    _hostField.layer.borderWidth = 1;
    _hostField.layer.borderColor = [UIColor colorWithRed:0.19 green:0.18 blue:0.5 alpha:0.8].CGColor;
    _hostField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _hostField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _hostField.autocorrectionType = UITextAutocorrectionTypeNo;
    _hostField.returnKeyType = UIReturnKeyDone;
    _hostField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _hostField.placeholder = @"电脑地址，例如 192.168.0.80:3088";
    _hostField.delegate = self;
    _hostField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    _hostField.leftViewMode = UITextFieldViewModeAlways;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"tf.host"];
    _hostField.text = saved.length ? saved : @"";
    [self.view addSubview:_hostField];

    _startButton = [self buttonWithTitle:@"开始收听"
                                  color:[UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0]
                                textColor:[UIColor colorWithRed:0.059 green:0.09 blue:0.16 alpha:1.0]];
    [_startButton addTarget:self action:@selector(onStart) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_startButton];

    _stopButton = [self buttonWithTitle:@"停止"
                                  color:[UIColor colorWithRed:0.153 green:0.153 blue:0.231 alpha:1.0]
                              textColor:[UIColor whiteColor]];
    [_stopButton addTarget:self action:@selector(onStop) forControlEvents:UIControlEventTouchUpInside];
    _stopButton.enabled = NO;
    _stopButton.alpha = 0.45;
    [self.view addSubview:_stopButton];

    _pipButton = [self buttonWithTitle:@"悬浮窗"
                                 color:[UIColor colorWithRed:0.153 green:0.153 blue:0.231 alpha:1.0]
                             textColor:[UIColor whiteColor]];
    _pipButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_pipButton addTarget:self action:@selector(onPiP) forControlEvents:UIControlEventTouchUpInside];
    _pipButton.enabled = NO;
    _pipButton.alpha = 0.45;
    [self.view addSubview:_pipButton];

    _statusLabel = [self labelWithSize:15 weight:UIFontWeightMedium color:[UIColor whiteColor]];
    _statusLabel.text = @"未连接";
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_statusLabel];

    _statsLabel = [self labelWithSize:12 weight:UIFontWeightRegular
                                color:[UIColor colorWithRed:0.58 green:0.64 blue:0.72 alpha:1.0]];
    _statsLabel.text = @"缓冲 0.00s";
    _statsLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_statsLabel];

    _levelTrack = [[UIView alloc] init];
    _levelTrack.backgroundColor = [UIColor colorWithRed:0.153 green:0.153 blue:0.231 alpha:1.0];
    _levelTrack.layer.cornerRadius = 3;
    _levelTrack.clipsToBounds = YES;
    [self.view addSubview:_levelTrack];

    _levelFill = [[UIView alloc] init];
    _levelFill.backgroundColor = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0];
    _levelFill.layer.cornerRadius = 3;
    [_levelTrack addSubview:_levelFill];

    _diagLabel = [self labelWithSize:11 weight:UIFontWeightRegular
                               color:[UIColor colorWithRed:0.42 green:0.47 blue:0.56 alpha:1.0]];
    _diagLabel.text = @"延迟 --ms · 包 --/s";
    _diagLabel.textAlignment = NSTextAlignmentCenter;
    _diagLabel.numberOfLines = 3;
    [self.view addSubview:_diagLabel];

    _latencySegment = [[UISegmentedControl alloc] initWithItems:@[@"低延迟", @"均衡", @"稳定"]];
    _latencySegment.selectedSegmentIndex = [self savedLatencyIndex];
    _latencySegment.tintColor = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0];
    if (@available(iOS 13.0, *)) {
        _latencySegment.selectedSegmentTintColor = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0];
    }
    NSDictionary *normalAttr = @{
        NSForegroundColorAttributeName: [UIColor colorWithRed:0.72 green:0.76 blue:0.84 alpha:1.0],
        NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightMedium],
    };
    [_latencySegment setTitleTextAttributes:normalAttr forState:UIControlStateNormal];
    [_latencySegment addTarget:self action:@selector(onLatencyChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_latencySegment];

    _hintLabel = [self labelWithSize:11 weight:UIFontWeightRegular
                               color:[UIColor colorWithRed:0.45 green:0.51 blue:0.6 alpha:1.0]];
    _hintLabel.text = @"首次连接请允许「本地网络」权限。\n锁屏/切后台后音频继续，可用锁屏控件暂停。";
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.numberOfLines = 0;
    [self.view addSubview:_hintLabel];

    _player = [[TFPlayer alloc] init];
    _player.delegate = self;
    _player.host = _hostField.text;
    _player.targetLatencyMs = kLatencyOptions[[self savedLatencyIndex]];

    _pipController = [[TFPiPController alloc] initWithHostView:_pipHostView];
    __weak typeof(self) weakSelf = self;
    // 三个回调驱动按钮文案，不再靠延时猜状态
    _pipController.onStart = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            TFViewController *s = weakSelf;
            if (!s) return;
            [s->_pipButton setTitle:@"关闭浮窗" forState:UIControlStateNormal];
        });
    };
    _pipController.onStop = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            TFViewController *s = weakSelf;
            if (!s) return;
            [s->_pipButton setTitle:@"悬浮窗" forState:UIControlStateNormal];
        });
    };
    _pipController.onFail = ^(NSString *reason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TFViewController *s = weakSelf;
            if (!s) return;
            [s->_pipButton setTitle:@"悬浮窗" forState:UIControlStateNormal];
            // 没在播放时系统不会把 PiP 标成就绪，直接把下一步告诉用户
            BOOL idle = s->_player.state != TFPlayerStatePlaying;
            s->_statusLabel.text = idle
                ? @"画中画需先有音频：请点「开始收听」，再开悬浮窗"
                : [NSString stringWithFormat:@"画中画不可用：%@", reason];
        });
    };
    // 关键：提前建好 layer / controller 并开始预热，
    // 否则首次点击时 isPictureInPicturePossible 还是 NO，点了没反应
    [_pipController prepare];
}

- (NSInteger)savedLatencyIndex {
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:kLatencyKey];
    if (v < 0 || v > 2) return 1;
    return v;
}

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.textAlignment = NSTextAlignmentCenter;
    return l;
}

- (UIButton *)buttonWithTitle:(NSString *)title color:(UIColor *)color textColor:(UIColor *)textColor {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:textColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    b.backgroundColor = color;
    b.layer.cornerRadius = 14;
    return b;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat pad = 24;
    CGFloat contentW = w - pad * 2;
    CGFloat y = self.view.safeAreaInsets.top + 40;

    _titleLabel.frame = CGRectMake(pad, y, contentW, 38);
    y += 44;
    _subLabel.frame = CGRectMake(pad, y, contentW, 20);
    y += 34;
    _hostField.frame = CGRectMake(pad, y, contentW, 52);
    y += 64;
    _startButton.frame = CGRectMake(pad, y, contentW, 52);
    y += 60;
    _stopButton.frame = CGRectMake(pad, y, (contentW - 12) / 2, 44);
    _pipButton.frame = CGRectMake(pad + (contentW - 12) / 2 + 12, y, (contentW - 12) / 2, 44);
    y += 56;
    _statusLabel.frame = CGRectMake(pad, y, contentW, 22);
    y += 26;
    _statsLabel.frame = CGRectMake(pad, y, contentW, 18);
    y += 24;
    _levelTrack.frame = CGRectMake(pad, y, contentW, 6);
    _levelFill.frame = CGRectMake(0, 0, contentW * _fillRatio, 6);
    y += 22;
    _diagLabel.frame = CGRectMake(pad, y, contentW, 46);
    y += 54;
    _latencySegment.frame = CGRectMake(pad, y, contentW, 32);

    // 宿主贴到屏幕最底部，2x2 基本不可见
    _pipHostView.frame = CGRectMake(0, self.view.bounds.size.height - 2, 2, 2);

    CGFloat hintH = 36;
    CGFloat hintY = self.view.bounds.size.height - self.view.safeAreaInsets.bottom - hintH - 12;
    _hintLabel.frame = CGRectMake(pad, hintY, contentW, hintH);
}

#pragma mark - 交互

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)onLatencyChanged {
    NSInteger idx = _latencySegment.selectedSegmentIndex;
    if (idx < 0 || idx > 2) idx = 1;
    [[NSUserDefaults standardUserDefaults] setInteger:idx forKey:kLatencyKey];
    _player.targetLatencyMs = kLatencyOptions[idx];
}

- (void)onStart {
    NSString *host = [_hostField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (host.length == 0) {
        _statusLabel.text = @"请先填写电脑地址";
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:host forKey:@"tf.host"];
    _player.host = host;
    _player.targetLatencyMs = kLatencyOptions[[self savedLatencyIndex]];
    [_hostField resignFirstResponder];

    _startButton.enabled = NO;
    _startButton.alpha = 0.45;
    _stopButton.enabled = YES;
    _stopButton.alpha = 1.0;
    _pipButton.enabled = YES;
    _pipButton.alpha = 1.0;
    [_player start];
}

- (void)onStop {
    [_pipController stop];
    [_pipButton setTitle:@"悬浮窗" forState:UIControlStateNormal];
    _pipButton.enabled = NO;
    _pipButton.alpha = 0.45;
    [_player stop];
    _startButton.enabled = YES;
    _startButton.alpha = 1.0;
    _stopButton.enabled = NO;
    _stopButton.alpha = 0.45;
    _fillRatio = 0;
    _levelFill.frame = CGRectMake(0, 0, _levelTrack.bounds.size.width, 6);
    _statsLabel.text = @"缓冲 0.00s";
    _diagLabel.text = @"延迟 --ms · 包 --/s";
}

- (void)onPiP {
    if (_pipController.isActive) {
        [_pipController stop];
        return;
    }
    [_pipButton setTitle:@"启动中…" forState:UIControlStateNormal];
    [_pipController start];
}

#pragma mark - TFPlayerDelegate

- (void)player:(TFPlayer *)player didChangeState:(TFPlayerState)state detail:(NSString *)detail {
    _statusLabel.text = detail.length ? detail : @"";
    switch (state) {
        case TFPlayerStateIdle:
            _statusLabel.textColor = [UIColor colorWithRed:0.58 green:0.64 blue:0.72 alpha:1.0];
            break;
        case TFPlayerStateFailed:
            _statusLabel.textColor = [UIColor colorWithRed:0.94 green:0.27 blue:0.27 alpha:1.0];
            _startButton.enabled = YES;
            _startButton.alpha = 1.0;
            _stopButton.enabled = NO;
            _stopButton.alpha = 0.45;
            break;
        case TFPlayerStatePlaying:
            _statusLabel.textColor = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0];
            break;
        default:
            _statusLabel.textColor = [UIColor whiteColor];
            break;
    }
}

- (void)player:(TFPlayer *)player didUpdateStats:(double)bufferedSeconds level:(float)level {
    _lastLevel = level;
    _statsLabel.text = [NSString stringWithFormat:@"缓冲 %.2fs", bufferedSeconds];
    CGFloat ratio = level * 1.6;
    if (ratio > 1) ratio = 1;
    if (ratio < 0) ratio = 0;
    _fillRatio = ratio;
    CGRect f = _levelFill.frame;
    f.size.width = _levelTrack.bounds.size.width * ratio;
    _levelFill.frame = f;
}

- (void)player:(TFPlayer *)player didUpdateDiagnostics:(NSDictionary<NSString *, NSNumber *> *)diag {
    double latency = [diag[@"latencyMs"] doubleValue];
    double backlog = [diag[@"backlogMs"] doubleValue];
    double outMs = [diag[@"inFlightMs"] doubleValue];
    double pps = [diag[@"packetRate"] doubleValue];
    unsigned long long dropped = [diag[@"dropped"] unsignedLongLongValue];
    unsigned long long underruns = [diag[@"underruns"] unsignedLongLongValue];
    unsigned long long dup = [diag[@"duplicates"] unsignedLongLongValue];

    // 丢帧速率（统计窗口 250ms）：持续丢帧会把波形切碎，听感就是沙哑
    unsigned long long delta = dropped >= _prevDropped ? dropped - _prevDropped : 0;
    _prevDropped = dropped;
    double dropRate = delta * 4.0;

    NSMutableString *line1 = [NSMutableString stringWithFormat:
        @"延迟约 %.0fms（积压 %.0f + 输出 %.0f）", latency, backlog, outMs];
    if (pps > 150) {
        [line1 appendString:@"  ⚠ 包速率异常"];
    }

    NSMutableString *line2 = [NSMutableString stringWithFormat:
        @"下行 %.0f 包/s · 丢 %llu 帧 · 欠载 %llu", pps, dropped, underruns];
    if (dropRate > 500) {
        [line2 appendFormat:@" · 丢帧 %.0f/s", dropRate];
    }
    if (dup > 0) {
        [line2 appendFormat:@" · 重复包 %llu", dup];
    }
    _diagLabel.text = [NSString stringWithFormat:@"%@\n%@", line1, line2];

    // 同步给悬浮窗，浮窗内容与主界面读数保持一致
    [_pipController updateLatencyMs:latency
                          backlogMs:backlog
                              level:_lastLevel
                          stateText:_statusLabel.text ?: @""
                               host:_hostField.text ?: @""];

    if (pps > 150) {
        // 包速率翻倍基本可以断定服务端重复广播
        _diagLabel.textColor = [UIColor colorWithRed:0.94 green:0.63 blue:0.2 alpha:1.0];
    } else if (dropRate > 500 || underruns > 0) {
        // 正在丢帧 / 欠载：波形被打断，声音会发沙
        _diagLabel.textColor = [UIColor colorWithRed:0.85 green:0.45 blue:0.35 alpha:1.0];
    } else {
        _diagLabel.textColor = [UIColor colorWithRed:0.42 green:0.47 blue:0.56 alpha:1.0];
    }
}

@end
