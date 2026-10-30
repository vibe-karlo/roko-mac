// roko's Dock tile plug-in: the icon chosen in Settings › Appearance › App
// icon, kept in the Dock after roko quits, as Arc's and Cra's are. The Dock
// loads it from Contents/PlugIns (NSDockTilePlugIn in Info.plist; build.sh
// builds it). It draws the file roko names in its defaults as appIconFile,
// and the bundle's own icon when there is none. roko says when it changes.

#import <AppKit/AppKit.h>

static CFStringRef const RokoID = CFSTR("com.growthstudio.roko.mac");

@interface RokoDockTilePlugIn : NSObject <NSDockTilePlugIn>
@property (strong) NSDockTile *tile;
@property (strong) id observer;
@end

@implementation RokoDockTilePlugIn

- (void)setDockTile:(NSDockTile *)dockTile {
    if (self.observer) {
        [[NSDistributedNotificationCenter defaultCenter] removeObserver:self.observer];
        self.observer = nil;
    }
    self.tile = dockTile;
    if (!dockTile) return;
    [self paint];
    __weak RokoDockTilePlugIn *weakSelf = self;
    self.observer = [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:@"com.growthstudio.roko.mac.appIcon" object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) { [weakSelf paint]; }];
}

- (void)paint {
    CFPreferencesAppSynchronize(RokoID);
    NSString *path = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("appIconFile"), RokoID));
    NSImage *image = [path isKindOfClass:[NSString class]] && path.length
        ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    if (image) {
        NSImageView *view = [NSImageView imageViewWithImage:image];
        view.imageScaling = NSImageScaleProportionallyUpOrDown;
        self.tile.contentView = view;
    } else {
        self.tile.contentView = nil;
    }
    [self.tile display];
}

@end
