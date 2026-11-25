// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
import Darwin
import Foundation

/// 在同一用户的应用数据目录上持有进程级互斥锁，防止多个实例同时修改上传历史。
enum MacInstanceLock {
    static let acquired = acquire(in: URL.applicationSupportDirectory.appending(path: "alioss4ios"))

    /// 成功时保留文件描述符至进程退出。锁文件留在原位，避免删除后两个进程锁住不同文件。
    static func acquire(in directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let descriptor = open(directory.appending(path: "instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        close(descriptor)
        return false
    }
}
#endif
