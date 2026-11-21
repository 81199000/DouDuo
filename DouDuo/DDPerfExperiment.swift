import Foundation

/// 性能对照实验开关（只在 DEBUG 生效）：DOUDUO_PERF_OFF=RING,AMBIENT,DANMAKU 关掉对应的逐帧工作，量 CPU 差多少
enum DDPerfExperiment {
    static func off(_ name: String) -> Bool {
        #if DEBUG
        return (ProcessInfo.processInfo.environment["DOUDUO_PERF_OFF"] ?? "").split(separator: ",").contains(Substring(name))
        #else
        return false
        #endif
    }
}
