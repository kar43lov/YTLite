// WebClientSpoof.x — v3 prototype. Spoof ONLY the /player InnerTube client to WEB (web_safari),
// to test whether the signed-in app session gets a playable (HLS) response past the 1-minute
// Code14 wall. Nothing else changed: /browse,/next,search untouched; SPS not suppressed;
// hasCommonConfig not touched; response/Content-Type not forced. Logs = non-secret markers only.
//
// Exact values from the yt-dlp web_safari profile proven to serve media past a minute from this
// same account/network (desktop Safari UA, not iPad — no extra unproven variable).
//   clientName enum = 1 (WEB)   clientVersion = 2.20260708.00.00   UA = macOS Safari 15.5

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>

static const int        kWebClientNameEnum = 1;  // WEB
static NSString * const kWebClientVersion  = @"2.20260708.00.00";
static NSString * const kWebUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    @"(KHTML, like Gecko) Version/15.5 Safari/605.1.15";
static NSString * const kPlayerPath = @"/youtubei/v1/player";

// Markers go to stderr (reaches `devicectl ... --console`), NSLog, and a file in the app
// container (pulled later via `devicectl device copy from --domain-type appDataContainer`).
static void WSLogLine(NSString *line) {
    if (!line) return;
    fprintf(stderr, "%s\n", line.UTF8String);
    NSLog(@"%@", line);
    @try {
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (!dir) return;
        NSString *path = [dir stringByAppendingPathComponent:@"webspoof.log"];
        NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        else { [stamped writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
    } @catch (__unused NSException *e) {}
}
#define WSLOG(fmt, ...) WSLogLine([NSString stringWithFormat:(fmt), ##__VA_ARGS__])

// ---- request context: player-scoped concrete decorator (confirmed: ...Impl, decorateContext: v24@0:8@16) ----
%hook YTPlayerInnerTubeContextDecoratorImpl
- (void)decorateContext:(id)context {
    %orig;  // app builds its normal context (auth/visitor intact); then override client only
    @try {
        id client = [context valueForKey:@"client"];
        if (!client) { WSLOG(@"[WebSpoof] REQ: context has no client"); return; }
        // Hypothesis (not yet proven): `client` may be reused across requests, so mutating it in
        // place could poison /browse,/next. Work on a copy and swap it in; capture evidence below.
        id beforeName = [client valueForKey:@"clientName"];
        id beforeVer  = [client valueForKey:@"clientVersion"];
        id clientCopy = [client copy];
        BOOL distinctCopy = (clientCopy && clientCopy != client);
        if (!clientCopy) { WSLOG(@"[WebSpoof] REQ: client copy failed"); return; }
        [clientCopy setValue:@(kWebClientNameEnum) forKey:@"clientName"];
        [clientCopy setValue:kWebClientVersion     forKey:@"clientVersion"];
        [clientCopy setValue:kWebUserAgent          forKey:@"userAgent"];
        [context setValue:clientCopy forKey:@"client"];
        id after = [context valueForKey:@"client"];
        // original client's fields must be unchanged by our write (safe scalar/string snapshots)
        BOOL origUnchanged = [[client valueForKey:@"clientName"] isEqual:beforeName] &&
                             ([beforeVer isEqual:[client valueForKey:@"clientVersion"]] ||
                              (beforeVer == nil && [client valueForKey:@"clientVersion"] == nil));
        WSLOG(@"[WebSpoof] REQ before name=%@ ver=%@ | after name=%@ ver=%@ | distinctCopy=%d origUnchanged=%d",
              beforeName, beforeVer, [after valueForKey:@"clientName"], [after valueForKey:@"clientVersion"],
              distinctCopy, origUnchanged);
    } @catch (__unused NSException *e) { WSLOG(@"[WebSpoof] REQ decorate failed at setValue"); }
}
%end

// ---- /player HTTP headers: coordinate UA + numeric client, scoped to the exact player path+host ----
static const void *kWSHeadersDone = &kWSHeadersDone;

static void WSApplyPlayerHeaders(id fetcher) {
    @try {
        NSURLRequest *req = [fetcher valueForKey:@"request"];
        NSString *path = req.URL.path ?: @"";
        NSString *host = req.URL.host ?: @"";
        // strict domain boundary: exact host or dotted suffix, not "notyoutube.com"
        BOOL hostOK = [host isEqualToString:@"youtube.com"]    || [host hasSuffix:@".youtube.com"] ||
                      [host isEqualToString:@"googleapis.com"] || [host hasSuffix:@".googleapis.com"];
        BOOL isPlayer = [path isEqualToString:kPlayerPath] && hostOK;
        if (!isPlayer) return;
        if (objc_getAssociatedObject(fetcher, kWSHeadersDone)) return;  // idempotent across both beginFetch entries

        NSString *beforeUA = [req valueForHTTPHeaderField:@"User-Agent"];
        NSString *beforeCN = [req valueForHTTPHeaderField:@"X-Youtube-Client-Name"];
        WSLOG(@"[WebSpoof] HDR before /player host=%@ uaIsWeb=%d clientName=%@",
              host, [beforeUA isEqualToString:kWebUserAgent], beforeCN);

        ((void(*)(id,SEL,id,NSString *))objc_msgSend)(fetcher, @selector(setRequestValue:forHTTPHeaderField:), kWebUserAgent, @"User-Agent");
        ((void(*)(id,SEL,id,NSString *))objc_msgSend)(fetcher, @selector(setRequestValue:forHTTPHeaderField:), @"1", @"X-Youtube-Client-Name");
        ((void(*)(id,SEL,id,NSString *))objc_msgSend)(fetcher, @selector(setRequestValue:forHTTPHeaderField:), kWebClientVersion, @"X-Youtube-Client-Version");

        // readback by equality on the (possibly copied) current request, not intent
        NSURLRequest *after = [fetcher valueForKey:@"request"];
        BOOL uaOK  = [[after valueForHTTPHeaderField:@"User-Agent"] isEqualToString:kWebUserAgent];
        BOOL cnOK  = [[after valueForHTTPHeaderField:@"X-Youtube-Client-Name"] isEqualToString:@"1"];
        BOOL verOK = [[after valueForHTTPHeaderField:@"X-Youtube-Client-Version"] isEqualToString:kWebClientVersion];
        WSLOG(@"[WebSpoof] HDR readback uaOK=%d clientNameOK=%d versionOK=%d", uaOK, cnOK, verOK);
        // mark done only after confirmed success, so a failed first entry lets the second retry
        if (uaOK && cnOK && verOK)
            objc_setAssociatedObject(fetcher, kWSHeadersDone, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *e) { WSLOG(@"[WebSpoof] HDR hook failed"); }
}

%hook GTMSessionFetcher
- (void)beginFetchWithCompletionHandler:(id)handler {
    WSApplyPlayerHeaders(self);   // upstream: delegate-variant forwards here, but hook both idempotently
    %orig(handler);
}
- (void)beginFetchWithDelegate:(id)delegate didFinishSelector:(SEL)sel {
    WSApplyPlayerHeaders(self);
    %orig(delegate, sel);
}
%end

// ---- response snapshot: once, at the parsed player-response consumption point ----
static void WSLogResponse(id playerData) {
    @try {
        if (!playerData) { WSLOG(@"[WebSpoof] RESP: nil playerData"); return; }
        id ps = [playerData valueForKey:@"playabilityStatus"];
        id status = ps ? [ps valueForKey:@"status"] : nil;
        id sd = [playerData valueForKey:@"streamingData"];
        BOOL hasHls = sd ? [[sd valueForKey:@"hasHlsManifestURL"] boolValue] : NO;
        id hlsN = sd ? [sd valueForKey:@"hlsFormatsArray_Count"] : nil;        // counts without materialising arrays
        id adaN = sd ? [sd valueForKey:@"adaptiveFormatsArray_Count"] : nil;
        WSLOG(@"[WebSpoof] RESP status=%@ hasHLS=%d hlsFormats=%@ adaptive=%@", status, hasHls, hlsN, adaN);
    } @catch (__unused NSException *e) { WSLOG(@"[WebSpoof] RESP snapshot failed"); }
}

%hook YTPlayerResponse
// trailer: is BOOL (encoding B48), not id — ABI must match
- (id)initWithPlayerData:(id)playerData responseDate:(id)d offlineStateDate:(id)o
       mutableState:(id)m trailer:(BOOL)t {
    WSLogResponse(playerData);
    return %orig;
}
- (id)initWithPlayerData:(id)playerData responseDate:(id)d offlineStateDate:(id)o
       mutableState:(id)m trailer:(BOOL)t offlineRentalActivated:(BOOL)ora {
    WSLogResponse(playerData);
    return %orig;
}
- (id)initWithPlayerData:(id)playerData responseDate:(id)d offlineStateDate:(id)o
       mutableState:(id)m trailer:(BOOL)t QOEController:(id)q cacheKey:(id)ck cacheContext:(id)cc
       latencyLogger:(id)ll offlineRentalActivated:(BOOL)ora {
    WSLogResponse(playerData);
    return %orig;
}
%end

// ---- ctor: confirm classes AND the exact selectors/targets exist in this build ----
%ctor {
    fprintf(stderr, "[WebSpoof] ctor reached\n");  // raw marker before any ObjC/NSString work
    Class dec   = objc_getClass("YTPlayerInnerTubeContextDecoratorImpl");
    Class resp  = objc_getClass("YTPlayerResponse");
    Class fetch = objc_getClass("GTMSessionFetcher");
    WSLOG(@"[WebSpoof] ctor classes: decoratorImpl=%d response=%d fetcher=%d clientInfo=%d",
          dec != nil, resp != nil, fetch != nil, objc_getClass("YTIClientInfo") != nil);
    WSLOG(@"[WebSpoof] ctor selectors: decorate=%d respShort=%d respRental=%d respLong=%d fetchCompletion=%d fetchDelegate=%d setHdr=%d",
          [dec instancesRespondToSelector:@selector(decorateContext:)],
          [resp instancesRespondToSelector:@selector(initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:)],
          [resp instancesRespondToSelector:@selector(initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:offlineRentalActivated:)],
          [resp instancesRespondToSelector:@selector(initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:QOEController:cacheKey:cacheContext:latencyLogger:offlineRentalActivated:)],
          [fetch instancesRespondToSelector:@selector(beginFetchWithCompletionHandler:)],
          [fetch instancesRespondToSelector:@selector(beginFetchWithDelegate:didFinishSelector:)],
          [fetch instancesRespondToSelector:@selector(setRequestValue:forHTTPHeaderField:)]);
}
