// Blockpost ESP Loader — NeqYaRialnyOG & Nyx
//
// Installed ONCE via Sileo. On every game launch it checks GitHub for the
// latest ESP release, downloads the raw dylib if it changed, and dlopen()s
// it — so future ESP updates never require reinstalling a .deb again.
//
// IMPORTANT: once this loader is confirmed working, uninstall the regular
// "Blockpost 2D Box ESP" package from Sileo — leaving both installed means
// Substrate loads the old one AND this loader dlopen()s a (possibly newer)
// copy, double-injecting everything.
//
// DIAGNOSTIC BUILD: shows a small on-screen status line (top of screen, non-
// interactive, auto-hides after ~20s) tracking every step, and copies the
// full log to the pasteboard when it finishes either way — paste it back if
// something's not working so the failure point is visible instead of guessed.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <string>

// Read-only, single-repo-scoped fine-grained PAT (Contents: Read-only on
// babaespchai only). Injected at BUILD TIME from the GitHub Actions secret
// LOADER_TOKEN (see Makefile / build.yml) — never committed to source, so it
// never enters git history and GitHub's push-protection secret scanner has
// nothing to catch. If it ever needs rotating: update the LOADER_TOKEN repo
// secret and cut a new loader release; no source change needed.
#ifndef GH_TOKEN
#error "GH_TOKEN must be supplied at compile time (-DGH_TOKEN=\"...\"), see Makefile"
#endif
#define GH_REPO_API "https://api.github.com/repos/NegYaRialnyOG/babaespchai"
#define ASSET_NAME  "BlockpostESP.dylib"

// ---------------------------------------------------------------------------
// Tiny non-interactive status overlay — plain UIKit, no dependency on the
// payload's own ImGui/Metal stack, so it works even if the payload never
// loads at all. hitTest always returns nil so it can never block game touches.
@interface ESPLoaderStatusWindow : UIWindow
@end
@implementation ESPLoaderStatusWindow
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e { return nil; }
@end

static ESPLoaderStatusWindow* g_statusWindow = nil;
static UILabel* g_statusLabel = nil;
static NSMutableString* g_log = nil;

static void loader_log(NSString* fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString* line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[ESPLoader] %@", line);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_log) g_log = [NSMutableString new];
        [g_log appendFormat:@"%@\n", line];
        [UIPasteboard generalPasteboard].string = g_log;   // always current, paste any time

        if (!g_statusWindow) {
            CGRect b = [UIScreen mainScreen].bounds;
            g_statusWindow = [[ESPLoaderStatusWindow alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 30)];
            g_statusWindow.windowLevel = UIWindowLevelStatusBar + 2000;
            g_statusWindow.backgroundColor = [UIColor clearColor];
            g_statusWindow.rootViewController = [UIViewController new];
            g_statusWindow.rootViewController.view = [[UIView alloc] initWithFrame:g_statusWindow.bounds];
            g_statusWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
            g_statusWindow.hidden = NO;

            g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, b.size.width - 16, 22)];
            g_statusLabel.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.4 alpha:1.0];
            g_statusLabel.font = [UIFont boldSystemFontOfSize:12];
            g_statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
            g_statusLabel.numberOfLines = 1;
            g_statusLabel.adjustsFontSizeToFitWidth = YES;
            [g_statusWindow.rootViewController.view addSubview:g_statusLabel];
        }
        g_statusLabel.text = [@"[ESPLoader] " stringByAppendingString:line];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            g_statusWindow.hidden = YES;
        });
    });
}

// ---------------------------------------------------------------------------
// Minimal synchronous HTTP helpers (semaphore-gated NSURLSession — this all
// runs on a background queue from %ctor, never the main thread).
static NSData* http_get_data(NSString* urlStr, NSString* accept, NSTimeInterval timeout, NSInteger* outStatus, NSString* stepName) {
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:[NSString stringWithFormat:@"Bearer %s", GH_TOKEN] forHTTPHeaderField:@"Authorization"];
    if (accept) [req setValue:accept forHTTPHeaderField:@"Accept"];
    [req setTimeoutInterval:timeout];

    __block NSData* result = nil;
    __block NSInteger status = -1;
    __block NSString* errDesc = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) status = ((NSHTTPURLResponse*)resp).statusCode;
            if (err) errDesc = err.localizedDescription;
            if (!err) result = data;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC) + (int64_t)(3 * NSEC_PER_SEC)));
    if (outStatus) *outStatus = status;
    if (waited != 0) {
        loader_log(@"%@: TIMED OUT", stepName);
    } else if (!result) {
        loader_log(@"%@: FAILED http=%ld err=%@", stepName, (long)status, errDesc ?: @"?");
    } else {
        loader_log(@"%@: ok http=%ld bytes=%lu", stepName, (long)status, (unsigned long)result.length);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tiny hand-rolled scan of GitHub's release JSON — no JSON library needed for
// two fixed-shape lookups. Verified against the real API response shape:
// "tag_name": "..." at the top level, and each entry in "assets" has its own
// "url" (the API url to hit for downloading THAT asset) immediately before
// its "name".
static std::string json_find_after(const std::string& json, const std::string& key, size_t from = 0) {
    size_t pos = json.find(key, from);
    if (pos == std::string::npos) return "";
    size_t start = pos + key.size();
    size_t end = json.find("\"", start);
    if (end == std::string::npos) return "";
    return json.substr(start, end - start);
}

static std::string find_tag_name(const std::string& json) {
    return json_find_after(json, "\"tag_name\": \"");
}

// Returns the asset's own API "url" (the one that must be hit with
// Accept: application/octet-stream to actually download it — the plain
// browser_download_url doesn't work headlessly for a private repo).
static std::string find_asset_api_url(const std::string& json, const std::string& wantName) {
    std::string nameNeedle = "\"name\": \"" + wantName + "\"";
    size_t namePos = json.find(nameNeedle);
    if (namePos == std::string::npos) return "";
    size_t urlKeyPos = json.rfind("\"url\": \"", namePos);
    if (urlKeyPos == std::string::npos) return "";
    return json_find_after(json, "\"url\": \"", urlKeyPos);
}

// ---------------------------------------------------------------------------
static NSString* cached_dylib_path() {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/BlockpostESP_loaded.dylib"];
}
static NSString* cached_tag_path() {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/esp_loader_tag.txt"];
}

static void try_load_cached(NSString* reason) {
    NSString* path = cached_dylib_path();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        loader_log(@"%@ — no cached dylib either, nothing to load", reason);
        return;
    }
    loader_log(@"%@ — falling back to cached dylib", reason);
    void* h = dlopen(path.fileSystemRepresentation, RTLD_NOW);
    loader_log(@"cached dlopen: %@ (%s)", h ? @"OK" : @"FAILED", h ? "" : dlerror());
}

static void loader_work() {
    @autoreleasepool {
        loader_log(@"start");
        NSInteger status = 0;
        NSData* relData = http_get_data([NSString stringWithFormat:@"%s/releases/latest", GH_REPO_API],
                                         @"application/vnd.github+json", 10.0, &status, @"fetch releases/latest");
        if (!relData) { try_load_cached(@"releases/latest fetch failed"); return; }

        std::string json((const char*)relData.bytes, relData.length);
        std::string tag = find_tag_name(json);
        std::string assetApiUrl = find_asset_api_url(json, ASSET_NAME);
        loader_log(@"tag=%s assetUrl=%s", tag.empty() ? "?" : tag.c_str(), assetApiUrl.empty() ? "NOT FOUND" : assetApiUrl.c_str());
        if (tag.empty() || assetApiUrl.empty()) { try_load_cached(@"tag/asset parse failed"); return; }

        NSString* nsTag = [NSString stringWithUTF8String:tag.c_str()];
        NSString* cachedTag = [NSString stringWithContentsOfFile:cached_tag_path()
                                                          encoding:NSUTF8StringEncoding error:nil];
        BOOL haveCachedFile = [[NSFileManager defaultManager] fileExistsAtPath:cached_dylib_path()];
        BOOL needDownload = !haveCachedFile || ![cachedTag isEqualToString:nsTag];
        loader_log(@"cachedTag=%@ haveCachedFile=%d needDownload=%d", cachedTag ?: @"(none)", haveCachedFile, needDownload);

        if (needDownload) {
            NSData* dylibData = http_get_data([NSString stringWithUTF8String:assetApiUrl.c_str()],
                                               @"application/octet-stream", 30.0, &status, @"download dylib");
            if (dylibData && dylibData.length > 0) {
                NSString* tmpPath = [cached_dylib_path() stringByAppendingString:@".tmp"];
                BOOL wrote = [dylibData writeToFile:tmpPath atomically:YES];
                loader_log(@"write tmp: %@", wrote ? @"ok" : @"FAILED");
                if (wrote) {
                    chmod(tmpPath.fileSystemRepresentation, 0755);
                    [[NSFileManager defaultManager] removeItemAtPath:cached_dylib_path() error:nil];
                    NSError* mvErr = nil;
                    BOOL moved = [[NSFileManager defaultManager] moveItemAtPath:tmpPath toPath:cached_dylib_path() error:&mvErr];
                    loader_log(@"move into place: %@ %@", moved ? @"ok" : @"FAILED", mvErr.localizedDescription ?: @"");
                    [nsTag writeToFile:cached_tag_path() atomically:YES
                              encoding:NSUTF8StringEncoding error:nil];
                }
            } else {
                loader_log(@"download produced no data");
            }
        }

        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:cached_dylib_path()];
        loader_log(@"cached dylib exists=%d path=%@", exists, cached_dylib_path());
        void* h = dlopen(cached_dylib_path().fileSystemRepresentation, RTLD_NOW);
        loader_log(@"dlopen: %@ (%s)", h ? @"SUCCESS" : @"FAILED", h ? "" : dlerror());
    }
}

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        loader_work();
    });
}
