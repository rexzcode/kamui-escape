#import "AppsListVC.h"
#import "FileBrowserVC.h"
#import "BQCore.h"
#import "BQUI.h"

@interface BQApp : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *dataPath;
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic, assign) BOOL nameResolved;
@end
@implementation BQApp @end

@interface AppsListVC () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<BQApp *> *allApps;
@property (nonatomic, strong) NSArray<BQApp *> *shown;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, assign) BOOL thirdPartyOnly;
@property (nonatomic, strong) NSMutableSet<NSString *> *resolving;
@property (nonatomic, assign) BOOL discoveredViaInodeWalk;
@end

@implementation AppsListVC

- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _thirdPartyOnly = YES;
        _resolving = [NSMutableSet new];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Installed apps";
    self.tableView.rowHeight = 60;

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"Search by name or bundle id";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    UIBarButtonItem *filter =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(toggleFilter)];
    self.navigationItem.rightBarButtonItem = filter;

    dispatch_async(dispatch_get_main_queue(), ^{ [self loadApps]; });
}

- (void)toggleFilter {
    self.thirdPartyOnly = !self.thirdPartyOnly;
    [self applyFilter];
}

// --- primary path: LSApplicationWorkspace (if the host grants it) -----------
- (NSArray<BQApp *> *)loadViaWorkspace {
    Class WS = NSClassFromString(@"LSApplicationWorkspace");
    if (!WS) return @[];
    id ws = [WS performSelector:@selector(defaultWorkspace)];
    NSArray *proxies = [ws performSelector:@selector(allInstalledApplications)];
    if (!proxies.count && [ws respondsToSelector:@selector(allApplications)])
        proxies = [ws performSelector:@selector(allApplications)];

    NSMutableArray *out = [NSMutableArray new];
    for (id p in proxies) {
        BQApp *a = [BQApp new];
        if ([p respondsToSelector:@selector(localizedName)])
            a.name = [p performSelector:@selector(localizedName)];
        if (!a.name.length && [p respondsToSelector:@selector(localizedShortName)])
            a.name = [p performSelector:@selector(localizedShortName)];
        if ([p respondsToSelector:@selector(applicationIdentifier)])
            a.bundleID = [p performSelector:@selector(applicationIdentifier)];
        if ([p respondsToSelector:@selector(dataContainerURL)])
            a.dataPath = ((NSURL *)[p performSelector:@selector(dataContainerURL)]).path;
        if ([p respondsToSelector:@selector(bundleURL)])
            a.bundlePath = ((NSURL *)[p performSelector:@selector(bundleURL)]).path;
        if (!a.bundleID.length) continue;
        if (!a.name.length) a.name = a.bundleID;
        a.nameResolved = YES;
        [out addObject:a];
    }
    return out;
}

// --- fallback: fsgetpath inode walk, lazy bundle-id resolve -----------------
- (NSArray<BQApp *> *)loadViaInodeWalk {
    NSArray<NSString *> *paths = BQListChildren(@"/var/mobile/Containers/Data/Application", 0);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *path in paths) {
        BQApp *a = [BQApp new];
        a.dataPath = path;
        a.name = path.lastPathComponent; // UUID until we resolve it
        a.bundleID = @"(resolving…)";
        [out addObject:a];
    }
    BQLog(@"AppsList: inode walk found %lu data containers", (unsigned long)out.count);
    return out;
}

- (void)loadApps {
    NSArray<BQApp *> *apps = [self loadViaWorkspace];
    BQLog(@"AppsList: LSApplicationWorkspace returned %lu apps", (unsigned long)apps.count);
    if (!apps.count) {
        apps = [self loadViaInodeWalk];
        self.discoveredViaInodeWalk = YES;
    }
    self.allApps = apps;
    [self applyFilter];
    if (self.discoveredViaInodeWalk && apps.count) {
        [self resolveNamesForVisibleRows];
    } else if (!apps.count) {
        BQAlert(self, @"No apps found",
                @"Neither LSApplicationWorkspace nor the inode-walk enumerator returned any apps.");
    }
}

// Read .com.apple.mobile_container_manager.metadata.plist inside the container
// to get the bundle id. One brief BQEscape lease per container.
- (NSString *)readBundleIDForContainer:(NSString *)containerPath {
    NSString *link = nil;
    int64_t h = BQEscape(containerPath, &link);
    if (h < 0 || !link.length) return nil;
    NSString *metaPath = [link stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:metaPath];
    BQEndEscape(h);
    return d[@"MCMMetadataIdentifier"];
}

- (void)resolveNamesForVisibleRows {
    NSArray<NSIndexPath *> *rows = self.tableView.indexPathsForVisibleRows;
    for (NSIndexPath *ip in rows) {
        if (ip.row >= (NSInteger)self.shown.count) continue;
        BQApp *a = self.shown[ip.row];
        if (a.nameResolved || [self.resolving containsObject:a.dataPath]) continue;
        [self.resolving addObject:a.dataPath];
        NSString *path = a.dataPath;
        dispatch_async(BQWorkQueue(), ^{
            NSString *bid = [self readBundleIDForContainer:path];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.resolving removeObject:path];
                if (bid.length) {
                    a.bundleID = bid;
                    a.name = bid;
                    a.nameResolved = YES;
                    NSInteger idx = [self.shown indexOfObject:a];
                    if (idx != NSNotFound) {
                        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:idx inSection:0]]
                                              withRowAnimation:UITableViewRowAnimationNone];
                    }
                }
            });
        });
    }
}

- (void)applyFilter {
    NSString *q = self.search.searchBar.text.lowercaseString;
    NSMutableArray *out = [NSMutableArray new];
    for (BQApp *a in self.allApps) {
        if (self.thirdPartyOnly && !self.discoveredViaInodeWalk) {
            if (![a.bundlePath containsString:@"/containers/Bundle/Application/"]) continue;
        }
        if (q.length) {
            if (![a.name.lowercaseString containsString:q] &&
                ![a.bundleID.lowercaseString containsString:q]) continue;
        }
        [out addObject:a];
    }
    [out sortUsingComparator:^NSComparisonResult(BQApp *x, BQApp *y) {
        // Resolved rows first, then by name.
        if (x.nameResolved != y.nameResolved) return x.nameResolved ? NSOrderedAscending : NSOrderedDescending;
        return [x.name localizedCaseInsensitiveCompare:y.name];
    }];
    self.shown = out;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc { [self applyFilter]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *CID = @"a";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:CID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CID];
    BQApp *a = self.shown[ip.row];
    cell.textLabel.text = a.nameResolved ? a.bundleID : a.name;
    cell.detailTextLabel.text = a.nameResolved ? a.dataPath.lastPathComponent : a.bundleID;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = [UIImage systemImageNamed:a.nameResolved ? @"app.dashed" : @"questionmark.app.dashed"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)c forRowAtIndexPath:(NSIndexPath *)ip {
    if (self.discoveredViaInodeWalk) [self resolveNamesForVisibleRows];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    BQApp *a = self.shown[ip.row];
    if (!a.dataPath.length) {
        BQAlert(self, a.name, @"No data container for this app.");
        return;
    }
    FileBrowserVC *next = [[FileBrowserVC alloc] initWithPath:a.dataPath];
    next.title = a.nameResolved ? a.bundleID : a.dataPath.lastPathComponent;
    [self.navigationController pushViewController:next animated:YES];
}

@end
