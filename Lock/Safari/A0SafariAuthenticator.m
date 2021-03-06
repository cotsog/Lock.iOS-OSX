// A0SafariAuthenticator.m
//
// Copyright (c) 2015 Auth0 (http://auth0.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "A0SafariAuthenticator.h"
#import "A0SafariSession.h"
#import "A0Lock.h"
#import "A0AuthParameters.h"
#import "A0Errors.h"
#import "A0LockNotification.h"
#import "NSDictionary+A0QueryParameters.h"
#import "A0Token.h"
#import "NSError+A0APIError.h"
#import "A0ModalPresenter.h"
#import <SafariServices/SafariServices.h>
#import "Constants.h"

@interface A0SafariAuthenticator () <SFSafariViewControllerDelegate>
@property (strong, nonatomic) A0SafariSession *session;
@property (strong, nonatomic) A0ModalPresenter *presenter;
@property (copy, nonatomic) A0SafariSessionAuthentication onAuthentication;
@property (strong, nonatomic) id universalLinkObserver;
@end

@implementation A0SafariAuthenticator

AUTH0_DYNAMIC_LOGGER_METHODS

- (instancetype)initWithLock:(A0Lock *)lock connectionName:(NSString *)connectionName useUniversalLink:(BOOL)useUniversalLink {
    return [self initWithSession:[[A0SafariSession alloc] initWithLock:lock connectionName:connectionName useUniversalLink:useUniversalLink]
                  modalPresenter:[[A0ModalPresenter alloc] init]];
}

- (instancetype)initWithLock:(A0Lock *)lock connectionName:(NSString *)connectionName {
    return [self initWithLock:lock connectionName:connectionName useUniversalLink:YES];
}

- (instancetype)initWithSession:(A0SafariSession *)session modalPresenter:(A0ModalPresenter *)presenter {
    self = [super init];
    if (self) {
        _session = session;
        _presenter = presenter;
        [self clearSessions];
        __weak A0SafariAuthenticator *weakSelf = self;
        _universalLinkObserver = [[NSNotificationCenter defaultCenter] addObserverForName:A0LockNotificationUniversalLinkReceived object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
            NSURL *link = note.userInfo[A0LockNotificationUniversalLinkParameterKey];
            [weakSelf handleURL:link sourceApplication:nil];
        }];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self.universalLinkObserver];
    self.universalLinkObserver = nil;
}

- (void)authenticateWithParameters:(A0AuthParameters *)parameters
                           success:(A0IdPAuthenticationBlock)success
                           failure:(A0IdPAuthenticationErrorBlock)failure {
    A0AuthParameters *authenticationParameters = parameters ?: [A0AuthParameters newDefaultParams];
    NSURL *url = [self.session authorizeURLWithParameters:[authenticationParameters asAPIPayload]];
    A0LogDebug(@"Opening URL %@ in SFSafariViewController", url);
    SFSafariViewController *controller = [[SFSafariViewController alloc] initWithURL:url];
    controller.delegate = self;
    [self.presenter presentController:controller completion:nil];
    self.onAuthentication = [self.session authenticationBlockWithSuccess:success failure:failure];
}

- (BOOL)handleURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication {
    BOOL shouldHandle = [url.path hasPrefix:self.session.callbackURL.path];
    if (shouldHandle) {
        A0LogDebug(@"Handling callback URL %@", url);
        [self handleAuthorizeResultInURL:url];
    }
    return shouldHandle;
}

- (NSString *)identifier {
    return self.session.connectionName;
}

- (void)clearSessions {
    self.onAuthentication = ^(NSError *error, A0Token *token) {};
}

#pragma mark - Utility methods

- (void)handleAuthorizeResultInURL:(NSURL *)url {
    NSString *queryString = url.query ?: url.fragment;
    NSDictionary *params = [NSDictionary fromQueryString:queryString];
    A0LogDebug(@"Received params %@ from URL %@", params, url);
    NSString *errorMessage = params[@"error"];
    A0Token *token;
    NSError *error;
    if (errorMessage) {
        A0LogError(@"URL contained error message %@", errorMessage);
        NSString *localizedDescription = [NSString stringWithFormat:@"Failed to authenticate user with connection %@", self.session.connectionName];
        error = [NSError errorWithCode:A0ErrorCodeAuthenticationFailed
                           description:A0LocalizedString(localizedDescription)
                               payload:params];
    } else {
        NSString *accessToken = params[@"access_token"];
        NSString *idToken = params[@"id_token"];
        NSString *tokenType = params[@"token_type"];
        NSString *refreshToken = params[@"refresh_token"];
        if (idToken) {
            token = [[A0Token alloc] initWithAccessToken:accessToken idToken:idToken tokenType:tokenType refreshToken:refreshToken];
            A0LogVerbose(@"Obtained token from URL: %@", token);
        } else {
            A0LogError(@"Failed to obtain id_token from URL %@", url);
            error = [A0Errors auth0InvalidConfigurationForConnectionName:self.session.connectionName];
        }
    }
    self.onAuthentication(error, token);
}

#pragma mark - SFSafariViewControllerDelegate

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.onAuthentication([A0Errors auth0CancelledForConnectionName:self.session.connectionName], nil);
        [self clearSessions];
    });
}

@end
