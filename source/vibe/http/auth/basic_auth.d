/**
	Implements HTTP Basic Auth.

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.http.auth.basic_auth;

import vibe.http.server;
import vibe.core.log;

import std.base64;
import std.exception;
import std.string;


HttpServerRequestDelegate performBasicAuth(string realm, bool delegate(string user, string name) pwcheck)
{
	void handleRequest(HttpServerRequest req, HttpServerResponse res)
	{
		auto pauth = "Authorization" in req.headers;

		if( pauth && (*pauth).startsWith("Basic ") ){
			string user_pw = cast(string)Base64.decode((*pauth)[6 .. $]);

			auto idx = user_pw.indexOf(":");
			enforce(idx >= 0, "Invalid auth string format!");
			string user = user_pw[0 .. idx];
			string password = user_pw[idx+1 .. $];

			if( pwcheck(user, password) ){
				req.username = user;
				// let the next stage handle the request
				return;
			}
		}

		// else output an error page
		res.statusCode = HttpStatus.Unauthorized;
		res.contentType = "text/plain";
		res.headers["WWW-Authenticate"] = "Basic realm=\""~realm~"\"";
		res.bodyWriter.write("Authorization required");
	}
	return &handleRequest;
}

string performBasicAuth(HttpServerRequest req, HttpServerResponse res, string realm, bool delegate(string user, string name) pwcheck)
{
	auto pauth = "Authorization" in req.headers;
	if( pauth && (*pauth).startsWith("Basic ") ){
		string user_pw = cast(string)Base64.decode((*pauth)[6 .. $]);

		auto idx = user_pw.indexOf(":");
		enforce(idx >= 0, "Invalid auth string format!");
		string user = user_pw[0 .. idx];
		string password = user_pw[idx+1 .. $];

		if( pwcheck(user, password) ){
			req.username = user;
			return user;
		}
	}

	res.headers["WWW-Authenticate"] = "Basic realm=\""~realm~"\"";
	throw new HttpServerError(HttpStatus.Unauthorized);
}

void addBasicAuth(HttpRequest req, string user, string password)
{
	string pwstr = user ~ ":" ~ password;
	string authstr = cast(string)Base64.encode(cast(ubyte[])pwstr);
	req.headers["Authorization"] = "Basic " ~ authstr;
}