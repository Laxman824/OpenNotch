#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any Objective-C exception it raises.
/// Returns nil on success, or the exception's name + reason.
///
/// Swift cannot catch NSExceptions, and AVFoundation reports misuse (removing
/// a tap that isn't there, playing a node whose engine stopped, a format
/// mismatch after an audio-route change) by raising them — which would
/// otherwise abort the whole app.
NSString * _Nullable NBTry(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
