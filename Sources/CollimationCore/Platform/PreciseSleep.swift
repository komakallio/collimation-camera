#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Windows)
import WinSDK
#endif
import Foundation

/// Sleeps for about `microseconds`, accurately enough for capture pacing and
/// mount pulses.
///
/// Foundation's `Thread.sleep(forTimeInterval:)` on Windows waits on a plain
/// waitable timer, so it is quantized to the process timer resolution —
/// 15.625 ms unless something called `timeBeginPeriod`. A 33 ms pacing sleep
/// then phase-locks to about 47 ms and a 200 µs poll becomes a 15.6 ms poll.
/// A high-resolution waitable timer avoids both.
public func preciseSleep(microseconds: Int) {
    guard microseconds > 0 else { return }
#if os(Windows)
    // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION (0x2) needs Windows 10 1803;
    // TIMER_ALL_ACCESS is STANDARD_RIGHTS_REQUIRED | SYNCHRONIZE | 0x3.
    guard let timer = CreateWaitableTimerExW(nil, nil, 0x0000_0002, 0x001F_0003) else {
        Thread.sleep(forTimeInterval: Double(microseconds) / 1_000_000)
        return
    }
    defer { CloseHandle(timer) }
    var dueTime = LARGE_INTEGER()
    // Negative 100 ns units means relative to now.
    dueTime.QuadPart = LONGLONG(-10 * microseconds)
    if SetWaitableTimer(timer, &dueTime, 0, nil, nil, false) == false {
        Thread.sleep(forTimeInterval: Double(microseconds) / 1_000_000)
        return
    }
    _ = WaitForSingleObject(timer, INFINITE)
#else
    usleep(UInt32(min(microseconds, Int(UInt32.max))))
#endif
}

/// Sleeps for about `milliseconds`.
public func preciseSleep(milliseconds: Int) {
    preciseSleep(microseconds: milliseconds * 1_000)
}
