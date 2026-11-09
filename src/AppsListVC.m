#import "AppsListVC.h"
#import "FileBrowserVC.h"
#import "BQCore.h"
#import "BQUI.h"

// A row: name, bundle id, data container path.
@interface BQApp : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *dataPath;
@property (nonatomic, copy) NSString *bundlePath;
@end
@implementation BQApp @end

@interface AppsListVC () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<BQApp *> *allApps;
@property (nonatomic, strong) NSArray<BQApp *> *shown;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, assign) BOOL thirdPartyOnly;
@end

@implementation AppsListVC

- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _thirdPartyOnly = YES;
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

    [self loadApps];
}

- (void)toggleFilter {
    self.thirdPartyOnly = !self.thirdPartyOnly;
    [self applyFilter];
}

- (void)loadApps {
    Class WS = NSClassFromString(@"LSApplicationWorkspace");
    if (!WS) {
        self.allApps = @[];
        [self applyFilter];
        BQAlert(self, @"No app list", @"LSApplicationWorkspace is unavailable on this build.");
        return;
    }
    id ws = [WS performSelector:@selector(defaultWorkspace)];
    NSArray *proxies = [ws performSelector:@selector(allInstalledApplications)];
    if (!proxies.count) proxies = [ws performSelector:@selector(allApplications)];

    NSMutableArray<BQApp *> *out = [NSMutableArray arrayWithCapacity:proxies.count];
    for (id p in proxies) {
        BQApp *a = [BQApp new];
        if ([p respondsToSelector:@selector(localizedName)])
            a.name = [p performSelector:@selector(localizedName)];
        if (!a.name.length && [p respondsToSelector:@selector(localizedShortName)])
            a.name = [p performSelector:@selector(localizedShortName)];
        if ([p respondsToSelector:@selector(applicationIdentifier)])
            a.bundleID = [p performSelector:@selector(applicationIdentifier)];
        if ([p respondsToSelector:@selector(dataContainerURL)]) {
            NSURL *u = [p performSelector:@selector(dataContainerURL)];
            a.dataPath = u.path;
        }
        if ([p respondsToSelector:@selector(bundleURL)]) {
            NSURL *u = [p performSelector:@selector(bundleURL)];
            a.bundlePath = u.path;
        }
        if (!a.bundleID.length) continue;
        if (!a.name.length) a.name = a.bundleID;
        [out addObject:a];
    }
    [out sortUsingComparator:^NSComparisonResult(BQApp *x, BQApp *y) {
        return [x.name localizedCaseInsensitiveCompare:y.name];
    }];
    self.allApps = out;
    BQLog(@"AppsList: %lu apps from LSApplicationWorkspace", (unsigned long)out.count);
    [self applyFilter];
}

- (void)applyFilter {
    NSString *q = self.search.searchBar.text.lowercaseString;
    NSMutableArray *out = [NSMutableArray new];
    for (BQApp *a in self.allApps) {
        if (self.thirdPartyOnly) {
            // Heuristic: third-party apps live under /var/containers/Bundle/Application.
            if (![a.bundlePath containsString:@"/containers/Bundle/Application/"]) continue;
        }
        if (q.length) {
            if (![a.name.lowercaseString containsString:q] &&
                ![a.bundleID.lowercaseString containsString:q]) continue;
        }
        [out addObject:a];
    }
    self.shown = out;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *CID = @"a";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:CID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CID];
    BQApp *a = self.shown[ip.row];
    cell.textLabel.text = a.name;
    cell.detailTextLabel.text = a.bundleID;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = [UIImage systemImageNamed:@"app.dashed"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    BQApp *a = self.shown[ip.row];
    if (!a.dataPath.length) {
        BQAlert(self, a.name, @"No data container for this app.");
        return;
    }
    FileBrowserVC *next = [[FileBrowserVC alloc] initWithPath:a.dataPath];
    next.title = a.name;
    [self.navigationController pushViewController:next animated:YES];
}

@end
