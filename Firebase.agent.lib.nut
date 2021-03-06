// MIT License
//
// Copyright 2015-2018 Electric Imp
//
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.


const FB_KEEP_ALIVE_SEC               = 60; // Timeout for streaming
const FB_DEFAULT_BACK_OFF_TIMEOUT_SEC = 60; // Backoff time

// Firebase authentication type
enum FIREBASE_AUTH_TYPE {
    // Legacy tokens authentication (https://firebase.google.com/docs/database/rest/auth#legacy_tokens)
    LEGACY_TOKEN,
    // Google OAuth2 access tokens authentication (https://firebase.google.com/docs/database/rest/auth#google_oauth2_access_tokens)
    OAUTH2_TOKEN,
    // Firebase ID tokens authentication (https://firebase.google.com/docs/database/rest/auth#firebase_id_tokens)
    FIREBASE_ID_TOKEN
};

class Firebase {

    static VERSION = "3.2.0";

    // Firebase
    _db = null;                 // The name of your firebase instance
    _auth = null;               // _auth key (if auth is enabled)
    _authType = null;           // type of authentication
    _authProvider = null;       // external provider of access tokens
    _baseUrl = null;            // base url (may change with 307 responses)
    _domain = null;

    // Debugging
    _debug = null;              // Debug flag, when true, class will log errors

    // REST
    _defaultHeaders = { "Content-Type": "application/json" };

    // Streaming
    _streamingHeaders = { "accept": "text/event-stream" };
    _streamingRequest = null;   // The request object of the streaming request
    _data = null;               // Current snapshot of what we're streaming
    _callbacks = null;          // List of _callbacks for streaming request
    _keepAliveTimer = null;     // Wakeup timer that watches for a dead Firebase socket
    _bufferedInput = null;      //  Buffer used for reading streamed data

    // General
    _promiseIncluded = null;    // indicate if Promise library is included
    _backOffTimer = null;       // Timer used to backoff stream if FB is getting hammered
    _tooManyReqTimer = false;   // Timer used to reject requests if FB is getting hammered
    _tooManyReqCounter = 1;     // Counter used to backoff incoming request

    /***************************************************************************
     * Constructor
     * Returns: Firebase object
     * Parameters:
     *      db      - the name of the Firesbase instance
     *      auth    - an optional authentication token
     *      domain  - base domain name for the Firebase instance.
     *                  Defaults to "firebaseio.com". Is used to build
     *                  the base Firebase database URL, for example:
     *                  https://username.firebaseio.com
     *      debug   - turns the debug logs on or off, true by default
     **************************************************************************/
    constructor(db, auth = null, domain = "firebaseio.com", debug = true) {
        _debug = debug;

        _db = db;
        _domain = domain;
        _baseUrl = "https://" + _db + "." + domain;
        _auth = auth;
        _authType = FIREBASE_AUTH_TYPE.LEGACY_TOKEN;

        _bufferedInput = "";

        _data = {};

        _callbacks = {};

        _promiseIncluded = ("Promise" in getroottable());
        _backOffTimer = FB_DEFAULT_BACK_OFF_TIMEOUT_SEC;
    }

    /***************************************************************************
     * Changes a type of authentication used by the library to work with the Firebase backend.
     *
     * If a not supported value is passed to the type parameter or the provider parameter is null
     * (irrespective of the type parameter value), the authentication type is changed to the 
     * FIREBASE_AUTH_TYPE.LEGACY_TOKEN.
     *
     * Returns:
     *      nothing
     * Parameters:
     *      type     - a type of authentication. It must be one of the FIREBASE_AUTH_TYPE enum values.
     *      provider - an external provider of access tokens.
     *                 The provider must contain an acquireAccessToken(tokenReadyCallback) method, 
     *                 where tokenReadyCallback is a handler that is called when an access token is 
     *                 acquired or an error occurs.
     *                 It has the following signature:
     *                 tokenReadyCallback(token, error), where
     *                     token - a string representation of the access token.
     *                     error - a string with error details (or null if no error occurred).
     *                 Token provider can be an instance of OAuth2.JWTProfile.Client OAuth2 library
     *                 (see https://github.com/electricimp/OAuth-2.0)
     *                 or any other access token provider with a similar interface.
     *
     **************************************************************************/
    function setAuthProvider(type, provider = null) {
        if (provider && (type == FIREBASE_AUTH_TYPE.OAUTH2_TOKEN || type == FIREBASE_AUTH_TYPE.FIREBASE_ID_TOKEN)) {
            _authType = type;
            _authProvider = provider;
        } else {
            _authType = FIREBASE_AUTH_TYPE.LEGACY_TOKEN;
            _authProvider = null;
        }
    }

    /***************************************************************************
     * Attempts to open a stream
     * Returns:
     *      false - if a stream is already open
     *      true -  otherwise
     * Parameters:
     *      path - the path of the node we're listending to (without .json)
     *      uriParams - table of values to attach as URI parameters.  This can be used for queries, etc. - see https://www.firebase.com/docs/rest/guide/retrieving-data.html#section-rest-uri-params
     *      onError - custom error handler for streaming API
     **************************************************************************/
    function stream(path = "", uriParams = null, onError = null) {
        // if we already have a stream open, don't open a new one
        if (isStreaming()) return false;

        if (typeof uriParams == "function") {
            onError = uriParams;
            uriParams = null;
        }
        if (onError == null) onError = _defaultErrorHandler.bindenv(this);

        _acquireAuthToken(function (token, error) {
            if (error) {
                onError({
                    "statuscode" : 0,
                    "body" : error
                });
            } else {
                _streamingRequest = http.get(_buildUrl(path, token, uriParams), _streamingHeaders);
                _streamingRequest.setvalidation(VALIDATE_USING_SYSTEM_CA_CERTS);

                _streamingRequest.sendasync(
                    _onStreamExitFactory(path, onError),
                    _onStreamDataFactory(path, onError),
                    NO_TIMEOUT
                );

                // Tickle the keepalive timer
                if (_keepAliveTimer) imp.cancelwakeup(_keepAliveTimer);
                _keepAliveTimer = imp.wakeup(FB_KEEP_ALIVE_SEC, _onKeepAliveExpiredFactory(path, onError));
            }
        }.bindenv(this));
        return true;
    }

    /***************************************************************************
     * Returns whether or not there is currently a stream open
     * Returns:
     *      true - streaming request is currently open
     *      false - otherwise
     **************************************************************************/
    function isStreaming() {
        return (_streamingRequest != null);
    }

    /***************************************************************************
     * Closes the stream (if there is one open)
     **************************************************************************/
    function closeStream() {
        // Close the stream if it's open
        if (_streamingRequest) {
            _streamingRequest.cancel();
            _streamingRequest = null;
        }

        // Kill the keepalive if it exists
        if (_keepAliveTimer) imp.cancelwakeup(_keepAliveTimer);
    }

    /***************************************************************************
     * Registers a callback for when data in a particular path is changed.
     * If a handler for a particular path is not defined, data will change,
     * but no handler will be called
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're listending to (without .json)
     *      callback - a callback function with two parameters (path, change) to be
     *                 executed when the data at path changes
     **************************************************************************/
    function on(path, callback) {
        if (path.len() > 0 && path.slice(0, 1) != "/") path = "/" + path;
        if (path.len() > 1 && path.slice(-1) == "/") path = path.slice(0, -1);
        _callbacks[path] <- callback;
    }

    /***************************************************************************
     * Reads a path from the internal cache. Really handy to use in an .on() handler
     **************************************************************************/
    function fromCache(path = "/") {
        local data = _data;
        foreach (step in split(path, "/")) {
            if (step == "") continue;
            if (step in data) data = data[step];
            else return null;
        }
        return data;
    }

    /***************************************************************************
     * Reads data from the specified path, and executes the callback handler
     * once complete.
     *
     * NOTE: This function does NOT update firebase._data
     *
     * Returns:
     *      if the callback is not provided and the Promise library is included 
     *      in agent code, returns Promise; otherwise returns nothing
     * Parameters:
     *      path     - the path of the node we're reading
     *      uriParams - table of values to attach as URI parameters.  This can be used for queries, etc. - see https://www.firebase.com/docs/rest/guide/retrieving-data.html#section-rest-uri-params
     *      callback - a callback function to be executed once the data is read.
     *                 The callback signature:
     *                 callback(error, data), where
     *                   error - string error details, null if the operation succeeds
     *                   data  - an object represending the Firebase resosponse,
     *                           null if an error occurred
     **************************************************************************/
     function read(path, uriParams = null, callback = null) {
        if (typeof uriParams == "function") {
            callback = uriParams;
            uriParams = null;
        }
        return _processRequest("GET", path, uriParams, _defaultHeaders, null, callback);
    }

    /***************************************************************************
     * Pushes data to a path (performs a POST)
     * This method should be used when you're adding an item to a list.
     *
     * NOTE: This function does NOT update firebase._data
     * Returns:
     *      if the callback is not provided and the Promise library is included 
     *      in agent code, returns Promise; otherwise returns nothing
     * Parameters:
     *      path     - the path of the node we're pushing to
     *      data     - the data we're pushing
     *      priority - optional numeric or alphanumeric value of each node.
     *                 It is used to sort the children under a specific parent,
     *                 or in a query if no other sort condition is specified.
     *      callback - a callback function to be executed once the data is pushed.
     *                 The callback signature:
     *                 callback(error, data), where
     *                   error - string error details, null if the operation succeeds
     *                   data  - an object represending the Firebase resosponse,
     *                           null if an error occurred
     **************************************************************************/
    function push(path, data, priority = null, callback = null) {
        if (priority != null && typeof data == "table") data[".priority"] <- priority;
        return _processRequest("POST", path, null, _defaultHeaders, http.jsonencode(data), callback);
    }

    /***************************************************************************
     * Writes data to a path (performs a PUT)
     * This is generally the function you want to use
     *
     * NOTE: This function does NOT update firebase._data
     *
     * Returns:
     *      if the callback is not provided and the Promise library is included 
     *      in agent code, returns Promise; otherwise returns nothing
     * Parameters:
     *      path     - the path of the node we're writing to
     *      data     - the data we're writing
     *      callback - a callback function to be executed once the data is written.
     *                 The callback signature:
     *                 callback(error, data), where
     *                   error - string error details, null if the operation succeeds
     *                   data  - an object represending the Firebase resosponse,
     *                           null if an error occurred
     **************************************************************************/
    function write(path, data, callback = null) {
        return _processRequest("PUT", path, null, _defaultHeaders, http.jsonencode(data), callback);
    }

    /***************************************************************************
     * Updates a particular path (performs a PATCH)
     * This method should be used when you want to do a non-destructive write
     *
     * NOTE: This function does NOT update firebase._data
     *
     * Returns:
     *      if the callback is not provided and the Promise library is included 
     *      in agent code, returns Promise; otherwise returns nothing
     * Parameters:
     *      path     - the path of the node we're patching
     *      data     - the data we're patching
     *      callback - a callback function to be executed once the data is updated.
     *                 The callback signature:
     *                 callback(error, data), where
     *                   error - string error details, null if the operation succeeds
     *                   data  - an object represending the Firebase resosponse,
     *                           null if an error occurred
     **************************************************************************/
    function update(path, data, callback = null) {
        if (typeof(data) == "table" || typeof(data) == "array") data = http.jsonencode(data);
        return _processRequest("PATCH", path, null, _defaultHeaders, data, callback);
    }

    /***************************************************************************
     * Deletes the data at the specific node (performs a DELETE)
     *
     * NOTE: This function does NOT update firebase._data
     *
     * Returns:
     *      if the callback is not provided and the Promise library is included 
     *      in agent code, returns Promise; otherwise returns nothing
     * Parameters:
     *      path     - the path of the node we're deleting
     *      callback - a callback function to be executed once the data is updated.
     *                 The callback signature:
     *                 callback(error, data), where
     *                   error - string error details, null if the operation succeeds
     *                   data  - an object represending the Firebase resosponse,
     *                           null if an error occurred
     **************************************************************************/
    function remove(path, callback = null) {
        return _processRequest("DELETE", path, null, _defaultHeaders, null, callback);
    }


    /************ Private Functions (DO NOT CALL FUNCTIONS BELOW) ************/
    // Builds a url to send a request to
    function _buildUrl(path, authToken, uriParams = null) {
        // Normalise the /'s
        // _baseUrl = <_baseUrl>
        // path = <path>
        if (_baseUrl.len() > 0 && _baseUrl[_baseUrl.len()-1] == '/') _baseUrl = _baseUrl.slice(0, -1);
        if (path.len() > 0 && path[0] == '/') path = path.slice(1);

        local url = _baseUrl + "/" + path + ".json";

        if(typeof(uriParams) != "table") uriParams = {}


        local quoteWrappedKeys = [
            "startAt",
            "endAt" ,
            "equalTo",
            "orderBy"
        ]

        foreach(key, value in uriParams){
            if(quoteWrappedKeys.find(key) != null && typeof(value) == "string") uriParams[key] = "\"" + value + "\""
        }

        //TODO: Right now we aren't doing any kind of checking on the uriParams - we are trusting that Firebase will throw errors as necessary

        // Use instance values if these keys aren't provided
        if (!("ns" in uriParams)) uriParams.ns <- _db;
        if (!("auth" in uriParams)) {
            switch (_authType) {
                case FIREBASE_AUTH_TYPE.OAUTH2_TOKEN:
                    uriParams.access_token <- authToken;
                    break;
                default:
                    uriParams.auth <- authToken;
                    break;
            }
        }

        url += "?" + http.urlencode(uriParams);
        return url;
    }

    // Default error handler
    function _defaultErrorHandler(error) {
        _logError(error.statuscode + ": " + error.body);
    }

    // Stream Callback
    function _onStreamExitFactory(path, onError) {
        return function(resp) {
            _streamingRequest = null;
            if (resp.statuscode == 307 && "location" in resp.headers) {
                // Reset backoff timer
                _backOffTimer = FB_DEFAULT_BACK_OFF_TIMEOUT_SEC;
                // set new location
                local location = resp.headers["location"];
                local p = location.find("." + _domain);
                p = location.find("/", p);
                _baseUrl = location.slice(0, p);
                return imp.wakeup(0, function() { stream(path, onError); }.bindenv(this));
            } else if (resp.statuscode == 28 || resp.statuscode == 429 || resp.statuscode == 503) {
                // if we timed out, just reconnect after a delay
                imp.wakeup(_backOffTimer, function() { return stream(path, onError); }.bindenv(this));
                _backOffTimer *= 2;
            } else {
                // Otherwise log an error (if enabled)
                _logError("Stream closed with error " + resp.statuscode);

                // Invoke our error handler
                onError(resp);
                _backOffTimer = FB_DEFAULT_BACK_OFF_TIMEOUT_SEC;
            }
        }.bindenv(this);
    }

    // Stream Callback
    //TODO: We are not currently explicitly handling https://www.firebase.com/docs/rest/api/#section-streaming-cancel and https://www.firebase.com/docs/rest/api/#section-streaming-auth-revoked
    function _onStreamDataFactory(path, onError) {
        return function(messageString) {
            // Tickle the keep alive timer
            if (_keepAliveTimer) imp.cancelwakeup(_keepAliveTimer);
            _keepAliveTimer = imp.wakeup(FB_KEEP_ALIVE_SEC, _onKeepAliveExpiredFactory(path, onError));
            // We have received a resp from firebase, so set backoff timer to default
            _backOffTimer = FB_DEFAULT_BACK_OFF_TIMEOUT_SEC;

            local messages = _parseEventMessage(messageString);
            foreach (message in messages) {
                // Update the internal cache
                _updateCache(message);

                // Check out every callback for matching path
                foreach (path, callback in _callbacks) {
                    if (path == "/" || path == message.path || message.path.find(path + "/") == 0) {
                        // This is an exact match or a subbranch
                        callback(message.path, message.data);
                    } else if (message.event == "patch") {
                        // This is a patch for a (potentially) parent node
                        foreach (head,body in message.data) {
                            local newMessagePath = ((message.path == "/") ? "" : message.path) + "/" + head;
                            if (newMessagePath == path) {
                                // We have found a superbranch that matches, rewrite this as a PUT
                                local subdata = _getDataFromPath(newMessagePath, message.path, _data);
                                callback(newMessagePath, subdata);
                            }
                        }
                    } else if (message.path == "/" || path.find(message.path + "/") == 0) {
                        // This is the root or a superbranch for a put or delete
                        local subdata = _getDataFromPath(path, message.path, _data);
                        callback(path, subdata);
                    }
                }
            }
        }.bindenv(this);
    }

    // No keep alive has been seen for a while, lets reconnect
    function _onKeepAliveExpiredFactory(path, onError) {
        return function() {
            _logError("Keep alive timer expired. Reconnecting stream.")
            closeStream();
            stream(path, onError);
        }.bindenv(this);
    }

    // parses event messages
    // (https://www.w3.org/TR/eventsource/#parsing-an-event-stream)
    // Message example:
    // event: put
    // data: {"path": "/c", "data": {"foo": true, "bar": false}}
    // All messages except errors have two lines
    // function can parse several messages, not full message or both
    function _parseEventMessage(input) {
        local text = _bufferedInput + input;
        _bufferedInput = "";

        // split message into parts
        local allLines = split(text, "\n");

        // Check, if we have at least one message
        if (allLines.len() < 2) {
            _bufferedInput = text;
            return [];
        }

        local parsedEvents = [];

        for (local i = 0; i < allLines.len(); ) {
            local lines = [];
            //try to get 2 lines
            if (i + 1 < allLines.len()) {
                lines.push(allLines[i++]);
                lines.push(allLines[i++]);
            } else {
                // check, if we have at least one line, that we should to save
                if (i < allLines.len()) {
                    hasEndOfLine = text[text.len() - 1] == "\n";
                    _bufferedInput = lines[i] + (hasEndOfLine ? "\n" : "");
                }
                return parsedEvents;
            }

            // Error have 3 lines and last one is "}"
            if (i < allLines.len() && allLines[i] == "}") {
                lines.push(allLines[i++]);
                try {
                    local error = http.jsondecode(text);
                    _logError("Firebase error message: " + error.error);
                } catch (e) {
                    _logError("Exeption while parsing error message: " + e);
                }
                continue;   // The continue operator jumps to the next iteration of the loop skipping the execution of the following statements.
            }

            // get the event
            local eventLine = lines[0];
            local event = eventLine.slice(7);

            // keep-alive contains no data
            if (event.tolower() == "keep-alive") continue;

            // get the data
            local dataLine = lines[1];
            local dataString = dataLine.slice(6);

            // pull interesting bits out of the data
            local d = null;
            try {
                // try to encode json to get data and path fields
                d = http.jsondecode(dataString);
            } catch (e) {
                // Check, if it is last line and we want to wait another part, or
                // message is broken
                if (i + 1 < allLines.len()) {
                    _logError("Exception while decoding (" + dataString.len() + " bytes): " + dataString);
                    _bufferedInput = "";
                    continue;
                } else {
                    // add last not full message to buffer
                    local hasEndOfLine = text[text.len() - 1] == "\n";
                    for (local j = 0; j < lines.len(); j++) {
                        local isLastString = j == lines.len() - 1;
                        _bufferedInput += lines[j] + (!isLastString || hasEndOfLine ? "\n" : "");
                    }
                    return parsedEvents;
                }
            }

            // return a useful object
            local path = d ? d.path : null;
            local data = d ? d.data : null;
            parsedEvents.push({"event": event, "path": path, "data": data});
        }

        return parsedEvents;
    }

    // Updates the local cache
    function _updateCache(message) {

        // base case - refresh everything
        if (message.event == "put" && message.path == "/") {
            _data = (message.data == null) ? {} : message.data;
            return _data
        }

        local pathParts = split(message.path, "/");
        local key = pathParts.len() > 0 ? pathParts[pathParts.len()-1] : null;

        local currentData = _data;
        local parent = _data;
        local lastPart = "";

        // Walk down the tree following the path
        foreach (part in pathParts) {
            if (typeof currentData != "array" && typeof currentData != "table") {
                // We have orphaned a branch of the tree
                if (lastPart == "") {
                    _data = {};
                    parent = _data;
                    currentData = _data;
                } else {
                    parent[lastPart] <- {};
                    currentData = parent[lastPart];
                }
            }

            parent = currentData;

            // NOTE: This is a hack to deal with a quirk of Firebase
            // Firebase sends arrays when the indicies are integers and its more efficient to use an array.
            if (typeof currentData == "array") {
                part = part.tointeger();
            }

            if (!(part in currentData)) {
                // This is a new branch
                currentData[part] <- {};
            }
            currentData = currentData[part];
            lastPart = part;
        }

        // Make the changes to the found branch
        if (message.event == "put") {
            if (message.data == null) {
                // Delete the branch
                if (key == null) {
                    _data = {};
                } else {
                    if (typeof parent == "array") {
                        parent[key.tointeger()] = null;
                    } else {
                        delete parent[key];
                    }
                }
            } else {
                // Replace the branch
                if (key == null) {
                    _data = message.data;
                } else {
                    if (typeof parent == "array") {
                        parent[key.tointeger()] = message.data;
                    } else {
                        parent[key] <- message.data;
                    }
                }
            }
        } else if (message.event == "patch") {
            foreach(k,v in message.data) {
                if (key == null) {
                    // Patch the root branch
                    _data[k] <- v;
                } else {
                    // Patch the current branch
                    parent[key][k] <- v;
                }
            }
        }

        // Now clean up the tree, removing any orphans
        _cleanTree(_data);
    }

    // Cleans the tree by deleting any empty nodes
    function _cleanTree(branch) {
        foreach (k,subbranch in branch) {
            if (typeof subbranch == "array" || typeof subbranch == "table") {
                _cleanTree(subbranch)
                if (subbranch.len() == 0) delete branch[k];
            }
        }
    }

    // Steps through a path to get the contents of the table at that point
    function _getDataFromPath(c_path, m_path, m_data) {

        // Make sure we are on the right branch
        if (m_path.len() > c_path.len() && m_path.find(c_path) != 0) return null;

        // Walk to the base of the callback path
        local new_data = m_data;
        foreach (step in split(c_path, "/")) {
            if (step == "") continue;
            if (step in new_data) {
                new_data = new_data[step];
            } else {
                new_data = null;
                break;
            }
        }

        // Find the data at the modified branch but only one step deep at max
        local changed_data = new_data;
        if (m_path.len() > c_path.len()) {
            // Only a subbranch has changed, pick the subbranch that has changed
            local new_m_path = m_path.slice(c_path.len())
            foreach (step in split(new_m_path, "/")) {
                if (step == "") continue;
                if (step in changed_data) {
                    changed_data = changed_data[step];
                } else {
                    changed_data = null;
                }
                break;
            }
        }

        return changed_data;
    }

    function _logError(message) {
        if (_debug) server.error(message);
    }

    function _createResponseHandler(onSuccess, onError) {
        return function (res) {
            local response = res.body;
            try {
                local data = null;
                if (response && response.len() > 0) {
                    data = http.jsondecode(response);
                }
                if (200 <= res.statuscode && res.statuscode < 300) {
                    onSuccess(data);
                    _tooManyReqTimer = false;
                } else if (res.statuscode == 28 || res.statuscode == 429 || res.statuscode == 503) {
                    local now = time();
                    // Too many requests, set _tooManyReqTimer to prevent more requests to FB
                    if (_tooManyReqTimer == false) {
                        // This is the first 429 we have seen set a default timeout
                        _tooManyReqTimer = now + FB_DEFAULT_BACK_OFF_TIMEOUT_SEC;
                    } else if (_tooManyReqTimer <= now) {
                        // Firebase is still overwhelmed after first timeout expired,
                        // Let's block requests for longer to let FB recover
                        _tooManyReqTimer = now + (FB_DEFAULT_BACK_OFF_TIMEOUT_SEC * _tooManyReqCounter++);
                    }
                    // Pass error to callback
                    onError("Error " + res.statuscode);
                } else if (typeof data == "table" && "error" in data) {
                    _tooManyReqTimer = false;
                    local error = data ? data.error : null;
                    onError(error);
                } else {
                    _tooManyReqTimer = false;
                    onError("Error " + res.statuscode);
                }
            } catch (err) {
                _tooManyReqTimer = false;
                onError(err);
            }
        }
    }

    function _acquireAuthToken(tokenReadyCallback) {
        if (_authProvider) {
            _authProvider.acquireAccessToken(tokenReadyCallback);
        } else {
            tokenReadyCallback(_auth, null);
        }
    }

    function _createAndSendRequest(method, path, uriParams, headers, body, onSuccess, onError) {
        _acquireAuthToken(function (token, error) {
            if (error) {
                onError(error);
            } else {
                local url = _buildUrl(path, token, uriParams);
                local request = http.request(method, url, headers, body ? body : "");
                request.setvalidation(VALIDATE_USING_SYSTEM_CA_CERTS);
                request.sendasync(_createResponseHandler(onSuccess, onError).bindenv(this));
            }
        }.bindenv(this));
    }

    function _processRequest(method, path, uriParams, headers, body, callback) {
        // Use Promise if promise libary included and callback == null
        local usePromise = (_promiseIncluded && callback == null);
        local now = time();

        // Only send request if we haven't received a 429 error recently
        if (_tooManyReqTimer == false || _tooManyReqTimer <= now) {
            if (usePromise) {
                return Promise(function (resolve, reject) {
                    _createAndSendRequest(method, path, uriParams, headers, body, resolve, reject);
                }.bindenv(this));
            } else {
                local onSuccess = function (data) {
                    callback && callback(null, data);
                };
                local onError = function (err) {
                    callback && callback(err, null);
                };
                _createAndSendRequest(method, path, uriParams, headers, body, onSuccess, onError);
            }
        } else {
            local error = "ERROR: Too many requests to Firebase, try request again in " + (_tooManyReqTimer - now) + " seconds.";
            if (usePromise) {
                return Promise.reject(error);
            } else {
                callback(error, null);
            }
        }
    }
}
