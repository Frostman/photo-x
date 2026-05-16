#import "LibRawWrapper.h"
#import <libraw/libraw.h>
#import <os/log.h>

NSString *const LibRawErrorDomain = @"dev.frostman.PhotoX.LibRaw";

static os_log_t librawLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("dev.frostman.PhotoX", "libraw");
    });
    return log;
}

static NSError *makeError(int code, NSString *stage) {
    const char *msg = libraw_strerror(code);
    NSString *text = msg ? [NSString stringWithUTF8String:msg] : @"unknown";
    return [NSError errorWithDomain:LibRawErrorDomain
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:@"LibRaw %@ failed: %@ (%d)", stage, text, code]
                           }];
}

/// CGDataProvider releaseData callback. We pass the libraw_processed_image_t*
/// as `info`; it's freed via libraw_dcraw_clear_mem when the CGImage's data
/// provider is released.
static void librawReleaseProcessedImage(void *info, const void *data, size_t size) {
    libraw_dcraw_clear_mem((libraw_processed_image_t *)info);
}

@implementation LibRawWrapper

+ (NSString *)libRawVersion {
    const char *v = libraw_version();
    return v ? [NSString stringWithUTF8String:v] : @"unknown";
}

+ (CGImageRef)decodeImageAtURL:(NSURL *)url error:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        if (error) *error = makeError(-1, @"open_file");
        return NULL;
    }

    libraw_data_t *raw = libraw_init(0);
    if (!raw) {
        if (error) *error = makeError(-1, @"init");
        return NULL;
    }

    int ret = libraw_open_file(raw, [url.path UTF8String]);
    if (ret != LIBRAW_SUCCESS) {
        if (error) *error = makeError(ret, @"open_file");
        libraw_close(raw);
        return NULL;
    }

    ret = libraw_unpack(raw);
    if (ret != LIBRAW_SUCCESS) {
        if (error) *error = makeError(ret, @"unpack");
        libraw_close(raw);
        return NULL;
    }

    os_log(librawLog(),
           "camera: maker=%{public}s model=%{public}s raw=%dx%d",
           raw->idata.make, raw->idata.model,
           raw->sizes.raw_width, raw->sizes.raw_height);

    // Defaults: sRGB output, 16-bit, camera WB, no auto-brightness.
    // gamm[0]=1/2.4, gamm[1]=12.92 → sRGB-ish transfer.
    raw->params.output_bps = 16;
    raw->params.output_color = 1;     // 1 = sRGB
    raw->params.no_auto_bright = 1;
    raw->params.use_camera_wb = 1;
    raw->params.gamm[0] = 1.0 / 2.4;
    raw->params.gamm[1] = 12.92;
    raw->params.user_flip = -1;       // honor camera orientation

    // Match Sony's JPEG/HEIF crop so LibRaw output aligns with HEIF. Values
    // come from the ARW's DefaultCropOrigin / DefaultCropSize EXIF tags:
    // for the A1 II sample, (12, 12) + (8640, 5760). Not centered.
    // TODO: read DefaultCropOrigin/Size dynamically (via ExifTool or by
    // parsing the raw EXIF) so this works for all bodies; currently
    // hardcoded for A1/A1 II's 8704×6144 sensor.
    if (raw->sizes.iwidth == 8704 && raw->sizes.iheight == 6144) {
        raw->params.cropbox[0] = 12;
        raw->params.cropbox[1] = 12;
        raw->params.cropbox[2] = 8640;
        raw->params.cropbox[3] = 5760;
    }

    ret = libraw_dcraw_process(raw);
    if (ret != LIBRAW_SUCCESS) {
        if (error) *error = makeError(ret, @"dcraw_process");
        libraw_close(raw);
        return NULL;
    }

    int err = LIBRAW_SUCCESS;
    libraw_processed_image_t *img = libraw_dcraw_make_mem_image(raw, &err);
    if (!img || err != LIBRAW_SUCCESS) {
        if (error) *error = makeError(err, @"make_mem_image");
        if (img) libraw_dcraw_clear_mem(img);
        libraw_close(raw);
        return NULL;
    }

    os_log(librawLog(),
           "sizes: raw=%dx%d processed=%dx%d output=%dx%d margins=%d,%d  img=%ux%u data_size=%u (expected=%u)",
           raw->sizes.raw_width, raw->sizes.raw_height,
           raw->sizes.width, raw->sizes.height,
           raw->sizes.iwidth, raw->sizes.iheight,
           raw->sizes.left_margin, raw->sizes.top_margin,
           img->width, img->height, img->data_size,
           (unsigned)(img->width) * img->height * img->colors * (img->bits/8));

    if (img->type != LIBRAW_IMAGE_BITMAP || img->colors != 3 || img->bits != 16) {
        if (error) {
            NSString *desc = [NSString stringWithFormat:
                @"LibRaw returned unexpected format: type=%d colors=%d bits=%d",
                img->type, img->colors, img->bits];
            *error = [NSError errorWithDomain:LibRawErrorDomain code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        libraw_dcraw_clear_mem(img);
        libraw_close(raw);
        return NULL;
    }

    size_t width  = (size_t)img->width;
    size_t height = (size_t)img->height;
    size_t bytesPerRow = width * 3 * 2;  // RGB16 = 3 channels × 2 bytes

    CGDataProviderRef provider = CGDataProviderCreateWithData(
        img,                              // info → passed to release callback
        img->data,                        // pixel data
        (size_t)img->data_size,
        librawReleaseProcessedImage       // frees the libraw_processed_image_t
    );
    if (!provider) {
        if (error) *error = makeError(-3, @"data_provider");
        libraw_dcraw_clear_mem(img);
        libraw_close(raw);
        return NULL;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    // LibRaw writes 16-bit samples in HOST byte order (little-endian on
    // Apple Silicon). Tagging the CGImage with Big here was producing
    // byte-swapped noise.
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)((uint32_t)kCGImageByteOrder16Little
                                           | (uint32_t)kCGImageAlphaNone);

    CGImageRef cgImage = CGImageCreate(
        width,
        height,
        16,                               // bits per component
        48,                               // bits per pixel
        bytesPerRow,
        cs,
        bitmapInfo,
        provider,
        NULL,
        false,
        kCGRenderingIntentDefault
    );

    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);    // CGImage retains it
    libraw_close(raw);                   // processed_image_t is independent

    if (!cgImage && error) {
        *error = makeError(-4, @"CGImageCreate");
    }

    return cgImage;
}

@end
