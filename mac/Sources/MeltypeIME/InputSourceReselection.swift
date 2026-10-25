// SPDX-License-Identifier: GPL-3.0-or-later AND MIT
// Copyright (C) 2026 koyashimano
//
// フォーカスのあるアプリに入力ソースの選択を頼む部分 (下の「macism の TSMUtils.swift をもとにしている」以降) は、
// macism (https://github.com/laishulu/macism) の TSMUtils.swift をもとにした。macism のライセンス:
//
//   MIT License
//   Copyright (c) 2023 https://github.com/laishulu
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
//   associated documentation files (the "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//   copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the
//   following conditions: The above copyright notice and this permission notice shall be included in all
//   copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT
//   LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
//   EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
//   IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
//   USE OR OTHER DEALINGS IN THE SOFTWARE.

import Carbon.HIToolbox
import Cocoa

/// フォーカスのないプロセス (herdr の switch_ascii_input_source_in_prefix など) が TISSelectInputSource で
/// Meltype に戻すと、macOS は先にシステム全体の入力ソースを Meltype にしてから、フォーカスのあるアプリに知らせる。
/// このとき、メニューバーは Meltype なのに、そのアプリの入力は英字のまま残ることがある (別のアプリに移って戻るまで直らない)。
/// ほかの入力ソースから Meltype に変わったのに、少し待っても入力欄で Meltype が有効にならなければ、残ったとみなす。
/// そのときは、入力メニューで選んだときと同じ経路で、フォーカスのあるアプリに ASCII の配列、Meltype の順に選び直してもらう。
/// (アプリの側ではもう Meltype が選ばれているので、Meltype だけを頼んでも何も変わらない)
/// 入力欄のない状態で Meltype を選んだときも有効にならないので、選び直す (メニューバーが一瞬 ABC になる)。
final class InputSourceReselection: NSObject {
    static let shared = InputSourceReselection()
    /// Meltype に変わってから、入力欄で Meltype が有効になるのを待つ時間。
    private static let settleDelay: TimeInterval = 0.15
    /// 選び直しても有効にならない (入力欄のないアプリなど) ときに、続けて選び直す回数の上限と、数え直すまでの時間。
    /// 通知の届く順によっては、選び直したあとにもう一度確かめるので、上限を設ける。
    private static let maxAttempts = 2
    private static let attemptsResetInterval: TimeInterval = 2
    private var wasMeltype = false
    private var attempts = 0
    private var lastAttempt = Date.distantPast
    private var pendingCheck: DispatchWorkItem?
    private let queue = DispatchQueue(label: "Meltype.InputSourceReselection")

    func start() {
        wasMeltype = ModeServices.currentInputSourceIsMeltype()
        // IME は前面にならないので、すぐ届けるようにしないと、入力ソースを変えても通知が届かない。
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(inputSourceChanged(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func inputSourceChanged(_ notification: Notification) {
        let isMeltype = ModeServices.currentInputSourceIsMeltype()
        defer { wasMeltype = isMeltype }
        // 入力ソースがまた変わったら、前の変更の確認は今の状態と合わないので取り消す。
        pendingCheck?.cancel()
        guard isMeltype, !wasMeltype else { return }
        let check = DispatchWorkItem { [weak self] in self?.reselectIfInactive() }
        pendingCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: check)
    }

    private func reselectIfInactive() {
        if Date().timeIntervalSince(lastAttempt) >= Self.attemptsResetInterval { attempts = 0 }
        guard !ModeServices.shared.hasActiveTarget else {
            attempts = 0
            return
        }
        guard attempts < Self.maxAttempts, ModeServices.currentInputSourceIsMeltype(),
              let meltype = Self.meltypeInputSource(),
              let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let request = Self.FocusedAppRequest(selecting: [ascii, meltype]) else { return }
        attempts += 1
        lastAttempt = Date()
        // 相手のアプリは Meltype の activateServer を待つことがあるので、メインスレッドで返事を待たない。
        queue.async {
            if !request.send() { NSLog("Meltype: フォーカスのあるアプリに、Meltype を選び直すよう頼めませんでした") }
        }
    }

    private static func meltypeInputSource() -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: InputSourceRegistration.japaneseIdentifier] as CFDictionary
        return (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first
    }

    // ---- 以下は macism の TSMUtils.swift をもとにしている ----
    // 非公開の関数を実行時に探す。見つからない・頼めないときは、何もしない。

    private typealias KeyFocusFunction = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<DarwinBoolean>) -> Int32
    private typealias ProcessIDFunction = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>) -> OSStatus
    private typealias RemotePortFunction = @convention(c) (CFAllocator?, CFString, pid_t) -> Unmanaged<CFMessagePort>?
    private typealias FlattenFunction = @convention(c) (TISInputSource, UnsafeMutablePointer<Unmanaged<AnyObject>?>) -> DarwinBoolean

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }

    /// キーを受けるプロセス (いちばん前のアプリとは限らない)。
    private static func keyFocusProcess() -> pid_t? {
        guard let keyFocus = symbol("CPSGetKeyFocusProcess", as: KeyFocusFunction.self),
              let processID = symbol("GetProcessPID", as: ProcessIDFunction.self) else { return nil }
        var psn = ProcessSerialNumber()
        var ignored: DarwinBoolean = false
        var pid: pid_t = -1
        guard keyFocus(&psn, &ignored) == 0, processID(&psn, &pid) == noErr, pid > 0 else { return nil }
        return pid
    }

    /// 入力メニューで選んだときと同じく、フォーカスのあるアプリの Text Services Manager に入力ソースの選択を頼む。
    /// 送り先と送る内容はメインスレッドで作り (TIS の関数を呼ぶため)、send は裏のスレッドで呼ぶ。
    /// 送り先は作ったときに 1 回だけ決めるので、途中でフォーカスが移っても、続けて頼む入力ソースが別のアプリに分かれない。
    private struct FocusedAppRequest {
        let port: CFMessagePort
        let messages: [CFData]

        init?(selecting sources: [TISInputSource]) {
            guard let remotePort = symbol("CFMessagePortCreatePerProcessRemote", as: RemotePortFunction.self),
                  let flatten = symbol("_CreateFlattenedInputSource", as: FlattenFunction.self),
                  let pid = keyFocusProcess(),
                  let port = remotePort(nil, "com.apple.tsm.portname" as CFString, pid)?.takeRetainedValue() else { return nil }
            var messages: [CFData] = []
            for source in sources {
                var flattened: Unmanaged<AnyObject>?
                guard flatten(source, &flattened).boolValue, let flat = flattened?.takeRetainedValue() else { return nil }
                let request = ["tsmInputSourceSelectedInpSrcKey": flat] as CFDictionary
                guard let data = CFPropertyListCreateData(nil, request, .xmlFormat_v1_0, 0, nil)?.takeRetainedValue() else { return nil }
                messages.append(data)
            }
            self.port = port
            self.messages = messages
        }

        /// 順に送る。返事が時間切れでも相手は遅れて切り替えることがあるので、途中で失敗しても最後まで送る
        /// (ASCII の配列で止めると、アプリが ABC のまま残る)。すべて受け付けられたら true。
        func send() -> Bool {
            messages.map { Self.send($0, to: port) }.allSatisfy { $0 }
        }

        private static func send(_ data: CFData, to port: CFMessagePort) -> Bool {
            var reply: Unmanaged<CFData>?
            let status = CFMessagePortSendRequest(port, 7, data, 0.3, 0.3, CFRunLoopMode.defaultMode.rawValue, &reply)
            guard status == kCFMessagePortSuccess else { return false }
            if let replyData = reply?.takeRetainedValue(),
               let dictionary = CFPropertyListCreateWithData(nil, replyData, 0, nil, nil)?.takeRetainedValue() as? [String: Any],
               let error = dictionary["tsmInputModeReplyToServerErrorKey"] as? Int, error != 0 {
                return false
            }
            return true
        }
    }
}
