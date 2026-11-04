// audio-play.exe —— 独立播放器（开发期使用）。
//
// 正式版（Toneferry.exe）会复用宿主的 --mic-player 模式，电脑上不会额外
// 出现这个文件。这个独立版保留下来是为了在没有托盘宿主的环境里
// 单独验证「手机麦克风 → 电脑扬声器」这条链路。
package main

import (
	"fmt"
	"os"

	"toneferry/player"
)

func main() {
	if err := player.Run(os.Stdin); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
}
