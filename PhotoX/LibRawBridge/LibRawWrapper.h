#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const LibRawErrorDomain;

@interface LibRawWrapper : NSObject

/// Decodes a RAW (.ARW etc.) file via LibRaw into an sRGB 16-bpc CGImage.
/// Returns nil on failure and populates `error`.
/// Caller takes ownership of the returned CGImage (CF_RETURNS_RETAINED).
+ (nullable CGImageRef)decodeImageAtURL:(NSURL *)url
                                  error:(NSError **)error CF_RETURNS_RETAINED;

/// LibRaw version string (e.g. "0.22.1-Release").
+ (NSString *)libRawVersion;

@end

NS_ASSUME_NONNULL_END
