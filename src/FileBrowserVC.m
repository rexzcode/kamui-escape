#import "FileBrowserVC.h"
#import "AppsListVC.h"
#import "BQCore.h"
#import "BQUI.h"
#import <sys/stat.h>

// ---------------------------------------------------------------- BQLease ---
// Resolves a path to something NSFileManager can touch. If the sandbox already
// allows the path, linkPath == realPath and handle == -1. Otherwise we hold a
// sandbox-extension lease from BQEscape for as long as the lease is alive.
@interface BQLease : NSObject
@property (nonatomic, copy)   NSString *realPath;
@property (nonatomic, copy)   NSString *linkPath;
@property (nonatomic, assign) int64_t   handle;
@property (nonatomic, assign) BOOL      escaped;
+ (instancetype)leaseForPath:(NSString *)path;
- (NSString *)resolveSubpath:(NSString *)name;
- (void)close;
@end

@implementation BQLease
+ (instancetype)leaseForPath:(NSString *)path {
    BQLease *l = [BQLease new];
    l.realPath = path;
    l.handle = -1;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
        // Direct access — try listing (dirs) or stat (files) without escape.
        if (isDir) {
            NSError *e = nil;
            [fm contentsOfDirectoryAtPath:path error:&e];
            if (!e) { l.linkPath = path; return l; }
        } else {
            if ([fm isReadableFileAtPath:path]) { l.linkPath = path; return l; }
        }
    }
    NSString *link = nil;
    int64_t h = BQEscape(path, &link);
    if (h >= 0 && link.length) {
        l.handle = h;
        l.linkPath = link;
        l.escaped = YES;
    }
    return l;
}
- (NSString *)resolveSubpath:(NSString *)name {
    if (!self.linkPath) return nil;
    return [self.linkPath stringByAppendingPathComponent:name];
}
- (void)close {
    if (self.handle >= 0) {
        BQEndEscape(self.handle);
        self.handle = -1;
    }
}
- (void)dealloc { [self close]; }
@end

// ----------------------------------------------------------- FilePreviewVC ---
// Simple text/hex/image preview for a single file. Reads once on load.
@interface FilePreviewVC : UIViewController
@property (nonatomic, copy)   NSString *realPath;
@property (nonatomic, copy)   NSString *linkPath;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIImageView *imageView;
@end

@implementation FilePreviewVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = self.realPath.lastPathComponent;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self
                                                      action:@selector(shareTapped)];

    NSError *e = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.linkPath error:&e];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];

    NSData *data = nil;
    if (size <= 4 * 1024 * 1024) {
        data = [NSData dataWithContentsOfFile:self.linkPath];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:self.linkPath];
        data = [fh readDataOfLength:64 * 1024];
        [fh closeFile];
    }

    UIImage *img = data ? [UIImage imageWithData:data] : nil;
    if (img) {
        self.imageView = [[UIImageView alloc] initWithFrame:self.view.bounds];
        self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.imageView.image = img;
        [self.view addSubview:self.imageView];
        return;
    }

    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.editable = NO;
    self.textView.alwaysBounceVertical = YES;
    [self.view addSubview:self.textView];

    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (text && text.length) {
        self.textView.text = text;
    } else {
        self.textView.text = [self hexDump:data truncatedFrom:size];
    }
}

- (NSString *)hexDump:(NSData *)data truncatedFrom:(unsigned long long)totalSize {
    NSMutableString *s = [NSMutableString new];
    [s appendFormat:@"%llu bytes%@\n\n", totalSize, (data.length < totalSize) ? @" (showing first 64 KB)" : @""];
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;
    for (NSUInteger i = 0; i < n; i += 16) {
        [s appendFormat:@"%08lx  ", (unsigned long)i];
        for (NSUInteger j = 0; j < 16; j++) {
            if (i + j < n) [s appendFormat:@"%02x ", b[i + j]];
            else           [s appendString:@"   "];
            if (j == 7) [s appendString:@" "];
        }
        [s appendString:@" |"];
        for (NSUInteger j = 0; j < 16 && i + j < n; j++) {
            uint8_t c = b[i + j];
            [s appendFormat:@"%c", (c >= 0x20 && c < 0x7f) ? c : '.'];
        }
        [s appendString:@"|\n"];
    }
    return s;
}

- (void)shareTapped {
    NSURL *u = [NSURL fileURLWithPath:self.linkPath];
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[u]
                                                                     applicationActivities:nil];
    vc.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:vc animated:YES completion:nil];
}
@end

// ----------------------------------------------------------- FileBrowserVC ---
@interface FileBrowserVC ()
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, strong) BQLease  *lease;
@property (nonatomic, strong) NSArray<NSDictionary *> *entries;
@property (nonatomic, assign) BOOL showHidden;
@property (nonatomic, assign) BOOL accessDenied;
@property (nonatomic, copy)   NSString *accessError;
@property (nonatomic, assign) BOOL isMountsRoot;
@end

// Known places to try. BQEscape can't grant an extension for "/", so the root
// screen shows this list of candidate mounts instead. Each one is a real path
// the user navigates into; the escape (if any) is opened on arrival.
static NSArray<NSDictionary *> *BQMounts(void) {
    NSMutableArray *m = [NSMutableArray new];
    NSString *docs = BQDocuments();
    if (docs.length) {
        [m addObject:@{@"title": @"App Documents", @"path": docs, @"icon": @"doc.text"}];
        NSString *lib = [[docs stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Library"];
        [m addObject:@{@"title": @"App Library", @"path": lib, @"icon": @"books.vertical"}];
        NSString *container = [docs stringByDeletingLastPathComponent];
        [m addObject:@{@"title": @"App container", @"path": container, @"icon": @"shippingbox"}];
    }
    NSString *groupRoot = BQGroupRoot();
    if (groupRoot.length) {
        [m addObject:@{@"title": @"App group", @"path": groupRoot, @"icon": @"person.3"}];
    }
    [m addObject:@{@"title": @"Installed apps",
                   @"kind": @"apps",
                   @"icon": @"app.badge"}];
    [m addObject:@{@"title": @"MobileGestalt caches",
                   @"path": @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches",
                   @"icon": @"cpu"}];
    [m addObject:@{@"title": @"Shared app groups",
                   @"path": @"/private/var/mobile/Containers/Shared/AppGroup",
                   @"icon": @"person.3.sequence"}];
    [m addObject:@{@"title": @"System groups",
                   @"path": @"/private/var/containers/Shared/SystemGroup",
                   @"icon": @"gearshape.2"}];
    [m addObject:@{@"title": @"PluginKit plugins",
                   @"path": @"/private/var/mobile/Containers/Data/PluginKitPlugin",
                   @"icon": @"puzzlepiece.extension"}];
    [m addObject:@{@"title": @"App bundles",
                   @"path": @"/private/var/containers/Bundle/Application",
                   @"icon": @"app.gift"}];
    return m;
}

@implementation FileBrowserVC

- (instancetype)initWithPath:(NSString *)path {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _path = path.length ? [path copy] : @"/";
        _isMountsRoot = [_path isEqualToString:@"/"];
        _showHidden = [[NSUserDefaults standardUserDefaults] boolForKey:@"BQShowHidden"];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.isMountsRoot ? @"Mounts" : self.path.lastPathComponent;
    self.tableView.rowHeight = 56;
    self.tableView.allowsSelectionDuringEditing = YES;

    UIBarButtonItem *menu =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(showMenu)];
    self.navigationItem.rightBarButtonItem = menu;

    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)dealloc { [self.lease close]; }

- (void)reload {
    [self.lease close];
    self.accessDenied = NO;
    self.accessError = nil;

    if (self.isMountsRoot) {
        self.lease = nil;
        self.entries = BQMounts();
        [self.tableView reloadData];
        [self.refreshControl endRefreshing];
        return;
    }

    self.lease = [BQLease leaseForPath:self.path];

    if (!self.lease.linkPath) {
        self.entries = @[];
        self.accessDenied = YES;
        self.accessError = @"sandbox escape failed for this path";
        [self.tableView reloadData];
        [self.refreshControl endRefreshing];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *e = nil;
    NSArray *names = [fm contentsOfDirectoryAtPath:self.lease.linkPath error:&e];
    if (e) {
        self.entries = @[];
        self.accessDenied = YES;
        self.accessError = e.localizedDescription;
        [self.tableView reloadData];
        [self.refreshControl endRefreshing];
        return;
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        if (!self.showHidden && [name hasPrefix:@"."]) continue;
        NSString *full = [self.lease.linkPath stringByAppendingPathComponent:name];
        struct stat st;
        if (lstat(full.fileSystemRepresentation, &st) != 0) continue;
        BOOL isLink = S_ISLNK(st.st_mode);
        BOOL isDir = S_ISDIR(st.st_mode);
        if (isLink) {
            struct stat target;
            if (stat(full.fileSystemRepresentation, &target) == 0) isDir = S_ISDIR(target.st_mode);
        }
        [out addObject:@{
            @"name":    name,
            @"isDir":   @(isDir),
            @"isLink":  @(isLink),
            @"size":    @((unsigned long long)st.st_size),
            @"mtime":   @(st.st_mtimespec.tv_sec),
            @"mode":    @(st.st_mode),
        }];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL ad = [a[@"isDir"] boolValue], bd = [b[@"isDir"] boolValue];
        if (ad != bd) return ad ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    self.entries = out;
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}

#pragma mark - table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (self.accessDenied) return 1;
    return self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *CID = @"c";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:CID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CID];

    if (self.accessDenied) {
        cell.textLabel.text = @"⚠ access denied";
        cell.detailTextLabel.text = self.accessError;
        cell.detailTextLabel.numberOfLines = 2;
        cell.imageView.image = [UIImage systemImageNamed:@"lock"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    if (self.isMountsRoot) {
        NSDictionary *m = self.entries[ip.row];
        cell.textLabel.text = m[@"title"];
        cell.detailTextLabel.text = m[@"path"] ?: @"browse apps by name";
        cell.detailTextLabel.numberOfLines = 1;
        cell.imageView.image = [UIImage systemImageNamed:m[@"icon"] ?: @"folder"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    NSDictionary *d = self.entries[ip.row];
    BOOL isDir = [d[@"isDir"] boolValue];
    BOOL isLink = [d[@"isLink"] boolValue];
    cell.textLabel.text = d[@"name"];
    cell.imageView.image = [UIImage systemImageNamed:
        isLink ? (isDir ? @"folder.badge.questionmark" : @"link")
               : (isDir ? @"folder" : @"doc")];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = isDir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryDetailButton;

    unsigned long long size = [d[@"size"] unsignedLongLongValue];
    NSString *sizeStr = isDir ? @"" : [NSByteCountFormatter stringFromByteCount:size countStyle:NSByteCountFormatterCountStyleFile];
    NSDate *mt = [NSDate dateWithTimeIntervalSince1970:[d[@"mtime"] doubleValue]];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateStyle = NSDateFormatterShortStyle;
    df.timeStyle = NSDateFormatterShortStyle;
    cell.detailTextLabel.text = sizeStr.length
        ? [NSString stringWithFormat:@"%@  ·  %@", sizeStr, [df stringFromDate:mt]]
        : [df stringFromDate:mt];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.accessDenied) return;
    if (self.isMountsRoot) {
        NSDictionary *m = self.entries[ip.row];
        if ([m[@"kind"] isEqualToString:@"apps"]) {
            AppsListVC *apps = [AppsListVC new];
            [self.navigationController pushViewController:apps animated:YES];
            return;
        }
        FileBrowserVC *next = [[FileBrowserVC alloc] initWithPath:m[@"path"]];
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    NSDictionary *d = self.entries[ip.row];
    NSString *name = d[@"name"];
    NSString *realChild = [self.path stringByAppendingPathComponent:name];
    if ([d[@"isDir"] boolValue]) {
        FileBrowserVC *next = [[FileBrowserVC alloc] initWithPath:realChild];
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    FilePreviewVC *p = [FilePreviewVC new];
    p.realPath = realChild;
    p.linkPath = [self.lease resolveSubpath:name];
    [self.navigationController pushViewController:p animated:YES];
}

- (void)tableView:(UITableView *)tv accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)ip {
    if (self.accessDenied) return;
    NSDictionary *d = self.entries[ip.row];
    [self showInfoFor:d];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.accessDenied || self.isMountsRoot) return nil;
    NSDictionary *d = self.entries[ip.row];
    NSString *name = d[@"name"];
    __weak typeof(self) weakSelf = self;

    UIContextualAction *del =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:@"Delete"
                                              handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        BQConfirm(weakSelf, @"Delete", [NSString stringWithFormat:@"Delete %@?", name], ^{
            NSString *full = [weakSelf.lease resolveSubpath:name];
            NSError *e = nil;
            [[NSFileManager defaultManager] removeItemAtPath:full error:&e];
            if (e) BQAlert(weakSelf, @"Delete failed", e.localizedDescription);
            [weakSelf reload];
        });
        done(YES);
    }];

    UIContextualAction *rn =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                title:@"Rename"
                                              handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [weakSelf promptRename:name];
        done(YES);
    }];
    rn.backgroundColor = [UIColor systemBlueColor];

    return [UISwipeActionsConfiguration configurationWithActions:@[del, rn]];
}

#pragma mark - menu & prompts

- (void)showMenu {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:self.path
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"Go to path…"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self promptGoto]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"New folder…"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self promptNewFolder]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:self.showHidden ? @"Hide dotfiles" : @"Show dotfiles"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        self.showHidden = !self.showHidden;
        [[NSUserDefaults standardUserDefaults] setBool:self.showHidden forKey:@"BQShowHidden"];
        [self reload];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Shortcuts…"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self showShortcuts]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Copy path"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = self.path;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showShortcuts {
    NSArray *places = @[
        @"/",
        @"/var/mobile",
        @"/var/mobile/Containers/Data/Application",
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/var/containers/Bundle/Application",
        @"/var/containers/Shared/SystemGroup",
        @"/private/var/preferences",
    ];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Shortcuts"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *p in places) {
        [ac addAction:[UIAlertAction actionWithTitle:p
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) { [self navigateTo:p]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)promptGoto {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Go to path"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = self.path;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Go"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        NSString *p = ac.textFields.firstObject.text;
        if (p.length) [self navigateTo:p];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)promptNewFolder {
    if (self.isMountsRoot || !self.lease.linkPath) {
        BQAlert(self, @"New folder", @"Open a mount first.");
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"New folder"
                                                                message:self.path
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"name";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Create"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        NSString *name = ac.textFields.firstObject.text;
        if (!name.length) return;
        NSString *full = [self.lease resolveSubpath:name];
        NSError *e = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:full
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:&e];
        if (e) BQAlert(self, @"Create failed", e.localizedDescription);
        [self reload];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)promptRename:(NSString *)oldName {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Rename"
                                                                message:oldName
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = oldName;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Rename"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        NSString *newName = ac.textFields.firstObject.text;
        if (!newName.length || [newName isEqualToString:oldName]) return;
        NSString *src = [self.lease resolveSubpath:oldName];
        NSString *dst = [self.lease resolveSubpath:newName];
        NSError *e = nil;
        [[NSFileManager defaultManager] moveItemAtPath:src toPath:dst error:&e];
        if (e) BQAlert(self, @"Rename failed", e.localizedDescription);
        [self reload];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)navigateTo:(NSString *)p {
    FileBrowserVC *next = [[FileBrowserVC alloc] initWithPath:p];
    [self.navigationController pushViewController:next animated:YES];
}

- (void)showInfoFor:(NSDictionary *)d {
    NSString *name = d[@"name"];
    mode_t m = (mode_t)[d[@"mode"] unsignedIntValue];
    char perms[11] = "----------";
    perms[0] = S_ISDIR(m) ? 'd' : (S_ISLNK(m) ? 'l' : '-');
    perms[1] = (m & S_IRUSR) ? 'r' : '-';
    perms[2] = (m & S_IWUSR) ? 'w' : '-';
    perms[3] = (m & S_IXUSR) ? 'x' : '-';
    perms[4] = (m & S_IRGRP) ? 'r' : '-';
    perms[5] = (m & S_IWGRP) ? 'w' : '-';
    perms[6] = (m & S_IXGRP) ? 'x' : '-';
    perms[7] = (m & S_IROTH) ? 'r' : '-';
    perms[8] = (m & S_IWOTH) ? 'w' : '-';
    perms[9] = (m & S_IXOTH) ? 'x' : '-';
    NSDate *mt = [NSDate dateWithTimeIntervalSince1970:[d[@"mtime"] doubleValue]];
    NSString *msg = [NSString stringWithFormat:@"%s\n%llu bytes\n%@\n\n%@",
                     perms,
                     [d[@"size"] unsignedLongLongValue],
                     mt,
                     [self.path stringByAppendingPathComponent:name]];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:name
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Copy path"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = [self.path stringByAppendingPathComponent:name];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
