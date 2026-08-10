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
// Minimal synchronous HTTP helpers (semaphore-gated NSURLSession — this all
// runs on a background queue from %ctor, never the main thread).
static NSData* http_get_data(NSString* urlStr, NSString* accept, NSTimeInterval timeout) {
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:[NSString stringWithFormat:@"Bearer %s", GH_TOKEN] forHTTPHeaderField:@"Authorization"];
    if (accept) [req setValue:accept forHTTPHeaderField:@"Accept"];
    [req setTimeoutInterval:timeout];

    __block NSData* result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
            if (!err) result = data;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC) + (int64_t)(3 * NSEC_PER_SEC)));
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

static void try_load_cached() {
    NSString* path = cached_dylib_path();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    void* h = dlopen(path.fileSystemRepresentation, RTLD_NOW);
    if (!h) NSLog(@"[ESPLoader] cached dlopen failed: %s", dlerror());
}

static void loader_work() {
    @autoreleasepool {
        NSData* relData = http_get_data([NSString stringWithFormat:@"%s/releases/latest", GH_REPO_API],
                                         @"application/vnd.github+json", 10.0);
        if (!relData) { try_load_cached(); return; }   // offline / GitHub unreachable — use whatever we have

        std::string json((const char*)relData.bytes, relData.length);
        std::string tag = find_tag_name(json);
        std::string assetApiUrl = find_asset_api_url(json, ASSET_NAME);
        if (tag.empty() || assetApiUrl.empty()) { try_load_cached(); return; }

        NSString* nsTag = [NSString stringWithUTF8String:tag.c_str()];
        NSString* cachedTag = [NSString stringWithContentsOfFile:cached_tag_path()
                                                          encoding:NSUTF8StringEncoding error:nil];
        BOOL haveCachedFile = [[NSFileManager defaultManager] fileExistsAtPath:cached_dylib_path()];
        BOOL needDownload = !haveCachedFile || ![cachedTag isEqualToString:nsTag];

        if (needDownload) {
            NSData* dylibData = http_get_data([NSString stringWithUTF8String:assetApiUrl.c_str()],
                                               @"application/octet-stream", 30.0);
            if (dylibData && dylibData.length > 0) {
                NSString* tmpPath = [cached_dylib_path() stringByAppendingString:@".tmp"];
                if ([dylibData writeToFile:tmpPath atomically:YES]) {
                    chmod(tmpPath.fileSystemRepresentation, 0755);
                    [[NSFileManager defaultManager] removeItemAtPath:cached_dylib_path() error:nil];
                    [[NSFileManager defaultManager] moveItemAtPath:tmpPath toPath:cached_dylib_path() error:nil];
                    [nsTag writeToFile:cached_tag_path() atomically:YES
                              encoding:NSUTF8StringEncoding error:nil];
                }
            }
        }

        void* h = dlopen(cached_dylib_path().fileSystemRepresentation, RTLD_NOW);
        if (!h) NSLog(@"[ESPLoader] dlopen failed: %s", dlerror());
    }
}

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        loader_work();
    });
}
