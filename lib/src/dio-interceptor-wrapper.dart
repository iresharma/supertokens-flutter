import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mutex/mutex.dart';
import 'package:supertokens_flutter/src/anti-csrf.dart';
import 'package:supertokens_flutter/src/constants.dart';
import 'package:supertokens_flutter/src/cookie-store.dart';
import 'package:supertokens_flutter/src/errors.dart';
import 'package:supertokens_flutter/src/front-token.dart';
import 'package:supertokens_flutter/src/supertokens-http-client.dart';
import 'package:supertokens_flutter/src/supertokens.dart';
import 'package:supertokens_flutter/src/utilities.dart';

class SuperTokensInterceptorWrapper extends Interceptor {
  ReadWriteMutex _refreshAPILock = ReadWriteMutex();
  final Dio client;
  late dynamic userSetCookie;
  late LocalSessionState _preRequestLocalSessionState;

  SuperTokensInterceptorWrapper({required this.client});

  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    if (!SuperTokens.isInitCalled) {
      handler.reject(DioError(
        requestOptions: options,
        type: DioErrorType.other,
        error: SuperTokensException(
            "SuperTokens.initialise must be called before using Client"),
      ));
      return;
    }

    if (!Utils.shouldDoInterceptions(
        options.uri.toString(),
        SuperTokens.config.apiDomain,
        SuperTokens.config.sessionTokenBackendDomain)) {
      super.onRequest(options, handler);
    }

    if (Client.cookieStore == null) {
      Client.cookieStore = SuperTokensCookieStore();
    }

    if (SuperTokensUtils.getApiDomain(options.uri.toString()) !=
        SuperTokens.config.apiDomain) {
      super.onRequest(options, handler);
    }

    if (SuperTokensUtils.getApiDomain(options.uri.toString()) ==
        SuperTokens.refreshTokenUrl) {
      super.onRequest(options, handler);
    }

    _preRequestLocalSessionState =
        await SuperTokensUtils.getLocalSessionState();
    String? antiCSRFToken = await AntiCSRF.getToken(
        _preRequestLocalSessionState.lastAccessTokenUpdate);

    if (antiCSRFToken != null) {
      options.headers[antiCSRFHeaderKey] = antiCSRFToken;
    }

    userSetCookie = options.headers[HttpHeaders.cookieHeader];

    String uriForCookieString = options.uri.toString();
    if (!uriForCookieString.endsWith("/")) {
      uriForCookieString += "/";
    }

    String? newCookiesToAdd = await Client.cookieStore
        ?.getCookieHeaderStringForRequest(Uri.parse(uriForCookieString));
    String? existingCookieHeader = options.headers[HttpHeaders.cookieHeader];

    // If the request already has a "cookie" header, combine it with persistent cookies
    if (existingCookieHeader != null) {
      options.headers[HttpHeaders.cookieHeader] =
          "$existingCookieHeader;${newCookiesToAdd ?? ""}";
    } else {
      options.headers[HttpHeaders.cookieHeader] = newCookiesToAdd ?? "";
    }

    options.headers.addAll({'st-auth-mode': 'cookie'});

    var oldValidate = options.validateStatus;
    options.validateStatus = (status) {
      if (status != null &&
          status == SuperTokens.config.sessionExpiredStatusCode) {
        return true;
      }
      return oldValidate(status);
    };

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    _refreshAPILock.acquireWrite();
    await saveTokensFromHeaders(response);
    String? frontTokenFromResponse =
        response.headers.map[frontTokenHeaderKey]?.first.toString();
    SuperTokensUtils.fireSessionUpdateEventsIfNecessary(
      wasLoggedIn:
          _preRequestLocalSessionState.status == LocalSessionStateStatus.EXISTS,
      status: response.statusCode!,
      frontTokenFromResponse: frontTokenFromResponse,
    );
    List<dynamic>? setCookieFromResponse =
        response.headers.map[HttpHeaders.setCookieHeader];
    setCookieFromResponse?.forEach((element) async {
      await Client.cookieStore
          ?.saveFromSetCookieHeader(response.realUri, element);
    });

    try {
      if (response.statusCode == SuperTokens.sessionExpiryStatusCode) {
        UnauthorisedResponse shouldRetry =
            await Client.onUnauthorisedResponse(_preRequestLocalSessionState);
        if (shouldRetry.status == UnauthorisedStatus.RETRY) {
          RequestOptions requestOptions = response.requestOptions;
          requestOptions.headers[HttpHeaders.cookieHeader] = userSetCookie;
          Response<dynamic> res = await client.fetch(requestOptions);
          List<dynamic>? setCookieFromResponse =
              res.headers.map[HttpHeaders.setCookieHeader];
          setCookieFromResponse?.forEach((element) async {
            await Client.cookieStore
                ?.saveFromSetCookieHeader(res.realUri, element);
          });
          await saveTokensFromHeaders(res);
          handler.next(res);
        } else {
          if (shouldRetry.exception != null) {
            handler.reject(
              DioError(
                  requestOptions: response.requestOptions,
                  error: SuperTokensException(shouldRetry.exception!.message),
                  type: DioErrorType.other),
            );
            return;
          } else {
            _refreshAPILock.release();
            return handler.next(response);
          }
        }
      } else {
        _refreshAPILock.release();
        return handler.next(response);
      }
    } on DioError catch (e) {
      handler.reject(e);
    } catch (e) {
      handler.reject(
        DioError(
            requestOptions: response.requestOptions,
            type: DioErrorType.other,
            error: e),
      );
    } finally {
      LocalSessionState localSessionState =
          await SuperTokensUtils.getLocalSessionState();
      if (localSessionState.status == LocalSessionStateStatus.NOT_EXISTS) {
        await AntiCSRF.removeToken();
        await FrontToken.removeToken();
      }
    }
  }

  Future<void> saveTokensFromHeaders(Response response) async {
    String? frontTokenFromResponse =
        response.headers.map[frontTokenHeaderKey]?.first.toString();
    if (frontTokenFromResponse != null) {
      await FrontToken.setItem(frontTokenFromResponse);
    }

    String? antiCSRFFromResponse =
        response.headers.map[antiCSRFHeaderKey]?.first.toString();
    if (antiCSRFFromResponse != null) {
      LocalSessionState localSessionState =
          await SuperTokensUtils.getLocalSessionState();
      await AntiCSRF.setToken(
        antiCSRFFromResponse,
        localSessionState.lastAccessTokenUpdate,
      );
    }
  }
}
