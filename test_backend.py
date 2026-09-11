#!/usr/bin/env python3
"""Self-check for omagoocal. Runs offline: D-Bus and the Google API are stubbed.

    python3 test_backend.py
"""
import base64, importlib.machinery, importlib.util, json, os, tempfile

spec = importlib.util.spec_from_loader(
    "gcal", importlib.machinery.SourceFileLoader(
        "gcal", os.path.join(os.path.dirname(os.path.abspath(__file__)), "omagoocal")))
gcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gcal)

gcal.STATE = tempfile.mkdtemp()          # mkdtemp is 0700 and ours: valid
gcal._state_cache = None
gcal.CONFIG = os.path.join(gcal.STATE, "config.json")
gcal.CACHE = os.path.join(gcal.STATE, "cache.json")
gcal.LAST_SYNC = os.path.join(gcal.STATE, "last-sync.json")

# -- config round-trip keeps defaults for untouched keys, and is chmod 600
gcal._write(gcal.CONFIG, {"notifyMinutes": 30})
assert gcal.load_config()["notifyMinutes"] == 30
assert gcal.load_config()["weekStart"] == gcal.DEFAULTS["weekStart"], "defaults fill in"
assert oct(os.stat(gcal.CONFIG).st_mode)[-3:] == "600"

# -- state I/O: random exclusive temp files, no stray .tmp, never through a symlink
assert not [f for f in os.listdir(gcal.STATE) if f.endswith(".tmp")], "temp file left behind"
link = os.path.join(gcal.STATE, "evil.json")
os.symlink("/dev/null", link)
try:
    gcal._write(link, {"x": 1})
    raise AssertionError("must refuse to write through a symlink")
except RuntimeError as exc:
    assert "symlink" in str(exc)
assert os.path.islink(link) and gcal._read(link, "fallback") == "fallback", "read must not follow it either"
os.unlink(link)

# -- a state directory that is a symlink is refused outright
real_state = gcal.STATE
gcal.STATE = tempfile.mkdtemp() + "/link"
os.symlink(real_state, gcal.STATE)
gcal._state_cache = None
try:
    gcal._state_fd()
    raise AssertionError("symlinked state dir must be refused")
except OSError:
    pass
gcal.STATE = real_state
gcal._state_cache = None

# -- bounded responses: one oversized body is an error, not a memory spike
class _Resp:
    def __init__(self, body): self.body = body
    def read(self, n=-1): return self.body if n < 0 else self.body[:n]
    def __enter__(self): return self
    def __exit__(self, *a): return False
real_urlopen = gcal.urllib.request.urlopen
gcal.urllib.request.urlopen = lambda req, timeout=None: _Resp(b"x" * (gcal.MAX_RESPONSE_BYTES + 1))
try:
    gcal.request("https://example.invalid/big")
    raise AssertionError("oversized response must raise")
except RuntimeError as exc:
    assert "MiB" in str(exc)
gcal.urllib.request.urlopen = lambda req, timeout=None: _Resp(b'{"ok": true}')
assert gcal.request("https://example.invalid/small") == {"ok": True}
gcal.urllib.request.urlopen = real_urlopen

# -- bounded pagination: an endless nextPageToken stops at the page ceiling
gcal.api = lambda account, path, params=None, payload=None, method=None: {"items": [1], "nextPageToken": "again"}
try:
    gcal.api_items("a@b.com", "/endless", {})
    raise AssertionError("endless pagination must raise")
except RuntimeError as exc:
    assert "pages" in str(exc)
gcal.api = lambda account, path, params=None, payload=None, method=None: {"items": [1] * 3000, "nextPageToken": "again"}
try:
    gcal.api_items("a@b.com", "/huge", {})
    raise AssertionError("aggregate item ceiling must raise")
except RuntimeError as exc:
    assert "items" in str(exc)

# -- ids from the API are quoted into the URL path, never concatenated raw
seen = []
gcal.api = lambda account, path, params=None, payload=None, method=None: seen.append((method, path)) or {}
gcal._tokens["a@b.com"] = "t"
gcal.save({"id": "evil/../other?sendUpdates=all", "account": "a@b.com", "calendarId": "c@x",
           "title": "T", "start": "2026-01-01T09:00:00-06:00", "end": "2026-01-01T10:00:00-06:00"})
gcal.delete({"id": "a/b?c", "account": "a@b.com", "calendarId": "c@x"})
for method, path in seen:
    assert "/../" not in path and "?" not in path, (method, path)
    assert path.count("/") == 4, "id must be one path segment: " + path
assert seen[0][0] == "PATCH" and "evil%2F..%2Fother%3FsendUpdates%3Dall" in seen[0][1]
assert seen[1][0] == "DELETE" and path.endswith("a%2Fb%3Fc")
gcal._tokens.clear()                     # leave no seeded token for the GOA test below

# -- payloads arrive as one line on stdin; oversize or non-object is refused
import io, sys as _sys
_stdin = _sys.stdin
_sys.stdin = io.StringIO(json.dumps({"notifyMinutes": 42}) + "\n")
assert gcal.main(["setall"]) == {"ok": True} and gcal.load_config()["notifyMinutes"] == 42
_sys.stdin = io.StringIO("[1,2,3]\n")
try:
    gcal.main(["setall"]); raise AssertionError("non-object config must be refused")
except RuntimeError as exc:
    assert "object" in str(exc)
_sys.stdin = io.StringIO("x" * (gcal.MAX_PAYLOAD_BYTES + 10))
try:
    gcal._payload(["save"]); raise AssertionError("oversize payload must be refused")
except RuntimeError as exc:
    assert "KiB" in str(exc)
_sys.stdin = _stdin
# ...and the base64 argv form still works for the CLI
assert gcal._payload(["save", base64.b64encode(b'{"a": 1}').decode()]) == {"a": 1}

# -- the offline snapshot: absent reads as {}, kept only while the preference
#    is on, and removed the moment it is switched off
assert gcal.main(["snapshot"]) == {}, "no snapshot yet reads as empty"
gcal._write(gcal.LAST_SYNC, {"timeMin": "a", "timeMax": "b", "payload": {"events": []}})
assert gcal.main(["snapshot"])["timeMin"] == "a"
_sys.stdin = io.StringIO(json.dumps({"snapshot": False}) + "\n")
gcal.main(["setall"])
assert not os.path.exists(gcal.LAST_SYNC), "turning the preference off must delete the snapshot"
assert gcal.main(["snapshot"]) == {}
_sys.stdin = io.StringIO(json.dumps({"snapshot": True}) + "\n")
gcal.main(["setall"])
_sys.stdin = _stdin

# -- request bodies: all-day uses date, timed uses dateTime, blanks are dropped
timed = gcal._body({"title": "T", "start": "2026-01-01T09:00:00-06:00",
                    "end": "2026-01-01T10:00:00-06:00", "location": ""})
assert "dateTime" in timed["start"] and "location" not in timed
allday = gcal._body({"title": "T", "allDay": True,
                     "start": "2026-01-01", "end": "2026-01-02", "colorId": 5})
assert allday["start"] == {"date": "2026-01-01"} and allday["colorId"] == "5"

# -- GOA account discovery: only Google accounts, only with calendar enabled
MANAGED = {"data": [{
    "/org/gnome/OnlineAccounts/Accounts/account_1": {
        "org.gnome.OnlineAccounts.Account": {
            "ProviderType": {"data": "google"},
            "PresentationIdentity": {"data": "a@b.com"},
            "Identity": {"data": "a@b.com"},
            "CalendarDisabled": {"data": False}}},
    "/org/gnome/OnlineAccounts/Accounts/account_2": {
        "org.gnome.OnlineAccounts.Account": {
            "ProviderType": {"data": "google"},
            "PresentationIdentity": {"data": "muted@b.com"},
            "CalendarDisabled": {"data": True}}},
    "/org/gnome/OnlineAccounts/Accounts/account_3": {
        "org.gnome.OnlineAccounts.Account": {
            "ProviderType": {"data": "imap_smtp"},
            "PresentationIdentity": {"data": "mail@b.com"},
            "CalendarDisabled": {"data": False}}},
    "/org/gnome/OnlineAccounts/Manager": {
        "org.gnome.OnlineAccounts.Manager": {}},
}]}

calls = []

def fake_busctl(*args):
    calls.append(args)
    if args[-1] == "GetManagedObjects":
        return MANAGED
    if args[-1] == "GetAccessToken":
        return {"data": ["ya29.token", 3599]}
    return {}

gcal.busctl = fake_busctl
found = gcal.goa_accounts()
assert list(found) == ["a@b.com"], found
assert found["a@b.com"].endswith("account_1")
assert gcal.access_token("a@b.com") == "ya29.token"
try:
    gcal.access_token("nobody@b.com")
    raise AssertionError("unknown account must raise")
except RuntimeError as exc:
    assert "Not connected" in str(exc)

# -- events(): disabled calendars are skipped, event colour beats calendar
#    colour, cancelled events drop out, all-day is detected from `date`
gcal._write(gcal.CONFIG, {"calendars": {"a@b.com\tmuted": False}})
CALS = [{"id": "primary", "summary": "Work", "backgroundColor": "#111111",
         "accessRole": "owner", "primary": True},
        {"id": "muted", "summary": "Noise", "backgroundColor": "#222222",
         "accessRole": "reader"}]
EVENTS = [{"id": "1", "summary": "Standup", "colorId": "3",
           "start": {"dateTime": "2026-01-01T09:00:00Z"},
           "end": {"dateTime": "2026-01-01T09:15:00Z"}},
          {"id": "2", "summary": "Holiday", "start": {"date": "2026-01-02"},
           "end": {"date": "2026-01-03"}},
          {"id": "3", "summary": "Gone", "status": "cancelled",
           "start": {"date": "2026-01-02"}, "end": {"date": "2026-01-03"}}]
paths = []

def fake_api(account, path, params=None, payload=None, method=None):
    paths.append(path)
    if path.endswith("calendarList"):
        return {"items": CALS}
    if path == "/colors":
        return {"event": {"3": {"background": "#ff0000"}}}
    # two pages, so pagination is exercised on every run
    if params and params.get("pageToken") == "p2":
        return {"items": EVENTS[2:]}
    return {"items": EVENTS[:2], "nextPageToken": "p2"}

gcal.api = fake_api
got = gcal.events("2026-01-01T00:00:00Z", "2026-01-08T00:00:00Z")
assert [e["title"] for e in got] == ["Standup", "Holiday"], got
assert got[0]["color"] == "#ff0000", "event colour must win"
assert got[1]["color"] == "#111111", "falls back to calendar colour"
assert got[1]["allDay"] is True and got[0]["allDay"] is False
assert got[0]["writable"] is True and got[0]["account"] == "a@b.com"
assert paths.count("/colors") == 1, "palette fetched once per account"
assert not any("muted" in p for p in paths), "disabled calendar was queried"
assert sum(1 for p in paths if p.endswith("/events")) == 2, "both pages fetched"

# -- the calendar list and palette come from the TTL cache on the second run
before = len(paths)
gcal.events("2026-01-01T00:00:00Z", "2026-01-08T00:00:00Z")
again = paths[before:]
assert not any(p.endswith("calendarList") for p in again), "calendarList should be cached"
assert "/colors" not in again, "palette should be cached"
assert sum(1 for p in again if p.endswith("/events")) == 2, "events are never cached"
gcal.events("2026-01-01T00:00:00Z", "2026-01-08T00:00:00Z", fresh=True)
assert any(p.endswith("calendarList") for p in paths[before + 2:]), "fresh bypasses the cache"

print("all checks passed")
