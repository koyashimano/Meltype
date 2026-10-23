// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 koyashimano

import Cocoa
import Carbon.HIToolbox

/// メニューバーに、今の入力モード (自動・英数) を文字で出す。
/// 入力メニューのアイコンは M のままなので、別の項目として出す。入力ソースが Meltype のときのみ出す。
final class ModeStatusItem: NSObject {
    static let shared = ModeStatusItem()
    private var item: NSStatusItem?
    /// 本体が最後に返したモード。入力モードは本体がプロセスで 1 つ持つので、入力欄によらず同じ。
    private var mode = MacInputMode.japanese

    func start() {
        // IME は前面にならないので、すぐ届けるようにしないと、入力ソースを変えても通知が届かない。
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(inputSourceChanged(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
        update()
    }

    /// 本体が返したモードを出す。変わっていなければ何もしない。
    func show(_ mode: MacInputMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        update()
    }

    private func update() {
        let isMeltypeSelected = ModeServices.currentInputSourceIsMeltype()
        if item == nil {
            // 消して作り直すと位置が変わるので、一度作ったら表示・非表示を切り替えるのみにする。
            guard isMeltypeSelected else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "MeltypeInputMode"
            self.item = item
        }
        guard let item else { return }
        item.button?.title = mode == .japanese ? "自動" : "英数"
        item.button?.setAccessibilityLabel("Meltype の入力モード：" + mode.title)
        item.isVisible = isMeltypeSelected
    }

    @objc private func inputSourceChanged(_ notification: Notification) {
        update()
    }
}
