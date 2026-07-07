import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ------------------------------------------------------------------
    // Publisher config: the PUBLIC-client Client ID shipped with the widget,
    // so end users never enter one. There is no Client ID field in settings;
    // the Plasmoid.configuration.clientId fallback below only applies if a
    // forker leaves embeddedClientId empty and sets it manually in the config.
    // ------------------------------------------------------------------
    readonly property string embeddedClientId: "0voosrrcycnc46i7nldbgaqx5aeosj"
    readonly property string clientId: (root.embeddedClientId
        || Plasmoid.configuration.clientId || "").trim()

    // ------------------------------------------------------------------
    // Kick: each user brings their own app credentials (Kick requires a
    // client secret, so there is no shippable public client like Twitch).
    // ------------------------------------------------------------------
    readonly property string kickClientId: (Plasmoid.configuration.kickClientId || "").trim()
    readonly property string kickClientSecret: (Plasmoid.configuration.kickClientSecret || "").trim()
    readonly property bool kickConfigured: kickClientId.length > 0 && kickClientSecret.length > 0

    // Currently live channels, merged across platforms and sorted by viewers.
    // Each record: { platform, login, name, game, viewers, title, key }
    //   platform: "twitch" | "kick"   key: "<platform>:<login>" (color/identity)
    property var liveStreams: []
    // Per-provider results; rebuildLiveStreams() merges them into liveStreams.
    property var twitchStreams: []
    property var kickStreams: []
    property string statusText: i18n("Loading…")
    // Per-provider in-flight guards; `busy` is the combined view for the UI.
    property bool twitchBusy: false
    property bool kickBusy: false
    readonly property bool busy: twitchBusy || kickBusy
    // Wall-clock stamp (Date.now) of when each guard was raised. A request can
    // never legitimately outlive its 15s xhr.timeout, so a guard older than this
    // window is stale and gets force-cleared on the next poll. This is what
    // recovers from suspend: when a poll's request is in flight as the machine
    // sleeps, the socket dies silently and — because the event loop is frozen —
    // the xhr.timeout that would normally release the guard never fires, wedging
    // it true forever. Date.now keeps ticking through sleep, so on resume the
    // stamp reads as ancient and the guard self-heals instead of freezing the
    // widget on its pre-sleep snapshot.
    readonly property int busyStaleMs: 2 * 15000 // 2× the per-request xhr.timeout
    property double twitchPollStart: 0
    property double kickPollStart: 0

    // Twitch OAuth / device-flow state
    // authState: "unlinked" | "linking" | "linked"
    property string authState: (Plasmoid.configuration.refreshToken
        || Plasmoid.configuration.cachedToken) ? "linked" : "unlinked"
    property string userCode: ""
    property string verificationUri: ""
    property string deviceCode: ""

    // Kick connection state (no interactive linking step — "linking" only marks
    // the brief credential-validation request). kickState: "unlinked" | "linking" | "linked"
    property string kickState: kickConfigured ? "linked" : "unlinked"

    // At least one platform usable → the widget shows streams instead of setup.
    readonly property bool anyLinked: authState === "linked" || kickState === "linked"

    readonly property int orientation: Plasmoid.configuration.orientation // 0 = horizontal, 1 = vertical
    readonly property bool showTooltip: Plasmoid.configuration.showTooltip // hover details in horizontal mode
    readonly property int fontSize: Plasmoid.configuration.fontSize
    readonly property string fontColor: Plasmoid.configuration.fontColor // "" = theme text color
    readonly property string fontFamily: Plasmoid.configuration.fontFamily // "" = default font
    readonly property int hAlign: Plasmoid.configuration.hAlign // 0 left, 1 center, 2 right
    readonly property int vAlign: Plasmoid.configuration.vAlign // 0 top, 1 center, 2 bottom
    readonly property int hoverDelay: Plasmoid.configuration.hoverDelay // ms before controls appear
    // Resolved colors used by the delegate
    readonly property color normalColor: fontColor ? fontColor : Kirigami.Theme.textColor
    readonly property color hoverColor: Kirigami.Theme.highlightedTextColor

    // ------------------------------------------------------------------
    // Border / background (opt-in framing for the widget and/or each chip).
    // Disabled by default → the widget stays frameless unless turned on.
    // *CornerStyle: 0 square, 1 rounded.  *FillMode: 0 single, 1 gradient, 2 random.
    // ------------------------------------------------------------------
    readonly property bool   widgetFrameEnabled: Plasmoid.configuration.widgetFrameEnabled
    readonly property int    widgetBorderWidth:  Plasmoid.configuration.widgetBorderWidth
    readonly property int    widgetCornerStyle:  Plasmoid.configuration.widgetCornerStyle
    readonly property int    widgetCornerRadius: Plasmoid.configuration.widgetCornerRadius
    readonly property string widgetBorderColor:  Plasmoid.configuration.widgetBorderColor // "" = theme highlight
    readonly property real   widgetFillOpacity:  Plasmoid.configuration.widgetFillOpacity
    readonly property int    widgetFillMode:     Plasmoid.configuration.widgetFillMode
    readonly property string widgetFillColors:   Plasmoid.configuration.widgetFillColors

    readonly property bool   chipFrameEnabled:   Plasmoid.configuration.chipFrameEnabled
    readonly property int    chipBorderWidth:    Plasmoid.configuration.chipBorderWidth
    readonly property int    chipCornerStyle:    Plasmoid.configuration.chipCornerStyle
    readonly property int    chipCornerRadius:   Plasmoid.configuration.chipCornerRadius
    readonly property string chipBorderColor:    Plasmoid.configuration.chipBorderColor
    readonly property real   chipFillOpacity:    Plasmoid.configuration.chipFillOpacity
    readonly property int    chipFillMode:       Plasmoid.configuration.chipFillMode
    readonly property string chipFillColors:     Plasmoid.configuration.chipFillColors

    // Breathing room so a widget frame doesn't crowd the text.
    readonly property int framePadding: widgetFrameEnabled
        ? (Kirigami.Units.smallSpacing + Math.max(0, widgetBorderWidth)) : 0

    // Random fill colors. Per-streamer colors are keyed by login and only change
    // when a channel newly comes online (a login that goes away and comes back is
    // treated as new and re-rolls). The widget-level random color likewise
    // re-rolls whenever a new channel appears.
    property var streamColors: ({})
    property color widgetRandomColor: "transparent"

    // Gradients are pre-built and only rebuilt when their colors/opacity change —
    // not on every hover or poll.
    readonly property var widgetGradient: (widgetFrameEnabled && widgetFillMode === 1)
        ? makeGradient(widgetFillColors, widgetFillOpacity, false) : null
    readonly property var chipGradient: (chipFrameEnabled && chipFillMode === 1)
        ? makeGradient(chipFillColors, chipFillOpacity, true) : null

    function parseColorList(s) {
        return (s || "").split(/[\s,]+/)
            .map(function (x) { return x.trim(); })
            .filter(function (x) { return x.length > 0; });
    }
    // Return `c` (a color value or "#rgb"/"#rrggbb"/"#aarrggbb" string) at alpha
    // `a`. Pure (no shared state) — using a shared scratch property here caused a
    // binding loop that froze the colors until the delegate was recreated.
    function withAlpha(c, a) {
        if (c !== undefined && c !== null && c.r !== undefined)
            return Qt.rgba(c.r, c.g, c.b, a);     // color value type (0..1 components)
        var s = ("" + c).trim();
        if (s.charAt(0) === "#") {
            var h = s.substring(1), r, g, b;
            if (h.length === 3) {
                r = parseInt(h.charAt(0) + h.charAt(0), 16);
                g = parseInt(h.charAt(1) + h.charAt(1), 16);
                b = parseInt(h.charAt(2) + h.charAt(2), 16);
            } else if (h.length === 8) {          // #aarrggbb
                r = parseInt(h.substr(2, 2), 16);
                g = parseInt(h.substr(4, 2), 16);
                b = parseInt(h.substr(6, 2), 16);
            } else {                              // #rrggbb
                r = parseInt(h.substr(0, 2), 16);
                g = parseInt(h.substr(2, 2), 16);
                b = parseInt(h.substr(4, 2), 16);
            }
            return Qt.rgba(r / 255, g / 255, b / 255, a);
        }
        return Qt.rgba(0, 0, 0, a);               // unknown → translucent (shouldn't happen)
    }
    function randomHue() { return Qt.hsla(Math.random(), 0.55, 0.55, 1.0); }
    // Pick from the configured list if any, otherwise a fully random hue.
    function pickFill(csv) {
        var list = parseColorList(csv);
        if (list.length > 0) return list[Math.floor(Math.random() * list.length)];
        return randomHue();
    }
    function makeGradient(csv, alpha, horizontal) {
        var list = parseColorList(csv);
        if (list.length === 0) list = [Kirigami.Theme.backgroundColor.toString()];
        if (list.length === 1) list.push(list[0]);
        var stops = "";
        for (var i = 0; i < list.length; i++) {
            var pos = i / (list.length - 1);
            stops += 'GradientStop { position: ' + pos
                  + '; color: "' + withAlpha(list[i], alpha).toString() + '" }\n';
        }
        return Qt.createQmlObject(
            'import QtQuick\nGradient {\norientation: Gradient.'
            + (horizontal ? 'Horizontal' : 'Vertical') + '\n' + stops + '}',
            root, "dynamicGradient");
    }
    // Keep the per-streamer (and widget) random colors in step with who's live.
    function reconcileStreamColors() {
        var prev = root.streamColors;
        var next = {};
        var grew = false;
        for (var i = 0; i < root.liveStreams.length; i++) {
            // Key by "<platform>:<login>" so the same name on two platforms gets
            // its own colour (and doesn't share/steal the other's).
            var k = root.liveStreams[i].key;
            if (prev[k] !== undefined) {
                next[k] = prev[k];                  // still live → keep its color
            } else {
                next[k] = pickFill(root.chipFillColors).toString(); // newly live
                grew = true;
            }
        }
        root.streamColors = next;                    // drops offline logins (re-roll later)
        if (grew && root.widgetFillMode === 2)
            root.widgetRandomColor = pickFill(root.widgetFillColors);
    }
    onLiveStreamsChanged: reconcileStreamColors()

    // No frame / panel behind the widget — just the content.
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: fullRepresentation

    // Keep the settings-page mirrors of link state in sync (display only).
    onAuthStateChanged: Plasmoid.configuration.linked = (authState === "linked")
    onKickStateChanged: Plasmoid.configuration.kickLinked = (kickState === "linked")
    Component.onCompleted: {
        Plasmoid.configuration.linked = (authState === "linked");
        Plasmoid.configuration.kickLinked = (kickState === "linked");
        if (Plasmoid.configuration.useCurlResume) root.probeCurl();
    }

    toolTipMainText: i18n("Who's Live")
    toolTipSubText: !anyLinked
        ? i18n("Not connected to Twitch or Kick")
        : (liveStreams.length > 0
            ? i18np("%1 channel live", "%1 channels live", liveStreams.length)
            : statusText)

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function splitChannels(raw) {
        return (raw || "").split(/[\s,]+/)
                  .map(function (s) { return s.trim().toLowerCase(); })
                  .filter(function (s) { return s.length > 0; });
    }
    function channelList() { return splitChannels(Plasmoid.configuration.channels); }
    function kickChannelList() { return splitChannels(Plasmoid.configuration.kickChannels); }

    function clearTokens() {
        Plasmoid.configuration.cachedToken = "";
        Plasmoid.configuration.refreshToken = "";
        Plasmoid.configuration.tokenExpiry = 0;
    }

    function clearKickTokens() {
        Plasmoid.configuration.kickToken = "";
        Plasmoid.configuration.kickTokenExpiry = 0;
    }

    // Merge both providers' results into the sorted list the UI renders, and
    // refresh the "nobody live" hint. Each provider replaces only its own slice,
    // so a slow/failed poll on one platform never blanks the other.
    function rebuildLiveStreams() {
        var arr = root.twitchStreams.concat(root.kickStreams);
        arr.sort(function (a, b) { return b.viewers - a.viewers; });
        root.liveStreams = arr;
        updateStatus();
    }
    // Only owns the idle/empty hint; error strings are set by the callers and
    // left intact here (they get cleared on the next successful poll).
    function updateStatus() {
        if (root.liveStreams.length > 0) { root.statusText = ""; return; }
        if (!root.anyLinked || root.busy) return;
        var noChannels = channelList().length === 0 && kickChannelList().length === 0;
        root.statusText = noChannels ? i18n("No channels configured")
                                     : i18n("Nobody's live right now");
    }
    function refreshAll() {
        root.checkStreams(false);
        root.checkKickStreams(false);
    }

    // ------------------------------------------------------------------
    // Unified HTTP transport (curl out-of-process  ·  in-process XHR).
    //
    // After resume-from-suspend the desktop's shared QNetworkAccessManager keeps
    // reusing the TCP socket that died during sleep; every request then hangs
    // until the kernel's ~15-min TCP retransmit timeout frees it (see the resume
    // notes below). Routing a poll through an external `curl` process sidesteps
    // that entirely — a fresh process opens a fresh connection and recovers in
    // seconds. It's opt-in (Plasmoid.configuration.useCurlResume) and only used
    // when curl is actually present; otherwise we fall back to the XHR path and
    // ride out the self-heal. The Kick *token refresh* is deliberately NEVER sent
    // via curl (it carries the client secret, which would be briefly visible in
    // the process list) — and it doesn't need to be, since the Kick app token
    // lasts ~57 days and so never expires across a sleep.
    // ------------------------------------------------------------------
    readonly property bool curlEnabled: Plasmoid.configuration.useCurlResume && root.curlAvailable
    property bool curlAvailable: false   // set by the one-shot probe
    property bool curlProbed: false
    property int curlSeq: 0
    property var curlPending: ({})        // unique command string → done(status,text)
    readonly property string curlProbeCmd: "command -v curl"

    P5Support.DataSource {
        id: curlEngine
        engine: "executable"
        onNewData: function (source, data) {
            if (source === root.curlProbeCmd) {
                curlEngine.disconnectSource(source);
                root.curlAvailable = (data && data["exit code"] === 0
                    && ("" + data["stdout"]).trim().length > 0);
                return;
            }
            var done = root.curlPending[source];
            curlEngine.disconnectSource(source); // run-once; free the slot
            if (done === undefined) return;       // aborted by the watchdog
            delete root.curlPending[source];
            var out = (data && data["stdout"] !== undefined) ? ("" + data["stdout"]) : "";
            var exitCode = data ? data["exit code"] : 1;
            // curl appends "\nWLSTATUS:<code>" after the body via -w. A network
            // failure (no connect / DNS / timeout) → non-zero exit and code 000,
            // which we surface as status 0 = transient (matches the XHR path).
            var status = 0, body = "";
            var marker = "WLSTATUS:";
            var m = out.lastIndexOf(marker);
            if (m >= 0) {
                status = parseInt(out.substring(m + marker.length)) || 0;
                body = out.substring(0, m).replace(/\n$/, "");
            }
            if (exitCode !== 0) status = 0;
            done(status, body);
        }
    }

    function probeCurl() {
        if (root.curlProbed) return;
        root.curlProbed = true;
        curlEngine.connectSource(root.curlProbeCmd);
    }

    // POSIX-sh single-quote escaping: wrap in '…' and turn every embedded ' into
    // '\'' . Makes any token / URL / header safe to splice into the command the
    // executable engine runs via the shell, regardless of its contents.
    function shq(s) { return "'" + ("" + s).split("'").join("'\\''") + "'"; }

    // Issue one request and call done(status, text). status 0 means a transient
    // failure (network down / hung / curl error). Returns a handle exposing
    // abort(), which the watchdog uses to cancel an in-flight request. `useCurl`
    // selects the transport per call (callers pass root.curlEnabled, except the
    // Kick refresh which always passes false).
    function httpSend(useCurl, method, url, headers, body, done) {
        return useCurl ? curlSend(method, url, headers, body, done)
                       : xhrSend(method, url, headers, body, done);
    }

    function xhrSend(method, url, headers, body, done) {
        var xhr = new XMLHttpRequest();
        xhr.open(method, url);
        for (var k in headers) xhr.setRequestHeader(k, headers[k]);
        xhr.timeout = 15000;
        var fired = false;
        function fire(status, text) { if (fired) return; fired = true; done(status, text); }
        xhr.ontimeout = function () { fire(0, ""); };
        xhr.onerror = function () { fire(0, ""); };
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            fire(xhr.status, xhr.responseText);
        };
        if (body !== undefined && body !== null) xhr.send(body); else xhr.send();
        return { abort: function () {
            fired = true;
            xhr.onreadystatechange = function () {};
            xhr.ontimeout = function () {};
            xhr.onerror = function () {};
            try { xhr.abort(); } catch (e) {}
        } };
    }

    function curlSend(method, url, headers, body, done) {
        var parts = ["curl", "-sS", "--max-time", "15"];
        if (method === "POST") {
            parts.push("-X", "POST");
            if (body !== undefined && body !== null) parts.push("--data", shq(body));
        }
        for (var k in headers) parts.push("-H", shq(k + ": " + headers[k]));
        parts.push("-w", shq("\\nWLSTATUS:%{http_code}"));
        parts.push(shq(url));
        var seq = root.curlSeq++;
        // Trailing "#<seq>" is a shell comment that just makes the source string
        // unique (so back-to-back polls aren't deduplicated by the engine).
        var cmd = parts.join(" ") + " #" + seq;
        root.curlPending[cmd] = done;
        curlEngine.connectSource(cmd);
        return { abort: function () {
            delete root.curlPending[cmd];
            curlEngine.disconnectSource(cmd);
        } };
    }

    // ------------------------------------------------------------------
    // Device Code Grant flow (no client secret, public client)
    // ------------------------------------------------------------------
    function startDeviceAuth() {
        if (!clientId) {
            root.statusText = i18n("Set a Client ID in settings first");
            return;
        }
        root.authState = "linking";
        root.statusText = i18n("Requesting code from Twitch…");

        var xhr = new XMLHttpRequest();
        xhr.open("POST", "https://id.twitch.tv/oauth2/device");
        xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                var r = JSON.parse(xhr.responseText);
                root.deviceCode = r.device_code;
                root.userCode = r.user_code;
                root.verificationUri = r.verification_uri;
                devicePoll.interval = Math.max(5, (r.interval || 5)) * 1000;
                deviceExpiry.interval = Math.max(60, (r.expires_in || 1800)) * 1000;
                root.statusText = i18n("Waiting for you to approve on Twitch…");
                devicePoll.restart();
                deviceExpiry.restart();
                // Open the verification page (it has the code pre-filled).
                Qt.openUrlExternally(root.verificationUri);
            } else {
                root.authState = "unlinked";
                root.statusText = i18n("Could not start linking (%1)", xhr.status);
            }
        };
        // streams data is public, so no scopes are requested
        xhr.send("client_id=" + encodeURIComponent(clientId) + "&scopes=");
    }

    function pollDeviceToken() {
        if (root.authState !== "linking" || !root.deviceCode) return;

        var xhr = new XMLHttpRequest();
        xhr.open("POST", "https://id.twitch.tv/oauth2/token");
        xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                var r = JSON.parse(xhr.responseText);
                Plasmoid.configuration.cachedToken = r.access_token;
                Plasmoid.configuration.refreshToken = r.refresh_token || "";
                Plasmoid.configuration.tokenExpiry = Date.now() + (r.expires_in * 1000);
                devicePoll.stop();
                deviceExpiry.stop();
                root.deviceCode = "";
                root.userCode = "";
                root.authState = "linked";
                root.statusText = i18n("Linked! Checking streams…");
                root.checkStreams(false);
            } else {
                // 400 + authorization_pending is normal until the user approves;
                // keep polling. Anything else (e.g. expired) is handled by the
                // expiry timer / a fresh attempt.
            }
        };
        xhr.send("client_id=" + encodeURIComponent(clientId) +
                 "&scopes=" +
                 "&device_code=" + encodeURIComponent(root.deviceCode) +
                 "&grant_type=urn:ietf:params:oauth:grant-type:device_code");
    }

    Timer { // polls the token endpoint while linking
        id: devicePoll
        repeat: true
        onTriggered: root.pollDeviceToken()
    }

    Timer { // gives up if the user never approves
        id: deviceExpiry
        repeat: false
        onTriggered: {
            if (root.authState === "linking") {
                devicePoll.stop();
                root.authState = "unlinked";
                root.deviceCode = "";
                root.userCode = "";
                root.statusText = i18n("Code expired — try linking again");
            }
        }
    }

    function unlink() {
        devicePoll.stop();
        deviceExpiry.stop();
        clearTokens();
        root.twitchStreams = [];
        root.authState = "unlinked";
        root.statusText = i18n("Not linked");
        rebuildLiveStreams();
    }

    // ------------------------------------------------------------------
    // Token use + refresh (public client: refresh needs no secret)
    // ------------------------------------------------------------------
    // cb(token) on success; onErr() on any failure (no token, refresh rejected,
    // network error/timeout). Callers rely on exactly one of the two firing so
    // they can release state (e.g. root.busy) on every path.
    function ensureToken(cb, onErr) {
        onErr = onErr || function () {};
        var now = Date.now();
        var tok = Plasmoid.configuration.cachedToken;
        var exp = Plasmoid.configuration.tokenExpiry;
        if (tok && exp > now + 60000) { // still valid (1 min safety margin)
            cb(tok);
            return;
        }

        var rt = Plasmoid.configuration.refreshToken;
        if (!rt) {
            root.authState = "unlinked";
            root.statusText = i18n("Link your Twitch account");
            onErr();
            return;
        }

        // Refresh uses curl too when enabled: after a long sleep the Twitch token
        // has usually expired (it lasts only a few hours), so this very request is
        // the one that would otherwise hang on the dead post-resume socket. It
        // carries no client secret (public client), only the refresh token.
        root.twitchXhr = httpSend(root.curlEnabled, "POST",
            "https://id.twitch.tv/oauth2/token",
            { "Content-Type": "application/x-www-form-urlencoded" },
            "grant_type=refresh_token"
                + "&refresh_token=" + encodeURIComponent(rt)
                + "&client_id=" + encodeURIComponent(clientId),
            function (status, text) {
                root.twitchXhr = null;
                if (status === 200) {
                    var r;
                    try { r = JSON.parse(text); } catch (e) {
                        root.statusText = i18n("Network error — will retry");
                        onErr(); return;
                    }
                    Plasmoid.configuration.cachedToken = r.access_token;
                    // refresh tokens are one-time-use — persist the new one
                    if (r.refresh_token) Plasmoid.configuration.refreshToken = r.refresh_token;
                    Plasmoid.configuration.tokenExpiry = Date.now() + (r.expires_in * 1000);
                    root.authState = "linked";
                    cb(r.access_token);
                } else if (status === 0) {
                    // Transient (network down / hung / curl error) — not a revoked token.
                    root.statusText = i18n("Network error — will retry");
                    onErr();
                } else {
                    // refresh token revoked or 30-day-expired → require re-link
                    clearTokens();
                    root.authState = "unlinked";
                    root.statusText = i18n("Session expired — please re-link");
                    onErr();
                }
            });
    }

    function checkStreams(retry) {
        if (root.authState !== "linked") { root.twitchStreams = []; return; }
        var chans = channelList();
        if (chans.length === 0) {
            root.twitchStreams = [];
            rebuildLiveStreams();
            return;
        }
        if (root.twitchBusy && (Date.now() - root.twitchPollStart) < root.busyStaleMs) {
            return;
        }
        root.twitchBusy = true;
        root.twitchPollStart = Date.now();

        ensureToken(function (token) { // onErr below releases busy if no token
            // Helix /streams accepts up to 100 user_login params; only live channels are returned.
            var qs = chans.slice(0, 100).map(function (c) {
                return "user_login=" + encodeURIComponent(c);
            }).join("&");

            // Out-of-process curl when enabled, else in-process XHR. Either way
            // the callback below clears twitchBusy on every path, so a dropped or
            // hung request can't silently wedge future polls.
            root.twitchXhr = httpSend(root.curlEnabled, "GET",
                "https://api.twitch.tv/helix/streams?" + qs,
                { "Client-Id": clientId, "Authorization": "Bearer " + token },
                null,
                function (status, text) {
                    root.twitchXhr = null;
                    root.twitchBusy = false;
                    if (status === 200) {
                        root.twitchFailed = false;
                        var data;
                        try { data = (JSON.parse(text).data) || []; } catch (e) { data = []; }
                        root.twitchStreams = data.map(function (s) {
                            return {
                                platform: "twitch",
                                key: "twitch:" + s.user_login,
                                login: s.user_login,
                                name: s.user_name,
                                game: s.game_name || "",
                                viewers: s.viewer_count || 0,
                                title: s.title || ""
                            };
                        });
                        rebuildLiveStreams();
                        root.noteHealthy();
                    } else if (status === 401 && !retry) {
                        // Access token rejected — drop it and refresh once.
                        Plasmoid.configuration.cachedToken = "";
                        Plasmoid.configuration.tokenExpiry = 0;
                        root.checkStreams(true);
                    } else if (status === 0 || status >= 500) {
                        // Connection failed or server-side hiccup → transient, fast-retry.
                        root.twitchFailed = true;
                        root.statusText = i18n("Network error — will retry");
                        root.scheduleRetry();
                    } else {
                        root.statusText = i18n("Twitch API error (%1)", status);
                    }
                });
        }, function () { // ensureToken failed (e.g. refresh request died on a
            // not-yet-up network at resume) → unstick polling and fast-retry.
            root.twitchBusy = false;
            root.twitchFailed = true;
            root.scheduleRetry();
        });
    }

    // ------------------------------------------------------------------
    // Kick: client-credentials app token + public livestream lookup
    // ------------------------------------------------------------------
    // The app token is short-lived and carries no refresh token, so when it
    // expires we just mint a new one straight from the saved credentials.
    // cb(token) on success; onErr() on any failure (mirrors ensureToken).
    function ensureKickToken(cb, onErr) {
        onErr = onErr || function () {};
        var now = Date.now();
        var tok = Plasmoid.configuration.kickToken;
        var exp = Plasmoid.configuration.kickTokenExpiry;
        if (tok && exp > now + 60000) { cb(tok); return; } // still valid (1 min margin)

        if (!root.kickConfigured) {
            root.kickState = "unlinked";
            onErr();
            return;
        }

        // Kick's token request ALWAYS stays in-process (httpSend false): it is the
        // only call carrying the client secret, so it must never reach a curl
        // command line. It also never needs curl — the Kick app token lasts ~57
        // days, so it doesn't expire across a sleep and is not part of the
        // resume-staleness problem.
        root.kickXhr = httpSend(false, "POST",
            "https://id.kick.com/oauth/token",
            { "Content-Type": "application/x-www-form-urlencoded" },
            "grant_type=client_credentials"
                + "&client_id=" + encodeURIComponent(root.kickClientId)
                + "&client_secret=" + encodeURIComponent(root.kickClientSecret),
            function (status, text) {
                root.kickXhr = null;
                if (status === 200) {
                    var r;
                    try { r = JSON.parse(text); } catch (e) {
                        root.statusText = i18n("Network error — will retry");
                        onErr(); return;
                    }
                    Plasmoid.configuration.kickToken = r.access_token;
                    Plasmoid.configuration.kickTokenExpiry = Date.now() + (r.expires_in * 1000);
                    root.kickState = "linked";
                    cb(r.access_token);
                } else if (status === 0) {
                    root.statusText = i18n("Network error — will retry");
                    onErr();
                } else {
                    // 401/invalid_client → the saved Client ID/Secret are wrong.
                    clearKickTokens();
                    root.kickState = "unlinked";
                    root.statusText = i18n("Kick sign-in failed — check your Client ID and Secret");
                    onErr();
                }
            });
    }

    // Validate freshly entered credentials by minting a token now, so the
    // settings page can confirm the connection instead of failing silently later.
    function connectKick() {
        if (!root.kickConfigured) {
            root.statusText = i18n("Enter your Kick Client ID and Secret first");
            return;
        }
        clearKickTokens();
        root.kickState = "linking";
        root.statusText = i18n("Connecting to Kick…");
        ensureKickToken(function () {
            root.statusText = i18n("Connected! Checking streams…");
            root.checkKickStreams(false);
        }, function () {});
    }

    function disconnectKick() {
        clearKickTokens();
        // Also drop the saved credentials so the disconnect sticks across
        // restarts (kickState seeds from whether credentials are present).
        Plasmoid.configuration.kickClientId = "";
        Plasmoid.configuration.kickClientSecret = "";
        root.kickStreams = [];
        root.kickState = "unlinked";
        rebuildLiveStreams();
    }

    function checkKickStreams(retry) {
        if (root.kickState !== "linked") { root.kickStreams = []; return; }
        var chans = kickChannelList();
        if (chans.length === 0) {
            root.kickStreams = [];
            rebuildLiveStreams();
            return;
        }
        if (root.kickBusy && (Date.now() - root.kickPollStart) < root.busyStaleMs) {
            return;
        }
        root.kickBusy = true;
        root.kickPollStart = Date.now();

        ensureKickToken(function (token) {
            // /public/v1/channels takes up to 50 slug params and returns every
            // requested channel (live or not), so we filter on is_live ourselves.
            var qs = chans.slice(0, 50).map(function (c) {
                return "slug=" + encodeURIComponent(c);
            }).join("&");

            root.kickXhr = httpSend(root.curlEnabled, "GET",
                "https://api.kick.com/public/v1/channels?" + qs,
                { "Authorization": "Bearer " + token, "Accept": "application/json" },
                null,
                function (status, text) {
                    root.kickXhr = null;
                    root.kickBusy = false;
                    if (status === 200) {
                        root.kickFailed = false;
                        var data;
                        try { data = (JSON.parse(text).data) || []; } catch (e) { data = []; }
                        var arr = [];
                        for (var i = 0; i < data.length; i++) {
                            var c = data[i];
                            if (!c.stream || !c.stream.is_live) continue; // offline → skip
                            arr.push({
                                platform: "kick",
                                key: "kick:" + c.slug,
                                login: c.slug,
                                // Kick's channel list carries no display name → use the slug.
                                name: c.slug,
                                game: (c.category && c.category.name) || "",
                                viewers: c.stream.viewer_count || 0,
                                title: c.stream_title || ""
                            });
                        }
                        root.kickStreams = arr;
                        rebuildLiveStreams();
                        root.noteHealthy();
                    } else if (status === 401 && !retry) {
                        // Token rejected/expired → drop it and re-mint once.
                        clearKickTokens();
                        root.checkKickStreams(true);
                    } else if (status === 0 || status >= 500) {
                        // Connection failed or server-side hiccup → transient, fast-retry.
                        root.kickFailed = true;
                        root.statusText = i18n("Network error — will retry");
                        root.scheduleRetry();
                    } else {
                        root.statusText = i18n("Kick API error (%1)", status);
                    }
                });
        }, function () { // ensureKickToken failed (network not up at resume) →
            // unstick polling and fast-retry instead of waiting a full interval.
            root.kickBusy = false;
            root.kickFailed = true;
            root.scheduleRetry();
        });
    }

    Timer {
        id: pollTimer
        interval: Math.max(30, Plasmoid.configuration.pollInterval) * 1000
        running: root.anyLinked
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.refreshAll();
        }
    }

    // ------------------------------------------------------------------
    // Resume-from-suspend recovery.
    //
    // pollTimer above is driven by the monotonic clock, which pauses while the
    // machine is asleep — so after a long suspend its next tick can be most of
    // an interval away, and any in-flight poll guard left raised as the machine
    // went down keeps the widget pinned to its pre-sleep snapshot until then.
    // The busyStaleMs guard only self-heals once a poll actually runs, so it
    // inherits the same delay. We instead watch the WALL clock (Date.now, which
    // keeps counting through suspend) on a short heartbeat: a tick that lands
    // far later than its schedule means the machine just woke, so we drop any
    // wedged guards and re-arm the poll cadence to refresh immediately.
    property double lastHeartbeat: 0
    readonly property int heartbeatMs: 30000
    Timer {
        id: resumeWatch
        interval: root.heartbeatMs
        running: root.anyLinked
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var now = Date.now();
            // Allow generous slack over the 30s cadence so ordinary event-loop
            // jitter never reads as a resume; only a real time jump trips it.
            var jumped = root.lastHeartbeat > 0
                && (now - root.lastHeartbeat) > root.heartbeatMs + 15000;
            root.lastHeartbeat = now;
            if (jumped) {
                root.twitchBusy = false;
                root.kickBusy = false;
                pollTimer.restart(); // triggeredOnStart → refreshAll() right now
            }
        }
    }

    // ------------------------------------------------------------------
    // Transient-failure fast retry.
    //
    // Right after resume the network stack is usually still down for a few
    // seconds, so the first poll fails instantly (status 0 / network error).
    // Without this the widget would then sit on its pre-sleep snapshot until the
    // next *scheduled* poll — a full pollInterval (≥30s) of staleness, and after
    // a deep suspend the outage can span several of those, which reads as "never
    // recovers". On any transient failure we instead re-poll on a short backoff
    // (2s → 4s → … → 30s), resetting to idle once both providers are healthy
    // again. A genuine longer outage is simply ridden out at the 30s ceiling.
    property bool twitchFailed: false
    property bool kickFailed: false
    property int retryBackoffMs: 0          // 0 = not currently retrying
    readonly property int retryBaseMs: 2000
    readonly property int retryMaxMs: 10000 // cap the gap so recovery after the
                                            // network returns is ≤ this, not 30s
    // The single in-flight request handle per provider (refresh token *or*
    // streams call; only one is ever live at a time per provider). Tracked so the
    // watchdog can abort a hung request instead of abandoning it: an abandoned
    // request would (a) pile up into a "herd" that all completes at once on
    // reconnect, and (b) for the token refresh, let several one-time-use refresh
    // tokens be spent together → all but one get invalid_grant → a spurious
    // unlink. Aborting a request that never reached the server avoids both. Each
    // handle is whatever httpSend() returned (XHR- or curl-backed) and exposes a
    // single abort() that silences/cancels it.
    property var twitchXhr: null
    property var kickXhr: null
    function abortInflight(x) {
        if (x && x.abort) { try { x.abort(); } catch (e) {} }
    }
    Timer {
        id: retryTimer
        repeat: false
        onTriggered: {
            root.refreshAll();
        }
    }
    // Arm the retry after a transient failure. Both providers can fail in the
    // same cycle; only the first arms it (and advances the backoff one step), so
    // the interval grows once per actual retry rather than once per failure.
    function scheduleRetry() {
        if (retryTimer.running) return; // already armed for this cycle
        root.retryBackoffMs = root.retryBackoffMs > 0
            ? Math.min(root.retryBackoffMs * 2, root.retryMaxMs)
            : root.retryBaseMs;
        retryTimer.interval = root.retryBackoffMs;
        retryTimer.restart();
    }
    // A provider just succeeded; if neither is in a failed state, stop retrying.
    function noteHealthy() {
        if (!root.twitchFailed && !root.kickFailed) {
            retryTimer.stop();
            root.retryBackoffMs = 0;
        }
    }

    // Watchdog for silently-hung requests.
    //
    // When the network is down at the instant a request is sent, the XHR can
    // hang with NO callback ever firing — not onreadystatechange, not onerror,
    // and (observed) not even the 15s xhr.timeout. That strands the busy guard
    // true and, fatally, never triggers scheduleRetry, so the error-path retry
    // above can't help. A Timer fires reliably regardless, so while a request is
    // in flight we watch for one that has outlived watchdogMs, force-fail it, and
    // kick off the same backoff retry. This is the recovery path that does not
    // depend on the network stack ever calling us back.
    readonly property int watchdogMs: 8000
    Timer {
        id: watchdog
        interval: 2000
        running: root.busy   // only ticks while a poll is in flight
        repeat: true
        onTriggered: {
            var now = Date.now();
            var hung = false;
            if (root.twitchBusy && (now - root.twitchPollStart) > root.watchdogMs) {
                root.abortInflight(root.twitchXhr); root.twitchXhr = null;
                root.twitchBusy = false; root.twitchFailed = true; hung = true;
            }
            if (root.kickBusy && (now - root.kickPollStart) > root.watchdogMs) {
                root.abortInflight(root.kickXhr); root.kickXhr = null;
                root.kickBusy = false; root.kickFailed = true; hung = true;
            }
            if (hung) root.scheduleRetry();
        }
    }

    // Re-check immediately when channels change (while connected).
    Connections {
        target: Plasmoid.configuration
        function onChannelsChanged() { root.checkStreams(false); }
        function onKickChannelsChanged() { root.checkKickStreams(false); }
        // First time the user opts into curl, probe for it so curlEnabled can
        // flip without waiting for a restart.
        function onUseCurlResumeChanged() {
            if (Plasmoid.configuration.useCurlResume) root.probeCurl();
        }
        // The settings Link/Unlink and Kick Connect/Disconnect buttons set these
        // flags; consume them here so the config form never has to touch (and risk
        // clobbering) the tokens. Guards make these idempotent: re-applying the
        // dialog (which keeps its local flag set) is a harmless no-op instead of
        // re-firing the flow.
        function onUnlinkRequestedChanged() {
            if (Plasmoid.configuration.unlinkRequested) {
                Plasmoid.configuration.unlinkRequested = false;
                if (root.authState !== "unlinked") root.unlink();
            }
        }
        function onKickConnectRequestedChanged() {
            if (Plasmoid.configuration.kickConnectRequested) {
                Plasmoid.configuration.kickConnectRequested = false;
                root.connectKick();
            }
        }
        function onKickDisconnectRequestedChanged() {
            if (Plasmoid.configuration.kickDisconnectRequested) {
                Plasmoid.configuration.kickDisconnectRequested = false;
                if (root.kickState !== "unlinked") root.disconnectKick();
            }
        }
        function onLinkRequestedChanged() {
            if (Plasmoid.configuration.linkRequested) {
                Plasmoid.configuration.linkRequested = false;
                if (root.authState === "unlinked") root.startDeviceAuth();
            }
        }
    }

    // ------------------------------------------------------------------
    // Delegate for one live streamer (clickable chip)
    // ------------------------------------------------------------------
    Component {
        id: streamDelegate

        Rectangle {
            id: chip
            radius: root.chipFrameEnabled
                ? (root.chipCornerStyle === 1 ? root.chipCornerRadius : 0)
                : Kirigami.Units.smallSpacing
            border.width: root.chipFrameEnabled ? Math.max(0, root.chipBorderWidth) : 0
            border.color: root.chipBorderColor
                ? root.chipBorderColor : Kirigami.Theme.highlightColor
            color: {
                if (hover.hovered) return Kirigami.Theme.highlightColor;
                if (!root.chipFrameEnabled) return "transparent";
                if (root.chipFillMode === 1) return "transparent"; // gradient set below
                if (root.chipFillMode === 2) {                     // random per streamer
                    var rc = root.streamColors[modelData.key];
                    return root.withAlpha(rc ? rc : Kirigami.Theme.backgroundColor,
                                          root.chipFillOpacity);
                }
                var list = root.parseColorList(root.chipFillColors); // single → first color
                return root.withAlpha(list.length ? list[0]
                    : Kirigami.Theme.backgroundColor, root.chipFillOpacity);
            }
            // Keep the hover highlight readable by dropping the gradient while hovered.
            gradient: (root.chipFrameEnabled && root.chipFillMode === 1 && !hover.hovered)
                ? root.chipGradient : null
            implicitWidth: chipRow.implicitWidth + Kirigami.Units.largeSpacing
            implicitHeight: chipRow.implicitHeight + Kirigami.Units.smallSpacing
            Layout.fillWidth: root.orientation === 1

            // Surface on hover what vertical mode would show inline, plus the
            // full stream title: title on top, then "game • viewers" beneath.
            readonly property string tipText: {
                var v = i18np("%1 viewer", "%1 viewers", modelData.viewers);
                var meta = modelData.game.length > 0 ? modelData.game + " • " + v : v;
                return modelData.title.length > 0 ? modelData.title + "\n" + meta : meta;
            }
            // Plasma's ToolTipArea renders in a dedicated tooltip window that
            // stacks above normal windows; a QQC2.ToolTip draws inside the
            // widget's own scene, so on the desktop layer it was covered by
            // any window overlapping the widget.
            PlasmaCore.ToolTipArea {
                anchors.fill: parent
                active: root.showTooltip && root.orientation === 0
                mainText: modelData.name
                subText: chip.tipText
                textFormat: Text.PlainText
            }

            RowLayout {
                id: chipRow
                // Left-align (not centerIn) so every entry's dot/name share a
                // common left edge when chips are stretched to full width.
                anchors.left: parent.left
                anchors.leftMargin: Kirigami.Units.smallSpacing
                anchors.verticalCenter: parent.verticalCenter
                spacing: Kirigami.Units.smallSpacing

                Rectangle { // "live" dot — coloured per platform (Twitch / Kick)
                    Layout.preferredWidth: Math.round(root.fontSize * 0.5)
                    Layout.preferredHeight: Layout.preferredWidth
                    radius: width / 2
                    color: modelData.platform === "kick" ? "#53FC18" : "#e62117"
                }

                ColumnLayout {
                    spacing: 0
                    PC3.Label {
                        text: modelData.name
                        font.pixelSize: root.fontSize
                        font.family: root.fontFamily ? root.fontFamily : Kirigami.Theme.defaultFont.family
                        // A subtle shadow-ish contrast helps on a frameless/transparent widget
                        style: Text.Outline
                        styleColor: Qt.rgba(0, 0, 0, 0.6)
                        color: hover.hovered ? root.hoverColor : root.normalColor
                    }
                    PC3.Label { // extra detail only makes sense in vertical mode
                        visible: root.orientation === 1 && modelData.game.length > 0
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: modelData.game + " • " +
                              i18np("%1 viewer", "%1 viewers", modelData.viewers)
                        font.pixelSize: Math.max(8, Math.round(root.fontSize * 0.72))
                        font.family: root.fontFamily ? root.fontFamily : Kirigami.Theme.defaultFont.family
                        opacity: 0.85
                        style: Text.Outline
                        styleColor: Qt.rgba(0, 0, 0, 0.6)
                        color: hover.hovered ? root.hoverColor : root.normalColor
                    }
                }
            }

            HoverHandler {
                id: hover
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                onTapped: Qt.openUrlExternally(
                    (modelData.platform === "kick" ? "https://kick.com/" : "https://twitch.tv/")
                    + modelData.login)
            }
        }
    }

    // ------------------------------------------------------------------
    // Compact (panel) representation
    // ------------------------------------------------------------------
    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            anchors.fill: parent
            source: "media-record"
            active: parent.containsMouse

            Rectangle { // count badge
                visible: root.anyLinked && root.liveStreams.length > 0
                anchors { right: parent.right; top: parent.top }
                width: Math.max(height, badge.implicitWidth + 4)
                height: Math.round(parent.height * 0.5)
                radius: height / 2
                color: "#e62117"
                PC3.Label {
                    id: badge
                    anchors.centerIn: parent
                    text: root.liveStreams.length
                    color: "white"
                    font.pixelSize: Math.round(parent.height * 0.7)
                    font.bold: true
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Full representation — frameless & transparent.
    //   • connected + live    → just the clickable streamer names (Twitch + Kick)
    //   • connected + none    → nothing (a faint hint appears on hover)
    //   • nothing connected   → the link/setup UI
    //   • Twitch linking      → the device-code approve UI
    //   • hovering            → small refresh/configure controls appear
    // ------------------------------------------------------------------
    fullRepresentation: Item {
        id: rep
        // Size to the content so a horizontal layout can be as thin as the text
        // (lets you align it flush to a screen edge). No tall minimum height.
        Layout.minimumWidth: Kirigami.Units.gridUnit * 3
        Layout.minimumHeight: contentCol.implicitHeight + 2 * root.framePadding
        implicitWidth: contentCol.implicitWidth + 2 * root.framePadding
        implicitHeight: contentCol.implicitHeight + 2 * root.framePadding

        // Optional widget-level border + translucent background (opt-in).
        Rectangle {
            id: widgetBg
            z: -1
            visible: root.widgetFrameEnabled
            anchors.fill: contentCol
            anchors.margins: -root.framePadding
            radius: root.widgetCornerStyle === 1 ? root.widgetCornerRadius : 0
            border.width: Math.max(0, root.widgetBorderWidth)
            border.color: root.widgetBorderColor
                ? root.widgetBorderColor : Kirigami.Theme.highlightColor
            color: {
                if (root.widgetFillMode === 1) return "transparent"; // gradient set below
                if (root.widgetFillMode === 2)
                    return root.withAlpha(root.widgetRandomColor, root.widgetFillOpacity);
                var list = root.parseColorList(root.widgetFillColors);
                return root.withAlpha(list.length ? list[0]
                    : Kirigami.Theme.backgroundColor, root.widgetFillOpacity);
            }
            gradient: root.widgetGradient
        }

        // Controls appear only after the pointer dwells for hoverDelay ms,
        // so sweeping the cursor across a wide strip doesn't flash them.
        property bool controlsShown: false
        HoverHandler {
            id: repHover
            onHoveredChanged: {
                if (hovered) {
                    if (root.hoverDelay <= 0) rep.controlsShown = true;
                    else hoverTimer.restart();
                } else {
                    hoverTimer.stop();
                    rep.controlsShown = false;
                }
            }
        }
        Timer {
            id: hoverTimer
            interval: root.hoverDelay
            repeat: false
            onTriggered: rep.controlsShown = true
        }

        ColumnLayout {
            id: contentCol
            // Pin the content block to the chosen edge/corner of the widget box,
            // so text can hug a side regardless of the box's forced size.
            // (Positioned with x/y to avoid conflicting-anchor combinations.)
            x: root.hAlign === 0 ? root.framePadding
               : root.hAlign === 2 ? (parent.width - width - root.framePadding)
               : (parent.width - width) / 2
            y: root.vAlign === 0 ? root.framePadding
               : root.vAlign === 2 ? (parent.height - height - root.framePadding)
               : (parent.height - height) / 2
            spacing: Kirigami.Units.smallSpacing

            // ---- nothing connected: prompt to link Twitch and/or set up Kick ----
            ColumnLayout {
                Layout.fillWidth: true
                visible: !root.anyLinked && root.authState !== "linking"
                spacing: Kirigami.Units.smallSpacing

                PC3.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    opacity: 0.85
                    text: root.clientId
                        ? i18n("Link your Twitch account, or set up Kick in settings.")
                        : i18n("Set a Client ID in settings, then link.")
                }
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Kirigami.Units.smallSpacing
                    PC3.Button {
                        icon.name: "link"
                        text: i18n("Link Twitch account")
                        enabled: root.clientId.length > 0
                        onClicked: root.startDeviceAuth()
                    }
                    PC3.ToolButton {
                        icon.name: "configure"
                        display: QQC2.AbstractButton.IconOnly
                        onClicked: Plasmoid.internalAction("configure").trigger()
                        QQC2.ToolTip.text: i18n("Configure…")
                        QQC2.ToolTip.visible: hovered
                    }
                }
                PC3.Label {
                    Layout.fillWidth: true
                    visible: root.statusText.length > 0
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    opacity: 0.6
                    font: Kirigami.Theme.smallFont
                    text: root.statusText
                }
            }

            // ---- linking: show the code + open-browser ----
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.authState === "linking"
                spacing: Kirigami.Units.smallSpacing

                PC3.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: i18n("Approve on the Twitch page that opened, or go to twitch.tv/activate and enter:")
                }
                PC3.Label {
                    Layout.alignment: Qt.AlignHCenter
                    visible: root.userCode.length > 0
                    text: root.userCode
                    font.family: "monospace"
                    font.bold: true
                    font.pixelSize: Math.round(root.fontSize * 1.6)
                }
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Kirigami.Units.smallSpacing
                    PC3.Button {
                        icon.name: "internet-services"
                        text: i18n("Open Twitch")
                        visible: root.verificationUri.length > 0
                        onClicked: Qt.openUrlExternally(root.verificationUri)
                    }
                    PC3.Button {
                        icon.name: "dialog-cancel"
                        text: i18n("Cancel")
                        onClicked: root.unlink()
                    }
                }
                PC3.Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    opacity: 0.6
                    font: Kirigami.Theme.smallFont
                    text: root.statusText
                }
            }

            // ---- connected + live: the clickable names ----
            GridLayout {
                Layout.fillWidth: true
                visible: root.anyLinked && root.liveStreams.length > 0
                // Horizontal: one row of N chips. Vertical: one column.
                columns: root.orientation === 0 ? Math.max(1, root.liveStreams.length) : 1
                rowSpacing: Kirigami.Units.smallSpacing
                columnSpacing: Kirigami.Units.smallSpacing

                Repeater {
                    model: root.liveStreams
                    delegate: streamDelegate
                }
            }

            // ---- Twitch auth lost while another platform is still linked ----
            // The full setup screen above only shows when NOTHING is linked, so a
            // revoked/expired Twitch token (or a config-file hiccup) with Kick
            // still connected would otherwise drop every Twitch channel silently —
            // anyLinked stays true, no prompt appears, and the "please re-link"
            // status is clobbered to "Nobody's live" on the next poll. Surface a
            // focused, always-visible re-link prompt whenever Twitch channels are
            // configured but Twitch isn't linked (and isn't mid-linking).
            RowLayout {
                Layout.fillWidth: true
                visible: root.anyLinked && root.authState === "unlinked"
                         && root.channelList().length > 0
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: "dialog-warning"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                PC3.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    opacity: 0.85
                    font: Kirigami.Theme.smallFont
                    text: i18n("Twitch isn't linked")
                    style: Text.Outline
                    styleColor: Qt.rgba(0, 0, 0, 0.6)
                }
                PC3.Button {
                    icon.name: "link"
                    text: i18n("Link")
                    onClicked: root.startDeviceAuth()
                }
            }

            // ---- connected + nothing live: faint hint, only while hovered ----
            PC3.Label {
                Layout.fillWidth: true
                visible: root.anyLinked && root.liveStreams.length === 0 && rep.controlsShown
                text: root.statusText
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                opacity: 0.5
                font: Kirigami.Theme.smallFont
                style: Text.Outline
                styleColor: Qt.rgba(0, 0, 0, 0.6)
            }
        }

        // ---- floating hover controls (top-right), only when connected ----
        RowLayout {
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: 0
            visible: root.anyLinked && rep.controlsShown
            opacity: 0.9

            PC3.ToolButton {
                icon.name: "view-refresh"
                display: QQC2.AbstractButton.IconOnly
                enabled: !root.busy
                onClicked: root.refreshAll()
                QQC2.ToolTip.text: i18n("Refresh now")
                QQC2.ToolTip.visible: hovered
            }
            PC3.ToolButton {
                icon.name: "configure"
                display: QQC2.AbstractButton.IconOnly
                onClicked: Plasmoid.internalAction("configure").trigger()
                QQC2.ToolTip.text: i18n("Configure…")
                QQC2.ToolTip.visible: hovered
            }
        }
    }
}
