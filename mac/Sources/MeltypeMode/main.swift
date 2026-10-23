// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 koyashimano
//
// Meltype の入力モードをコマンドから切り替える、小さな道具。Vim・Neovim の autocmd などから呼ぶ。
//   MeltypeMode automatic | direct | toggle
//
// Info.plist の NSServices に登録した「Meltype：…」のサービスを呼ぶのみで、切り替えは IME 本体 (ModeServices) が行う。
// 入力ソースで Meltype を選んでいないときは何も変わらない。
// サービスはメニューの名前で呼び分けるので、Info.plist の NSMenuItem を変えたらここも合わせる。

import Cocoa

let services = [
    "automatic": "Meltype：日本語・英語の自動判定",
    "direct": "Meltype：英数の直接入力",
    "toggle": "Meltype：日本語 ⇔ 英数",
]
guard CommandLine.arguments.count == 2, let service = services[CommandLine.arguments[1]] else {
    FileHandle.standardError.write("usage: MeltypeMode automatic|direct|toggle\n".data(using: .utf8)!)
    exit(2)
}
let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally() }
exit(NSPerformService(service, pasteboard) ? 0 : 1)
