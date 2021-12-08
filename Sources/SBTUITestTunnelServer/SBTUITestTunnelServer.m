// SBTUITestTunnelServer.m
//
// Copyright (C) 2016 Subito.it S.r.l (www.subito.it)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#if DEBUG
    #ifndef ENABLE_UITUNNEL
        #define ENABLE_UITUNNEL 1
    #endif
#endif

#if ENABLE_UITUNNEL

#ifdef SPM
    @import SBTUITestTunnelCommonNoARC;
#endif

@import SBTUITestTunnelCommon;
@import GCDWebServer;
@import CoreLocation;
@import UserNotifications;

#import "include/SBTUITestTunnelServer.h"
#import "include/SBTAnyViewControllerPreviewing.h"
#import "include/UIViewController+SBTUITestTunnel.h"
#import "private/CLLocationManager+Swizzles.h"
#import "private/UNUserNotificationCenter+Swizzles.h"
#import "private/UITextField+DisableAutocomplete.h"
#import "private/SBTProxyURLProtocol.h"
#import "private/UIView+Extensions.h"

#if !defined(NS_BLOCK_ASSERTIONS)

#define BlockAssert(condition, desc, ...) \
do {\
if (!(condition)) { \
[[NSAssertionHandler currentHandler] handleFailureInFunction:NSStringFromSelector(_cmd) \
file:[NSString stringWithUTF8String:__FILE__] \
lineNumber:__LINE__ \
description:(desc), ##__VA_ARGS__]; \
}\
} while(0);

#else // NS_BLOCK_ASSERTIONS defined

#define BlockAssert(condition, desc, ...)

#endif

void repeating_dispatch_after(int64_t delay, dispatch_queue_t queue, BOOL (^block)(void))
{
    if (block() == NO) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
            repeating_dispatch_after(delay, queue, block);
        });
    }
}

@implementation GCDWebServerRequest (Extension)

- (NSDictionary *)parameters
{
    if ([self isKindOfClass:[GCDWebServerURLEncodedFormRequest class]]) {
        return ((GCDWebServerURLEncodedFormRequest *)self).arguments;
    } else {
        return self.query;
    }
}

@end

@interface SBTUITestTunnelServer() <SBTIPCTunnel>

@property (nonatomic, strong) GCDWebServer *server;
@property (nonatomic, strong) dispatch_queue_t commandDispatchQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSObject *)> *customCommands;

@property (nonatomic, assign) BOOL startupCompleted;

@property (nonatomic, strong) NSMapTable<CLLocationManager *, id<CLLocationManagerDelegate>> *coreLocationActiveManagers;
@property (nonatomic, strong) NSMutableString *coreLocationStubbedServiceStatus;
@property (nonatomic, strong) NSMutableString *notificationCenterStubbedAuthorizationStatus;

@property (nonatomic, strong) DTXIPCConnection* ipcConnection;

@end

@implementation SBTUITestTunnelServer

static NSTimeInterval SBTUITunneledServerDefaultTimeout = 60.0;

+ (SBTUITestTunnelServer *)sharedInstance
{
    static dispatch_once_t once;
    static SBTUITestTunnelServer *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[SBTUITestTunnelServer alloc] init];
        sharedInstance.server = [[GCDWebServer alloc] init];
        sharedInstance.commandDispatchQueue = dispatch_queue_create("com.sbtuitesttunnel.queue.command", DISPATCH_QUEUE_SERIAL);
        sharedInstance.startupCompleted = NO;
        sharedInstance.coreLocationActiveManagers = NSMapTable.weakToWeakObjectsMapTable;
        sharedInstance.coreLocationStubbedServiceStatus = [NSMutableString string];
        sharedInstance.notificationCenterStubbedAuthorizationStatus = [NSMutableString stringWithString:[@(UNAuthorizationStatusAuthorized) stringValue]];

        [sharedInstance reset];
        
        [NSURLProtocol registerClass:[SBTProxyURLProtocol class]];
    });
    
    return sharedInstance;
}

+ (void)takeOff
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [self.sharedInstance takeOffOnce];
    });
}

- (void)takeOffOnce
{
    NSDictionary<NSString *, NSString *> *environment = [NSProcessInfo processInfo].environment;
    
    NSString *ipcIdentifier = environment[SBTUITunneledApplicationLaunchEnvironmentIPCKey];
    NSString *tunnelPort = environment[SBTUITunneledApplicationLaunchEnvironmentPortKey];
    
    if (!tunnelPort && !ipcIdentifier) {
        // Required methods missing, presumely app wasn't launched from ui test
        NSLog(@"[SBTUITestTunnel] required environment parameters missing, safely landing");
        return;
    }
        
    if (ipcIdentifier) {
        NSLog(@"[SBTUITestTunnel] IPC tunnel taking off");
        [self takeOffOnceIPCWithServiceIdentifier:ipcIdentifier];
    } else {
        NSLog(@"[SBTUITestTunnel] HTTP tunnel taking off");
        [self takeOffOnceUsingHTTPPort:tunnelPort];
    }
}

- (void)takeOffOnceIPCWithServiceIdentifier:(NSString *)serviceIdentifier
{
    self.ipcConnection = [[DTXIPCConnection alloc] initWithServiceName:[NSString stringWithFormat:@"com.subito.sbtuitesttunnel.ipc.%@", serviceIdentifier]];
    self.ipcConnection.exportedInterface = [DTXIPCInterface interfaceWithProtocol:@protocol(SBTIPCTunnel)];
    self.ipcConnection.exportedObject = self;

    [self.ipcConnection resume];

    [self processLaunchOptionsIfNeeded];

    if (![[NSProcessInfo processInfo].arguments containsObject:SBTUITunneledApplicationLaunchSignal]) {
        NSLog(@"[SBTUITestTunnel] Signal launch option missing, safely landing!");
        return;
    }

    NSAssert([NSThread isMainThread], @"We synch startupCompleted on main thread");
    NSTimeInterval start = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - start < SBTUITunneledServerDefaultTimeout) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

        if (self.startupCompleted) {
            NSLog(@"[SBTUITestTunnel] Up and running!");
            return;
        }
    }

    BlockAssert(NO, @"[UITestTunnelServer] Fail waiting for launch semaphore");
}

- (void)performCommandWithParameters:(NSDictionary *)parameters block:(void (^)(NSDictionary *))block
{
    NSString *command = parameters[SBTUITunnelIPCCommand];

    NSString *commandString = [command stringByAppendingString:@":"];
    SEL commandSelector = NSSelectorFromString(commandString);
    NSDictionary *response = nil;

    if (![self processCustomCommandIfNecessary:command parameters:parameters returnObject:&response]) {
        if (![self respondsToSelector:commandSelector]) {
            BlockAssert(NO, @"[UITestTunnelServer] Unhandled/unknown command! %@", command);
        }

        IMP imp = [self methodForSelector:commandSelector];

        NSLog(@"[SBTUITestTunnel] Executing command '%@'", command);

        NSDictionary * (*func)(id, SEL, NSDictionary *) = (void *)imp;
        response = func(self, commandSelector, parameters);
    }
    
    block(response);
}

- (void)takeOffOnceUsingHTTPPort:(NSString *)tunnelPort
{
    Class requestClass = ([SBTUITunnelHTTPMethod isEqualToString:@"POST"]) ? [GCDWebServerURLEncodedFormRequest class] : [GCDWebServerRequest class];
    
    __weak typeof(self) weakSelf = self;
    [self.server addDefaultHandlerForMethod:SBTUITunnelHTTPMethod requestClass:requestClass processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
        __strong typeof(weakSelf)strongSelf = weakSelf;
        __block GCDWebServerDataResponse *ret;
        
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(strongSelf.commandDispatchQueue, ^{
            NSString *command = [request.path stringByReplacingOccurrencesOfString:@"/" withString:@""];
            
            NSString *commandString = [command stringByAppendingString:@":"];
            SEL commandSelector = NSSelectorFromString(commandString);
            NSDictionary *response = nil;
            
            if (![strongSelf processCustomCommandIfNecessary:command parameters:request.parameters returnObject:&response]) {
                if (![strongSelf respondsToSelector:commandSelector]) {
                    BlockAssert(NO, @"[UITestTunnelServer] Unhandled/unknown command! %@", command);
                }
                
                IMP imp = [strongSelf methodForSelector:commandSelector];
                
                NSLog(@"[SBTUITestTunnel] Executing command '%@'", command);
                
                NSDictionary * (*func)(id, SEL, NSDictionary *) = (void *)imp;
                response = func(strongSelf, commandSelector, request.parameters);
            }
            
            ret = [GCDWebServerDataResponse responseWithJSONObject:response];
            
            dispatch_semaphore_signal(sem);
        });
        
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SBTUITunneledServerDefaultTimeout * NSEC_PER_SEC))) != 0) {}
        return ret;
    }];
    
    [self processLaunchOptionsIfNeeded];
    
    if (![[NSProcessInfo processInfo].arguments containsObject:SBTUITunneledApplicationLaunchSignal]) {
        NSLog(@"[SBTUITestTunnel] Signal launch option missing, safely landing!");
        return;
    }
    
    NSDictionary *serverOptions = [NSMutableDictionary dictionary];
    
    [serverOptions setValue:@NO forKey:GCDWebServerOption_AutomaticallySuspendInBackground];
    [serverOptions setValue:@(YES) forKey:GCDWebServerOption_BindToLocalhost];
    
    if (tunnelPort) {
        [serverOptions setValue:@([tunnelPort intValue]) forKey:GCDWebServerOption_Port];
        NSLog(@"[SBTUITestTunnel] Starting server on port: %@", tunnelPort);
    } else {
        NSAssert(NO, @"No valid discovery method passed");
    }
    
    [GCDWebServer setLogLevel:3];

    NSError *serverError = nil;
    if (![self.server startWithOptions:serverOptions error:&serverError]) {
        BlockAssert(NO, @"[UITestTunnelServer] Failed to start server on port %d. %@", [tunnelPort intValue], serverError.description);
        return;
    }
    
    NSAssert([NSThread isMainThread], @"We synch startupCompleted on main thread");
    NSTimeInterval start = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - start < SBTUITunneledServerDefaultTimeout) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        
        if (self.startupCompleted) {
            NSLog(@"[SBTUITestTunnel] Up and running!");
            return;
        }
    }
    
    BlockAssert(NO, @"[UITestTunnelServer] Fail waiting for launch semaphore");
}

- (BOOL)processCustomCommandIfNecessary:(NSString *)command parameters:(NSDictionary *)parameters returnObject:(NSObject **)returnObject
{
    if ([command isEqualToString:SBTUITunneledApplicationCommandCustom]) {
        NSString *customCommandName = parameters[SBTUITunnelCustomCommandKey];
        NSData *objData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelObjectKey] options:0];
        NSObject *inObj = [NSKeyedUnarchiver unarchiveObjectWithData:objData];
        
        NSObject *(^block)(NSObject *) = [[SBTUITestTunnelServer customCommands] objectForKey:customCommandName];
        if (block) {
            NSObject *outObject = block(inObj);
            
            NSData *data;
            if (@available(iOS 11.0, *)) {
                data = [NSKeyedArchiver archivedDataWithRootObject:outObject requiringSecureCoding:NO error:nil];
            } else {
                data = [NSKeyedArchiver archivedDataWithRootObject:outObject];
            }
            
            NSString *ret = data ? [data base64EncodedStringWithOptions:0] : @"";
            *returnObject = @{ SBTUITunnelResponseResultKey: ret };
            
            return YES;
        } else {
            BlockAssert(NO, @"[UITestTunnelServer] Custom command %@ not registered", customCommandName);
        }
    }
    
    return NO;
}

/* Rememeber to always return something at the end of the command otherwise [self performSelector] will crash with an EXC_I386_GPFLT */

#pragma mark - Ping Command

- (NSDictionary *)commandPing:(NSDictionary *)parameters
{
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Quit Command

- (NSDictionary *)commandQuit:(NSDictionary *)parameters
{
    exit(0);
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Stubs Commands

- (NSDictionary *)commandStubMatching:(NSDictionary *)parameters
{
    __block NSString *stubId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validStubRequest:parameters]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelStubMatchRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        
        NSData *responseData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelStubResponseKey] options:0];
        SBTStubResponse *response = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];

        stubId = [SBTProxyURLProtocol stubRequestsMatching:requestMatch stubResponse:response];
    }
    
    return @{ SBTUITunnelResponseResultKey: stubId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @"" };
}

#pragma mark - Stub Remove Commands

- (NSDictionary *)commandStubRequestsRemove:(NSDictionary *)parameters
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelStubMatchRuleKey] options:0];
    NSString *stubId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol stubRequestsRemoveWithId:stubId] ? @"YES" : @"NO";
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandStubRequestsRemoveAll:(NSDictionary *)parameters
{
    [SBTProxyURLProtocol stubRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Stub Retrieve Commands

- (NSDictionary *)commandStubRequestsAll:(NSDictionary *)parameters
{
    NSString *ret = nil;
    
    NSDictionary *activeStubs = [SBTProxyURLProtocol stubRequestsAll];
    
    NSData *data;
    if (@available(iOS 11.0, *)) {
        data = [NSKeyedArchiver archivedDataWithRootObject:activeStubs requiringSecureCoding:NO error:nil];
    } else {
        data = [NSKeyedArchiver archivedDataWithRootObject:activeStubs];
    }
    
    if (data) {
        ret = [data base64EncodedStringWithOptions:0];
    }
    
    return @{ SBTUITunnelResponseResultKey: ret ?: @"" };
}

#pragma mark - Rewrites Commands

- (NSDictionary *)commandRewriteMatching:(NSDictionary *)parameters
{
    __block NSString *rewriteId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validRewriteRequest:parameters]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelRewriteMatchRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        
        NSData *rewriteData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelRewriteKey] options:0];
        SBTRewrite *rewrite = [NSKeyedUnarchiver unarchiveObjectWithData:rewriteData];
        
        rewriteId = [SBTProxyURLProtocol rewriteRequestsMatching:requestMatch rewrite:rewrite];
    }
    
    return @{ SBTUITunnelResponseResultKey: rewriteId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @"" };
}

#pragma mark - Rewrite Remove Commands

- (NSDictionary *)commandRewriteRemove:(NSDictionary *)parameters
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelRewriteMatchRuleKey] options:0];
    NSString *rewriteId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol rewriteRequestsRemoveWithId:rewriteId] ? @"YES" : @"NO";
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandRewriteRemoveAll:(NSDictionary *)parameters
{
    [SBTProxyURLProtocol rewriteRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Request Monitor Commands

- (NSDictionary *)commandMonitorMatching:(NSDictionary *)parameters
{
    NSString *reqId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validMonitorRequest:parameters]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelProxyQueryRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        
        reqId = [SBTProxyURLProtocol monitorRequestsMatching:requestMatch];
    }
    
    return @{ SBTUITunnelResponseResultKey: reqId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @"" };
}

- (NSDictionary *)commandMonitorRemove:(NSDictionary *)parameters
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelProxyQueryRuleKey] options:0];
    NSString *reqId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol monitorRequestsRemoveWithId:reqId] ? @"YES" : @"NO";
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandMonitorsRemoveAll:(NSDictionary *)parameters
{
    [SBTProxyURLProtocol monitorRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandMonitor:(NSDictionary *)parameters flush:(BOOL)flag
{
    __block NSArray<SBTMonitoredNetworkRequest *> *requestsToFlush = @[];
    
    requestsToFlush = [SBTProxyURLProtocol monitoredRequestsAll];
    if (flag) {
        [SBTProxyURLProtocol monitoredRequestsFlushAll];
    }
    
    NSData *data;
    if (@available(iOS 11.0, *)) {
        data = [NSKeyedArchiver archivedDataWithRootObject:requestsToFlush requiringSecureCoding:NO error:nil];
    } else {
        data = [NSKeyedArchiver archivedDataWithRootObject:requestsToFlush];
    }
    
    NSString *ret = @"";
    if (data) {
        ret = [data base64EncodedStringWithOptions:0];
    }
    
    NSString *debugInfo = [NSString stringWithFormat:@"Found %ld monitored requests", (unsigned long)requestsToFlush.count];
    
    return @{ SBTUITunnelResponseResultKey: ret ?: @"", SBTUITunnelResponseDebugKey: debugInfo ?: @"" };
}

- (NSDictionary *)commandMonitorPeek:(NSDictionary *)parameters
{
    return [self commandMonitor:parameters flush:NO];
}

- (NSDictionary *)commandMonitorFlush:(NSDictionary *)parameters
{
    return [self commandMonitor:parameters flush:YES];
}

#pragma mark - Request Throttle Commands

- (NSDictionary *)commandThrottleMatching:(NSDictionary *)parameters
{
    NSString *reqId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validThrottleRequest:parameters]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelProxyQueryRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        NSTimeInterval responseDelayTime = [parameters[SBTUITunnelProxyQueryResponseTimeKey] doubleValue];
        
        reqId = [SBTProxyURLProtocol throttleRequestsMatching:requestMatch delayResponse:responseDelayTime];
    }
    
    return @{ SBTUITunnelResponseResultKey: reqId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @""};
}

- (NSDictionary *)commandThrottleRemove:(NSDictionary *)parameters
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelProxyQueryRuleKey] options:0];
    NSString *reqId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol throttleRequestsRemoveWithId:reqId] ? @"YES" : @"NO";
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandThrottlesRemoveAll:(NSDictionary *)parameters
{
    [SBTProxyURLProtocol throttleRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Cookie Block Commands

- (NSDictionary *)commandCookiesBlockMatching:(NSDictionary *)parameters
{
    NSString *cookieBlockId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validCookieBlockRequest:parameters]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelCookieBlockMatchRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        
        NSInteger cookieBlockRemoveAfterCount = [parameters[SBTUITunnelCookieBlockQueryIterationsKey] integerValue];
        
        cookieBlockId = [SBTProxyURLProtocol cookieBlockRequestsMatching:requestMatch activeIterations:cookieBlockRemoveAfterCount];
    }
    
    return @{ SBTUITunnelResponseResultKey: cookieBlockId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @"" };
}

#pragma mark - Cookie Block Remove Commands

- (NSDictionary *)commandCookiesBlockRemove:(NSDictionary *)parameters
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelCookieBlockMatchRuleKey] options:0];
    NSString *reqId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol cookieBlockRequestsRemoveWithId:reqId] ? @"YES" : @"NO";
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandCookiesBlockRemoveAll:(NSDictionary *)parameters
{
    [SBTProxyURLProtocol cookieBlockRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - NSUSerDefaults Commands

- (NSDictionary *)commandNSUserDefaultsSetObject:(NSDictionary *)parameters
{
    NSString *objKey = parameters[SBTUITunnelObjectKeyKey];
    NSString *suiteName = parameters[SBTUITunnelUserDefaultSuiteNameKey];
    NSData *objData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelObjectKey] options:0];
    id obj = [NSKeyedUnarchiver unarchiveObjectWithData:objData];
    
    NSString *ret = @"NO";
    if (objKey) {
        NSUserDefaults *userDefault;
        if ([suiteName length] > 0) {
            userDefault = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        } else {
            userDefault = [NSUserDefaults standardUserDefaults];
        }

        [userDefault setObject:obj forKey:objKey];
        ret = [userDefault synchronize] ? @"YES" : @"NO";
    }
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandNSUserDefaultsRemoveObject:(NSDictionary *)parameters
{
    NSString *objKey = parameters[SBTUITunnelObjectKeyKey];
    NSString *suiteName = parameters[SBTUITunnelUserDefaultSuiteNameKey];
    
    NSString *ret = @"NO";
    if (objKey) {
        NSUserDefaults *userDefault;
        if ([suiteName length] > 0) {
            userDefault = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        } else {
            userDefault = [NSUserDefaults standardUserDefaults];
        }
        
        [userDefault removeObjectForKey:objKey];
        ret = [userDefault synchronize] ? @"YES" : @"NO";
    }
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandNSUserDefaultsObject:(NSDictionary *)parameters
{
    NSString *objKey = parameters[SBTUITunnelObjectKeyKey];
    NSString *suiteName = parameters[SBTUITunnelUserDefaultSuiteNameKey];
    
    NSUserDefaults *userDefault;
    if ([suiteName length] > 0) {
        userDefault = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    } else {
        userDefault = [NSUserDefaults standardUserDefaults];
    }
    
    NSObject *obj = [userDefault objectForKey:objKey];
    
    NSData *data;
    if (@available(iOS 11.0, *)) {
        data = [NSKeyedArchiver archivedDataWithRootObject:obj requiringSecureCoding:NO error:nil];
    } else {
        data = [NSKeyedArchiver archivedDataWithRootObject:obj];
    }

    NSString *ret = @"";
    if (data) {
        ret = [data base64EncodedStringWithOptions:0];
    }
    
    return @{ SBTUITunnelResponseResultKey: ret ?: @"" };
}

- (NSDictionary *)commandNSUserDefaultsReset:(NSDictionary *)parameters
{
    NSString *suiteName = parameters[SBTUITunnelUserDefaultSuiteNameKey];
    
    NSUserDefaults *userDefault;
    if ([suiteName length] > 0) {
        userDefault = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    } else {
        userDefault = [NSUserDefaults standardUserDefaults];
    }
    
    [userDefault removePersistentDomainForName:[[NSBundle mainBundle] bundleIdentifier]];
    [userDefault synchronize];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - NSBundle

- (NSDictionary *)commandMainBundleInfoDictionary:(NSDictionary *)parameters
{
    NSData *data;
    if (@available(iOS 11.0, *)) {
        data = [NSKeyedArchiver archivedDataWithRootObject:[[NSBundle mainBundle] infoDictionary] requiringSecureCoding:NO error:nil];
    } else {
        data = [NSKeyedArchiver archivedDataWithRootObject:[[NSBundle mainBundle] infoDictionary]];
    }

    NSString *ret = @"";
    if (data) {
        ret = [data base64EncodedStringWithOptions:0];
    }
    
    return @{ SBTUITunnelResponseResultKey: ret ?: @"" };
}

#pragma mark - Copy Commands

- (NSDictionary *)commandUpload:(NSDictionary *)parameters
{
    NSData *fileData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelUploadDataKey] options:0];
    NSString *destPath = [NSKeyedUnarchiver unarchiveObjectWithData:[[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelUploadDestPathKey] options:0]];
    NSSearchPathDirectory basePath = [parameters[SBTUITunnelUploadBasePathKey] intValue];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(basePath, NSUserDomainMask, YES);
    NSString *path = [[paths firstObject] stringByAppendingPathComponent:destPath];
    
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        
        if (error) {
            return @{ SBTUITunnelResponseResultKey: @"NO" };
        }
    }
    
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil error:&error];
    if (error) {
        return @{ SBTUITunnelResponseResultKey: @"NO" };
    }
    
    
    NSString *ret = [fileData writeToFile:path atomically:YES] ? @"YES" : @"NO";
    
    NSString *debugInfo = [NSString stringWithFormat:@"Writing %ld bytes to file %@", (unsigned long)fileData.length, path ?: @""];
    return @{ SBTUITunnelResponseResultKey: ret, SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandDownload:(NSDictionary *)parameters
{
    NSSearchPathDirectory basePathDirectory = [parameters[SBTUITunnelDownloadBasePathKey] intValue];
    
    NSString *basePath = [NSSearchPathForDirectoriesInDomains(basePathDirectory, NSUserDomainMask, YES) firstObject];
    
    NSArray *basePathContent = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:basePath error:nil];
    
    NSString *filesToMatch = [NSKeyedUnarchiver unarchiveObjectWithData:[[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelDownloadPathKey] options:0]];
    NSPredicate *filterPredicate = [NSPredicate predicateWithFormat:@"SELF like %@", filesToMatch];
    NSArray *matchingFiles = [basePathContent filteredArrayUsingPredicate:filterPredicate];
    
    NSMutableArray *filesDataArr = [NSMutableArray array];
    for (NSString *matchingFile in matchingFiles) {
        NSData *fileData = [NSData dataWithContentsOfFile:[basePath stringByAppendingPathComponent:matchingFile]];
        
        [filesDataArr addObject:fileData];
    }
        
    NSData *filesDataArrData;
    if (@available(iOS 11.0, *)) {
        filesDataArrData = [NSKeyedArchiver archivedDataWithRootObject:filesDataArr requiringSecureCoding:NO error:nil];
    } else {
        filesDataArrData = [NSKeyedArchiver archivedDataWithRootObject:filesDataArr];
    }
    
    NSString *ret = [filesDataArrData base64EncodedStringWithOptions:0];
    
    NSString *debugInfo = [NSString stringWithFormat:@"Found %ld files matching download request@", (unsigned long)matchingFiles.count];
    return @{ SBTUITunnelResponseResultKey: ret ?: @"", SBTUITunnelResponseDebugKey: debugInfo };
}

#pragma mark - Other Commands

- (NSDictionary *)commandSetUIAnimations:(NSDictionary *)parameters
{
    BOOL enableAnimations = [parameters[SBTUITunnelObjectKey] boolValue];
    
    [UIView setAnimationsEnabled:enableAnimations];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandSetUIAnimationSpeed:(NSDictionary *)parameters
{
    NSAssert(![NSThread isMainThread], @"Shouldn't be on main thread");
    
    NSInteger animationSpeed = [parameters[SBTUITunnelObjectKey] integerValue];
    dispatch_sync(dispatch_get_main_queue(), ^() {
        // Replacing [UIView setAnimationsEnabled:] as per
        // https://pspdfkit.com/blog/2016/running-ui-tests-with-ludicrous-speed/
        UIApplication.sharedApplication.keyWindow.layer.speed = animationSpeed;
    });
    
    NSString *debugInfo = [NSString stringWithFormat:@"Setting animationSpeed to %ld", (long)animationSpeed];
    return @{ SBTUITunnelResponseResultKey: @"YES", SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandStartupCompleted:(NSDictionary *)parameters
{
    __weak typeof(self)weakSelf = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.startupCompleted = YES; NSAssert([NSThread isMainThread], @"We synch on main thread");
    });
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - XCUITest scroll extensions

- (BOOL)scrollElementWithIdentifier:(NSString *)elementIdentifier elementClass:(Class)elementClass toRow:(NSInteger)elementRow numberOfSections:(NSInteger (^)(UIView *))sectionsDataSource numberOfRows:(NSInteger (^)(UIView *, NSInteger))rowsDataSource scrollDelegate:(void (^)(UIView *, NSIndexPath *))scrollDelegate;
{
    NSAssert([NSThread isMainThread], @"Call this from main thread!");
    
    // Hacky way to get top-most UIViewController
    UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (rootViewController.presentedViewController != nil) {
        rootViewController = rootViewController.presentedViewController;
    }
    
    NSArray *allViews = [rootViewController.view allSubviews];
    for (UIView *view in [allViews reverseObjectEnumerator]) {
        if ([view isKindOfClass:elementClass]) {
            BOOL withinVisibleBounds = CGRectContainsRect(UIScreen.mainScreen.bounds, [view convertRect:view.bounds toView:nil]);
            
            if (!withinVisibleBounds) {
                continue;
            }
            
            BOOL expectedIdentifier = [view.accessibilityIdentifier isEqualToString:elementIdentifier] || [view.accessibilityLabel isEqualToString:elementIdentifier];
            if (expectedIdentifier) {
                NSInteger numberOfSections = sectionsDataSource(view);
                
                NSInteger processedRows = 0;
                NSInteger targetSection = numberOfSections - 1;
                NSInteger targetRow = rowsDataSource(view, targetSection) - 1;
                NSInteger lastValidSection = -1;
                NSInteger lastValidSectionRows = -1;
                for (NSInteger section = 0; section < numberOfSections; section++) {
                    NSInteger rowsInSection = rowsDataSource(view, section);
                    if (rowsInSection > 0) {
                        lastValidSection = section;
                        lastValidSectionRows = rowsInSection - 1;
                    }
                    if (processedRows + rowsInSection > elementRow) {
                        targetSection = section;
                        targetRow = elementRow - processedRows;
                        break;
                    }
                    
                    processedRows += rowsInSection;
                }

                NSIndexPath *targetIndexPath = [NSIndexPath indexPathForRow:targetRow inSection:targetSection];
                if (targetIndexPath.row >= 0 && targetIndexPath.section >= 0) {
                    scrollDelegate(view, targetIndexPath);
                } else {
                    NSIndexPath *targetIndexPath = [NSIndexPath indexPathForRow:lastValidSectionRows inSection:lastValidSection];
                    if (targetIndexPath.row >= 0 && targetIndexPath.section >= 0) {
                        scrollDelegate(view, targetIndexPath);
                    }
                }
                
                return YES;
            }
        }
    }
    
    return NO;
}

- (NSDictionary *)commandScrollScrollView:(NSDictionary *)parameters
{
    NSString *elementIdentifier = parameters[SBTUITunnelObjectKey];
    NSString *targetElementIdentifier = parameters[SBTUITunnelObjectValueKey];
    BOOL animated = [parameters[SBTUITunnelObjectAnimatedKey] boolValue];
    
    return [self commandScrollScrollViewWithIdentifier:elementIdentifier targetIdentifier:targetElementIdentifier animated:animated];
}

- (NSDictionary *)commandScrollScrollViewWithIdentifier:(NSString *)elementIdentifier targetIdentifier:(NSString *)targetElementIdentifier animated:(BOOL)animated
{
    __block BOOL result = NO;
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Hacky way to get top-most UIViewController
        UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (rootViewController.presentedViewController != nil) {
            rootViewController = rootViewController.presentedViewController;
        }
        
        NSArray *allViews = [rootViewController.view allSubviews];
        for (UIView *view in [allViews reverseObjectEnumerator]) {
            if ([view isKindOfClass:[UIScrollView class]]) {
                BOOL withinVisibleBounds = CGRectContainsRect(UIScreen.mainScreen.bounds, [view convertRect:view.bounds toView:nil]);
                
                if (!withinVisibleBounds) {
                    continue;
                }
                
                BOOL expectedIdentifier = [view.accessibilityIdentifier isEqualToString:elementIdentifier] || [view.accessibilityLabel isEqualToString:elementIdentifier];
                if (expectedIdentifier) {
                    UIScrollView *scrollView = (UIScrollView *)view;
                                        
                    while (!result) {
                        NSArray *allScrollViewViews = [scrollView allSubviews];
                        for (UIView *scrollViewView in [allScrollViewViews reverseObjectEnumerator]) {
                            BOOL expectedTargetIdentifier = [scrollViewView.accessibilityIdentifier isEqualToString:targetElementIdentifier] || [scrollViewView.accessibilityLabel isEqualToString:targetElementIdentifier];
                            
                            if (expectedTargetIdentifier) {
                                CGRect frameInScrollView = [scrollViewView convertRect:scrollView.bounds toView:nil];
                                CGFloat targetContentOffsetY = MAX(0.0, frameInScrollView.origin.y - view.frame.size.height / 2);
                                
                                [scrollView setContentOffset:CGPointMake(0, targetContentOffsetY) animated:animated];
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    dispatch_semaphore_signal(sem);
                                });
                                
                                result = YES;
                                break;
                            }
                        }
                        
                        if (result) {
                            break;
                        } else {
                            if (scrollView.contentOffset.y < scrollView.contentSize.height)  {
                                CGFloat targetContentOffsetY = MIN(scrollView.contentSize.height, scrollView.contentOffset.y + scrollView.frame.size.height);
                                
                                [scrollView setContentOffset:CGPointMake(0, targetContentOffsetY) animated:animated];
                                NSTimeInterval start = CFAbsoluteTimeGetCurrent();
                                while (CFAbsoluteTimeGetCurrent() - start < 0.25) {
                                    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                                }
                            } else {
                                break;
                            }
                        }
                    }
                }
            }
            
            if (result) { break; }
        }
    });
    
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC))) != 0) {}
    
    NSString *debugInfo = result ? @"" : @"element not found!";
    
    return @{ SBTUITunnelResponseResultKey: result ? @"YES": @"NO", SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandScrollTableView:(NSDictionary *)parameters
{
    NSString *elementIdentifier = parameters[SBTUITunnelObjectKey];
    NSString *targetDestination = parameters[SBTUITunnelObjectValueKey];
    NSString *scrollType = parameters[SBTUITunnelXCUIExtensionScrollType];
    BOOL animated = [parameters[SBTUITunnelObjectAnimatedKey] boolValue];
    
    if ([scrollType isEqualToString:@"identifier"]) {
        return [self commandScrollScrollViewWithIdentifier:elementIdentifier targetIdentifier:targetDestination animated:animated];
    } else {
        return [self commandScrollTableViewWithIdentifier:elementIdentifier targetRow:[targetDestination intValue] animated:animated];
    }
}
    
- (NSDictionary *)commandScrollTableViewWithIdentifier:(NSString *)tableIdentifier targetRow:(NSInteger)elementRow animated:(BOOL)animated
{
    __block BOOL result = NO;
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    __weak typeof(self)weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        result = [weakSelf scrollElementWithIdentifier:tableIdentifier
                                      elementClass:[UITableView class]
                                             toRow:elementRow
                                  numberOfSections:^NSInteger (UIView *view) {
                                      UITableView *tableView = (UITableView *)view;
                                      if ([tableView.dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]) {
                                          return [tableView.dataSource numberOfSectionsInTableView:tableView];
                                      } else {
                                          return 1;
                                      }
                                  }
                                      numberOfRows:^NSInteger (UIView *view, NSInteger section) {
                                          UITableView *tableView = (UITableView *)view;
                                          if ([tableView.dataSource respondsToSelector:@selector(tableView:numberOfRowsInSection:)]) {
                                              return [tableView.dataSource tableView:tableView numberOfRowsInSection:section];
                                          } else {
                                              return 0;
                                          }
                                      }
                                    scrollDelegate:^void (UIView *view, NSIndexPath *indexPath) {
                                        UITableView *tableView = (UITableView *)view;
                                        
                                        [tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionTop animated:animated];
                                        [weakSelf runMainLoopForSeconds:0.5];
                                        
                                        __block int iteration = 0;
                                        repeating_dispatch_after((int64_t)(0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                                            if ([tableView.indexPathsForVisibleRows containsObject:indexPath] || iteration == 10) {
                                                return YES;
                                            } else {
                                                iteration++;
                                                [tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionTop animated:animated];
                                                [weakSelf runMainLoopForSeconds:0.5];
                                                return NO;
                                            }
                                        });
                                    }];
        
        dispatch_semaphore_signal(sem);
    });
    
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC))) != 0) {}
    
    NSString *debugInfo = result ? @"" : @"element not found!";
    
    return @{ SBTUITunnelResponseResultKey: result ? @"YES": @"NO", SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandScrollCollectionView:(NSDictionary *)parameters
{
    NSString *elementIdentifier = parameters[SBTUITunnelObjectKey];
    NSString *targetDestination = parameters[SBTUITunnelObjectValueKey];
    NSString *scrollType = parameters[SBTUITunnelXCUIExtensionScrollType];
    BOOL animated = [parameters[SBTUITunnelObjectAnimatedKey] boolValue];
    
    if ([scrollType isEqualToString:@"identifier"]) {
        return [self commandScrollScrollViewWithIdentifier:elementIdentifier targetIdentifier:targetDestination animated:animated];
    } else {
        return [self commandScrollCollectionViewWithIdentifier:elementIdentifier targetRow:[targetDestination intValue] animated:animated];
    }
}
    
- (NSDictionary *)commandScrollCollectionViewWithIdentifier:(NSString *)collectionIdentifier targetRow:(NSInteger)elementRow animated:(BOOL)animated
{
    __block BOOL result = NO;
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    __weak typeof(self)weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        result = [weakSelf scrollElementWithIdentifier:collectionIdentifier
                                      elementClass:[UICollectionView class]
                                             toRow:elementRow
                                  numberOfSections:^NSInteger (UIView *view) {
                                      UICollectionView *collectionView = (UICollectionView *)view;
                                      if ([collectionView.dataSource respondsToSelector:@selector(numberOfSectionsInCollectionView:)]) {
                                          return [collectionView.dataSource numberOfSectionsInCollectionView:collectionView];
                                      } else {
                                          return 1;
                                      }
                                  }
                                      numberOfRows:^NSInteger (UIView *view, NSInteger section) {
                                          UICollectionView *collectionView = (UICollectionView *)view;
                                          if ([collectionView.dataSource respondsToSelector:@selector(collectionView:numberOfItemsInSection:)]) {
                                              return [collectionView.dataSource collectionView:collectionView numberOfItemsInSection:section];
                                          } else {
                                              return 0;
                                          }
                                      }
                                    scrollDelegate:^void (UIView *view, NSIndexPath *indexPath) {
                                        UICollectionView *collectionView = (UICollectionView *)view;
                                        
                                        [collectionView scrollToItemAtIndexPath:indexPath atScrollPosition:UICollectionViewScrollPositionTop animated:animated];
                                        [weakSelf runMainLoopForSeconds:0.5];
                                        
                                        __block int iteration = 0;
                                        repeating_dispatch_after((int64_t)(0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                                            if ([collectionView.indexPathsForVisibleItems containsObject:indexPath] || iteration == 10) {
                                                return YES;
                                            } else {
                                                iteration++;
                                                [collectionView scrollToItemAtIndexPath:indexPath atScrollPosition:UICollectionViewScrollPositionTop animated:animated];
                                                [weakSelf runMainLoopForSeconds:0.5];
                                                return NO;
                                            }
                                        });
                                    }];
        
        dispatch_semaphore_signal(sem);
    });
    
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC))) != 0) {}
    
    NSString *debugInfo = result ? @"" : @"element not found!";
    
    return @{ SBTUITunnelResponseResultKey: result ? @"YES": @"NO", SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandForceTouchPopView:(NSDictionary *)parameters
{
    NSString *elementIdentifier = parameters[SBTUITunnelObjectKey];

    __block BOOL result = NO;
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Hacky way to get top-most UIViewController
        UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (rootViewController.presentedViewController != nil) {
            rootViewController = rootViewController.presentedViewController;
        }
        
        NSArray *allViews = [rootViewController.view allSubviews];
        for (UIView *view in [allViews reverseObjectEnumerator]) {
            BOOL expectedIdentifier = [view.accessibilityIdentifier isEqualToString:elementIdentifier] || [view.accessibilityLabel isEqualToString:elementIdentifier];
            if (expectedIdentifier) {
                UIView *registeredView = [UIViewController previewingRegisteredViewForView:view];
                if (registeredView == nil) { break; }
                
                id<UIViewControllerPreviewingDelegate> sourceDelegate = [UIViewController previewingDelegateForRegisteredView:registeredView];
                if (sourceDelegate == nil) { break; }

                SBTAnyViewControllerPreviewing *context = [[SBTAnyViewControllerPreviewing alloc] initWithSourceView:registeredView delegate:sourceDelegate];
                UIViewController *viewController = [sourceDelegate previewingContext:context viewControllerForLocation:view.center];
                if (viewController == nil) { break; }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [sourceDelegate previewingContext:context commitViewController:viewController];
                    dispatch_semaphore_signal(sem);
                });
            }
        }
    });
    
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC))) != 0) {
        result = NO;
    }
    
    NSString *debugInfo = result ? @"" : @"element not found!";
    
    return @{ SBTUITunnelResponseResultKey: result ? @"YES": @"NO", SBTUITunnelResponseDebugKey: debugInfo };
}

- (void)runMainLoopForSeconds:(NSTimeInterval)timeinterval
{
    NSTimeInterval start = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - start < timeinterval) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

#pragma mark - XCUITest CLLocation extensions

- (NSDictionary *)commandCoreLocationStubbing:(NSDictionary *)parameters
{
    BOOL stubSystemLocation = [parameters[SBTUITunnelObjectValueKey] isEqualToString:@"YES"];
    if (stubSystemLocation) {
        [CLLocationManager loadSwizzlesWithInstanceHashTable:self.coreLocationActiveManagers];
    } else {
        [CLLocationManager removeSwizzles];
    }
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandCoreLocationStubAuthorizationStatus:(NSDictionary *)parameters
{
    NSString *authorizationStatus = parameters[SBTUITunnelObjectValueKey];
    
    [CLLocationManager setStubbedAuthorizationStatus:authorizationStatus];
    for (CLLocationManager *locationManager in self.coreLocationActiveManagers.keyEnumerator.allObjects) {
        [locationManager.stubbedDelegate locationManager:locationManager didChangeAuthorizationStatus:authorizationStatus.intValue];
        #if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
        if (@available(iOS 14.0, *)) {
            [locationManager.stubbedDelegate locationManagerDidChangeAuthorization:locationManager];
    }
        #endif
    }

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandCoreLocationStubAccuracyAuthorization:(NSDictionary *)parameters API_AVAILABLE(ios(14))
{
    #if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
        NSString *accuracyAuthorization = parameters[SBTUITunnelObjectValueKey];
        
        [CLLocationManager setStubbedAccuracyAuthorization:accuracyAuthorization];
        for (CLLocationManager *locationManager in self.coreLocationActiveManagers.keyEnumerator.allObjects) {
            [locationManager.stubbedDelegate locationManagerDidChangeAuthorization:locationManager];
        }
    #endif

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandCoreLocationStubServiceStatus:(NSDictionary *)parameters
{
    NSString *serviceStatus = parameters[SBTUITunnelObjectValueKey];
    
    [self.coreLocationStubbedServiceStatus setString:serviceStatus];

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandCoreLocationNotifyUpdate:(NSDictionary *)parameters
{
    NSData *locationsData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelObjectKey] options:0];
    NSArray<CLLocation *> *locations = [NSKeyedUnarchiver unarchiveObjectWithData:locationsData];
    
    for (CLLocationManager *locationManager in self.coreLocationActiveManagers.keyEnumerator.allObjects) {
        [locationManager.stubbedDelegate locationManager:locationManager didUpdateLocations:locations];
    }

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandCoreLocationNotifyFailure:(NSDictionary *)parameters
{
    NSData *paramData = [[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelObjectKey] options:0];
    NSError *error = [NSKeyedUnarchiver unarchiveObjectWithData:paramData];
    
    for (CLLocationManager *locationManager in self.coreLocationActiveManagers.keyEnumerator.allObjects) {
        [locationManager.stubbedDelegate locationManager:locationManager didFailWithError:error];
    }

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - XCUITest UNUserNotificationCenter extensions

- (NSDictionary *)commandNotificationCenterStubbing:(NSDictionary *)parameters
{
    if (@available(iOS 10.0, *)) {
        BOOL stubNotificationCenter = [parameters[SBTUITunnelObjectValueKey] isEqualToString:@"YES"];
        if (stubNotificationCenter) {
            [UNUserNotificationCenter loadSwizzlesWithAuthorizationStatus:self.notificationCenterStubbedAuthorizationStatus];
        } else {
            [UNUserNotificationCenter removeSwizzles];
        }
    }
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandNotificationCenterStubAuthorizationStatus:(NSDictionary *)parameters
{
    NSString *authorizationStatus = parameters[SBTUITunnelObjectValueKey];
    
    [self.notificationCenterStubbedAuthorizationStatus setString:authorizationStatus];

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - XCUITest WKWebView stubbing

- (NSDictionary *)commandWkWebViewStubbing:(NSDictionary *)parameters
{
    BOOL stubWkWebView = [parameters[SBTUITunnelObjectValueKey] isEqualToString:@"YES"];
    if (stubWkWebView) {
        [self enableUrlProtocolInWkWebview];
    } else {
        [self disableUrlProtocolInWkWebview];
    }
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Custom Commands

+ (NSMutableDictionary *)customCommands
{
    static NSMutableDictionary *customCommandsDict = nil;
    
    if (customCommandsDict == nil) {
        customCommandsDict = [NSMutableDictionary dictionary];
    }
    
    return customCommandsDict;
}

+ (void)registerCustomCommandNamed:(NSString *)commandName block:(NSObject *(^)(NSObject *object))block
{
    if ([self respondsToSelector:NSSelectorFromString([commandName stringByAppendingString:@":"])]) {
        NSAssert(NO, @"Command name already taken");
    }
    if ([[self customCommands] objectForKey:commandName]) {
        NSAssert(NO, @"Custom command already registered, did you forgot to unregister it?");
    }
    
    [[self customCommands] setObject:block forKey:commandName];
}

+ (void)unregisterCommandNamed:(NSString *)commandName
{
    [[self customCommands] removeObjectForKey:commandName];
}

#pragma mark - Helper Methods

- (void)processLaunchOptionsIfNeeded
{
    if ([[NSProcessInfo processInfo].arguments containsObject:SBTUITunneledApplicationLaunchOptionResetFilesystem]) {
        [self deleteAppData];
        [self commandNSUserDefaultsReset:nil];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:SBTUITunneledApplicationLaunchOptionDisableUITextFieldAutocomplete]) {
        [UITextField disableAutocompleteOnce];
    }
}

- (BOOL)validStubRequest:(NSDictionary *)parameters
{
    if (![[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelStubMatchRuleKey] options:0]) {
        NSLog(@"[SBTUITestTunnel] Invalid stubRequest received!");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validRewriteRequest:(NSDictionary *)parameters
{
    if (![[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelRewriteMatchRuleKey] options:0]) {
        NSLog(@"[SBTUITestTunnel] Invalid rewriteRequest received!");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validMonitorRequest:(NSDictionary *)parameters
{
    if (![[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelProxyQueryRuleKey] options:0]) {
        NSLog(@"[SBTUITestTunnel] Invalid monitorRequest received!");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validThrottleRequest:(NSDictionary *)parameters
{
    if (parameters[SBTUITunnelProxyQueryResponseTimeKey] != nil && ![[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelProxyQueryRuleKey] options:0]) {
        NSLog(@"[SBTUITestTunnel] Invalid throttleRequest received!");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validCookieBlockRequest:(NSDictionary *)parameters
{
    if (![[NSData alloc] initWithBase64EncodedString:parameters[SBTUITunnelCookieBlockMatchRuleKey] options:0]) {
        NSLog(@"[SBTUITestTunnel] Invalid cookieBlockRequest received!");
        
        return NO;
    }
    
    return YES;
}

#pragma mark - Helper Functions

// https://gist.github.com/michalzelinka/67adfa0142767575194f
- (void)deleteAppData
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *folders = @[[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject],
                                     [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject],
                                     [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject],
                                     NSTemporaryDirectory()];
    
    NSError *error = nil;
    for (NSString *folder in folders) {
        for (NSString *file in [fm contentsOfDirectoryAtPath:folder error:&error]) {
            [fm removeItemAtPath:[folder stringByAppendingPathComponent:file] error:&error];
        }
    }
}

#pragma mark - Connectionless

+ (NSString *)performCommand:(NSString *)commandName params:(NSDictionary<NSString *, NSString *> *)params
{
    NSString *commandString = [commandName stringByAppendingString:@":"];
    SEL commandSelector = NSSelectorFromString(commandString);
    
    NSMutableDictionary *unescapedParams = [params mutableCopy];
    for (NSString *key in params) {
        unescapedParams[key] = [unescapedParams[key] stringByRemovingPercentEncoding];
    }
        
    NSDictionary *response = nil;
    
    if (![self.sharedInstance processCustomCommandIfNecessary:commandName parameters:unescapedParams returnObject:&response]) {
        if (![self.sharedInstance respondsToSelector:commandSelector]) {
            NSAssert(NO, @"[UITestTunnelServer] Unhandled/unknown command! %@", commandName);
        }
        
        IMP imp = [self.sharedInstance methodForSelector:commandSelector];
        
        NSLog(@"[SBTUITestTunnel] Executing command '%@'", commandName);
        
        NSDictionary * (*func)(id, SEL, NSDictionary *) = (void *)imp;
        response = func(self.sharedInstance, commandSelector, unescapedParams);
    }
    
    return response[SBTUITunnelResponseResultKey];
}

+ (void)_connectionlessReset
{
    [self.sharedInstance reset];
}

- (void)reset
{
    [SBTProxyURLProtocol reset];
    [[self customCommands] removeAllObjects];
}

- (void)enableUrlProtocolInWkWebview
{
    Class cls = NSClassFromString(@"WKBrowsingContextController");
    SEL sel = NSSelectorFromString(@"registerSchemeForCustomProtocol:");
    if ([cls respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [cls performSelector:sel withObject:@"http"];
        [cls performSelector:sel withObject:@"https"];
#pragma clang diagnostic pop
    }
}

- (void)disableUrlProtocolInWkWebview
{
    Class cls = NSClassFromString(@"WKBrowsingContextController");
    SEL sel = NSSelectorFromString(@"unregisterSchemeForCustomProtocol:");
    if ([cls respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [cls performSelector:sel withObject:@"http"];
        [cls performSelector:sel withObject:@"https"];
#pragma clang diagnostic pop
    }
}

@end

#endif
