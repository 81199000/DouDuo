#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 执行 block，接住里面抛出的 Objective-C 异常（Swift 自己接不住，会直接闪退）。
/// 返回 YES = 正常跑完；NO = 抛了异常，reason 带回异常说明。
/// 用途：VLCKit 的 saveVideoSnapshotAt: 截不到图时直接 @throw。
BOOL DDTryObjC(NS_NOESCAPE void (^block)(void), NSString * _Nullable * _Nullable reason);

NS_ASSUME_NONNULL_END
