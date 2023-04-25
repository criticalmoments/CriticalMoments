//
//  CMBannerManagger.m
//  
//
//  Created by Steve Cosman on 2023-04-23.
//

#import "CMBannerManager.h"

#define MAX_BANNER_HEIGHT_PERCENTAGE 0.20

@interface CMBannerManager () <CMBannerDismissDelegate>

// Access should be @synchronized(self)
@property (nonatomic, strong) NSMutableArray<CMBannerMessage*>* appWideMessages;

// currentMessage managed by renderForCurrentState -- don't modify directly
@property (nonatomic, strong) CMBannerMessage* currentMessage;
@property (nonatomic, strong) UIView* currentMessageView;

// access syncronized by main queue
@property (nonatomic, strong) UIView* appWideContainerView;

@end

@implementation CMBannerManager

static CMBannerManager *sharedInstance = nil;

+ (CMBannerManager*)sharedInstance
{
    @synchronized(CMBannerManager.class) {
        if (!sharedInstance) {
            sharedInstance = [[self alloc] init];
        }
        
        return sharedInstance;
    }
}

-(instancetype)init {
    self = [super init];
    if (self) {
        _appWideMessages = [[NSMutableArray alloc] init];
        // Default to bottom -- less likely to conflict with hard-coded app frame content
        self.appWideBannerPosition = CMAppWideBannerPositionBottom;
    }
    return self;
}

-(void) showAppWideMessage:(CMBannerMessage*)message {
    @synchronized (self) {
        if ([_appWideMessages containsObject:message]) {
            return;
        }
        
        message.dismissDelegate = self;
        [_appWideMessages addObject:message];

        [self renderForCurrentState];
    }
}

-(void) removeAppWideMessage:(CMBannerMessage*)message {
    @synchronized (self) {
        [_appWideMessages removeObject:message];
        
        [self renderForCurrentState];
    }
}

-(void) removeAllAppWideMessages {
    @synchronized (self) {
        [_appWideMessages removeAllObjects];
        
        [self renderForCurrentState];
    }
}

-(void) renderForCurrentState {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self renderForCurrentState];
        });
        return;
    }

    // Pick a valid new current message, preferring current, then the last added still active message
    CMBannerMessage* priorCurrentMessage = _currentMessage;
    if (![_appWideMessages containsObject:_currentMessage]) {
        _currentMessage = nil;
    }
    _currentMessage = _appWideMessages.lastObject;
    
    // if no messages left to render clear container view
    if (!_currentMessage) {
        [self removeAppWideBannerContainer];
        return;
    }
    
    if (priorCurrentMessage == _currentMessage) {
        // we are already rendering this message, no-op
        return;
    }
    
    // remove prior message from container
    [_currentMessageView removeFromSuperview];
    
    if (!_appWideContainerView) {
        [self createAppWideBannerContainer];
    }
    
    UIView* messageView = [_currentMessage buildViewForMessage];
    _currentMessageView = messageView;
    messageView.translatesAutoresizingMaskIntoConstraints = NO;
    [_appWideContainerView addSubview:messageView];
    NSArray<NSLayoutConstraint*>* constraints = @[
        [messageView.topAnchor constraintEqualToAnchor:_appWideContainerView.topAnchor],
        [messageView.leftAnchor constraintEqualToAnchor:_appWideContainerView.leftAnchor],
        [messageView.rightAnchor constraintEqualToAnchor:_appWideContainerView.rightAnchor],
        [messageView.bottomAnchor constraintEqualToAnchor:_appWideContainerView.bottomAnchor],
    ];
    
    [NSLayoutConstraint activateConstraints:constraints];
}

-(void) createAppWideBannerContainer {
    //if (dispatch_queue_get_label(dispatch_get_main_queue()) != dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)) {
    // Dispatch UI work to main
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self createAppWideBannerContainer];
        });
        return;
    }
    
    if (_appWideContainerView) {
        return;
    }
    
    // Find key window, falling back to first window
    UIWindow* keyWindow = [[[UIApplication sharedApplication] windows] firstObject];
    for (UIWindow* w in [[UIApplication sharedApplication] windows]) {
        if (w.isKeyWindow) {
            keyWindow = w;
            break;
        }
    }
    if (!keyWindow) {
        // no window to render in
        NSLog(@"CMBannerManager could not find a key window");
        return;
    }
    
    UIViewController* appRootViewController = keyWindow.rootViewController;
    
    _appWideContainerView = [[UIView alloc] init];
    _appWideContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    [keyWindow addSubview:_appWideContainerView];
    
    // TODO
    // Max height still set, don't want it taking over screen
    // Max lines still set, but configurable
    // Invert sizing
    // look at rootview.bottomLayoutGuide
    
    appRootViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    
    // Layout
    
    // These two low priority constraints aligns rootVC to window top/bottom,  but are overridden by high pri banner constraints if present
    NSLayoutConstraint* appAlignBottomWindowLowPriorityConstraint = [appRootViewController.view.bottomAnchor constraintEqualToAnchor:keyWindow.bottomAnchor];
    appAlignBottomWindowLowPriorityConstraint.priority = UILayoutPriorityDefaultLow;
    NSLayoutConstraint* appAlignTopWindowLowPriorityConstraint = [appRootViewController.view.topAnchor constraintEqualToAnchor:keyWindow.topAnchor];
    appAlignTopWindowLowPriorityConstraint.priority = UILayoutPriorityDefaultLow;
    
    NSArray<NSLayoutConstraint*>* constraints = @[
        // position banner at the bottom the window and to the edges
        [_appWideContainerView.leftAnchor constraintEqualToAnchor:keyWindow.leftAnchor],
        [_appWideContainerView.rightAnchor constraintEqualToAnchor:keyWindow.rightAnchor],
        
        // TODO [_appWideContainerView.bottomAnchor constraintEqualToAnchor:keyWindow.bottomAnchor],
        
        // Make the banner at most 20% window height. Backstop for way too much text.
        [_appWideContainerView.heightAnchor constraintLessThanOrEqualToAnchor:keyWindow.heightAnchor multiplier:MAX_BANNER_HEIGHT_PERCENTAGE],
        
        // Align root VC to window
        appAlignBottomWindowLowPriorityConstraint,
        appAlignTopWindowLowPriorityConstraint,
        // TODO [appRootViewController.view.bottomAnchor constraintEqualToAnchor:_appWideContainerView.topAnchor],
        [appRootViewController.view.leftAnchor constraintEqualToAnchor:keyWindow.leftAnchor],
        [appRootViewController.view.rightAnchor constraintEqualToAnchor:keyWindow.rightAnchor],
    ];
    
    if (self.appWideBannerPosition == CMAppWideBannerPositionBottom) {
        // Container at bottom of app
        constraints = [constraints arrayByAddingObjectsFromArray:@[
            [_appWideContainerView.bottomAnchor constraintEqualToAnchor:keyWindow.bottomAnchor],
            [appRootViewController.view.bottomAnchor constraintEqualToAnchor:_appWideContainerView.topAnchor],
        ]];
    } else {
        // Container at top of app
        constraints = [constraints arrayByAddingObjectsFromArray:@[
            [_appWideContainerView.topAnchor constraintEqualToAnchor:keyWindow.topAnchor],
            [appRootViewController.view.topAnchor constraintEqualToAnchor:_appWideContainerView.bottomAnchor],
        ]];
    }
    
    [NSLayoutConstraint activateConstraints:constraints];
}

// TODO main method dispatch
-(void) removeAppWideBannerContainer {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self removeAppWideBannerContainer];
        });
        return;
    }
    
    if (!_appWideContainerView) {
        return;
    }
    
    [_appWideContainerView removeFromSuperview];
    _appWideContainerView = nil;
}

#pragma mark

-(void) dismissedMessage:(CMBannerMessage*)message{
    [self removeAppWideMessage:message];
}

@end
