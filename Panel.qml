import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Google Calendar panel: day, week and month views over every connected
// account, with an inline editor and a settings page.
//
// The look is a printed timetable rather than a web calendar — hairline
// rules instead of boxes, monospace numerals holding their column, and no
// colour anywhere except the colours Google already assigned to the events
// themselves. That way the chroma on screen is information, not decoration.
//
// All Google traffic goes through `omagoocal`; this file never speaks
// HTTP. One `sync` subprocess per refresh returns accounts, calendars and
// events together.
Panel {
  id: root
  moduleName: "io.github.huligabuliga.omagoocal"
  ipcTarget: "io.github.huligabuliga.omagoocal"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The backend ships inside the plugin, so a clone of the repo is the whole
  // thing — nothing to put on PATH before it works.
  readonly property string backend:
    Qt.resolvedUrl("omagoocal").toString().replace(/^file:\/\//, "")

  // ---------------------------------------------------------------- state
  property string view: "week"                  // day | week | month | settings
  property date anchor: new Date()              // the date the view is built around
  property date now: new Date()
  property var events: []
  property var calendars: []
  property var accounts: []
  property var cfg: ({})

  // ---- Dependencies. GNOME Online Accounts is what makes this plugin
  //      installable by anyone: it carries the distro's own Google OAuth
  //      client, so no user ever creates a Google Cloud project and the
  //      plugin never needs Google's verification review.
  //
  //      The install follows the Omarchy convention: Omarchy's own installer
  //      in a visible floating terminal (which is also where its password
  //      prompt is answered), then a poll of pacman until the packages land.
  //
  //      Every executable here is an absolute path and no shell of ours is
  //      involved: the probe is pacman itself, and the install hands the
  //      terminal wrapper one fixed command.
  property bool depsInstalled: false
  property bool depsChecking: true
  property bool installing: false
  property string installError: ""

  readonly property var requiredPackages: ["gnome-online-accounts", "gnome-online-accounts-gtk"]
  readonly property string pacman: "/usr/bin/pacman"
  readonly property string omarchyBin: "/usr/share/omarchy/bin"

  function checkDeps() {
    if (depsProc.running) return
    depsChecking = true
    depsProc.command = [pacman, "-Q"].concat(requiredPackages)
    depsProc.running = true
  }

  function installDeps() {
    installing = true
    installError = ""
    installProc.command = [
      omarchyBin + "/omarchy-launch-floating-terminal-with-presentation",
      omarchyBin + "/omarchy-pkg-add " + requiredPackages.join(" ")]
    installProc.startDetached()
    installPoll.restart()
    installTimeout.restart()
  }
  property bool busy: false
  property string error: ""
  property bool everSynced: false
  // Set when the user asks for settings, so a background refresh never yanks
  // them out of it — and cleared when they pick a calendar view, so the
  // not-connected screen can hand back over once an account appears.
  property bool settingsPinned: false
  property var editing: null                    // event under the editor, or null

  readonly property int weekStart: cfg.weekStart === undefined ? 1 : cfg.weekStart
  readonly property int notifyMinutes: cfg.notifyMinutes === undefined ? 10 : cfg.notifyMinutes
  readonly property int dayStartHour: cfg.dayStartHour === undefined ? 7 : cfg.dayStartHour
  readonly property int refreshMinutes: Math.max(1, cfg.refreshMinutes || 5)
  readonly property bool hours12: cfg.hours12 === true
  readonly property bool connected: accounts.length > 0
  readonly property var nextEvent: Model.nextEvent(events, now)

  // ------------------------------------------------------------- palette
  //
  // Everything downstream reads these four, so a theme change moves the
  // whole panel at once and no child ever names a literal colour.
  readonly property color ink: bar ? bar.foreground : Color.popups.text
  readonly property string mono: bar ? bar.fontFamily : Style.font.family
  // Omarchy ships light themes as well as dark ones, and several choices
  // below only hold for one or the other.
  readonly property bool lightSurface: Model.isLightSurface(String(Color.popups.background))

  readonly property color hair: Util.alpha(ink, lightSurface ? 0.16 : 0.12)
  // Secondary and tertiary text. Kept well above the 3:1 floor a dark ground
  // needs — 45%/26% of the foreground looked refined and read as unfinished.
  readonly property color dim: Util.alpha(ink, 0.66)
  readonly property color faint: Util.alpha(ink, 0.44)

  // ---------------------------------------------------------- navigation
  readonly property var viewDays: view === "day"
    ? [Model.startOfDay(anchor)]
    : Model.weekDays(anchor, weekStart)

  readonly property string title: view === "settings"
    ? "SETTINGS"
    : Qt.formatDate(anchor, "MMMM").toUpperCase()

  readonly property string subtitle: {
    if (view === "settings") {
      if (!connected) return "NOT CONNECTED"
      var on = calendars.filter(function(c) { return !c.error && c.enabled }).length
      return accounts.length + (accounts.length === 1 ? " ACCOUNT" : " ACCOUNTS")
        + " · " + on + (on === 1 ? " CALENDAR" : " CALENDARS")
    }
    if (view === "month") return anchor.getFullYear() + ""
    if (view === "day") return Qt.formatDate(anchor, "dddd d").toUpperCase() + " · " + anchor.getFullYear()
    var days = viewDays
    return anchor.getFullYear() + " · WEEK " + Model.isoWeek(anchor)
      + " · " + Qt.formatDate(days[0], "d MMM").toUpperCase()
      + " – " + Qt.formatDate(days[6], "d MMM").toUpperCase()
  }

  readonly property bool onToday: view === "month"
    ? (anchor.getFullYear() === now.getFullYear() && anchor.getMonth() === now.getMonth())
    : (view === "day" ? Model.sameDay(anchor, now)
                      : Model.startOfWeek(anchor, weekStart).getTime() === Model.startOfWeek(now, weekStart).getTime())

  function step(direction) {
    if (view === "month") anchor = Model.addMonths(anchor, direction)
    else if (view === "day") anchor = Model.addDays(anchor, direction)
    else anchor = Model.addDays(anchor, direction * 7)
    ensureRange()
  }

  function goToday() {
    anchor = new Date()
    ensureRange()
  }

  function setView(next) {
    settingsPinned = next === "settings"
    if (next === view) return
    view = next
    ensureRange()
  }

  // ---------------------------------------------------------------- data
  //
  // A month either side of the anchor, so paging a week at a time almost
  // never costs a round trip and month view is always fully populated.
  property string loadedKey: ""
  property string pendingKey: ""   // promoted to loadedKey only once it lands

  function rangeStart() { return Model.addDays(new Date(anchor.getFullYear(), anchor.getMonth(), 1), -14) }
  function rangeEnd() { return Model.addDays(new Date(anchor.getFullYear(), anchor.getMonth() + 1, 1), 14) }

  function ensureRange() {
    var key = anchor.getFullYear() + "-" + anchor.getMonth()
    if (key === loadedKey && everSynced) return
    pendingKey = key
    sync()
  }

  property bool syncQueued: false

  property bool forceFresh: false

  function sync() {
    // A refresh asked for while one is in flight is queued, not dropped: the
    // dropped one is always the one carrying the change the user just made.
    if (busy) { syncQueued = true; return }
    busy = true
    var argv = [root.backend, "sync", Model.rfc3339(rangeStart()), Model.rfc3339(rangeEnd())]
    if (forceFresh) argv.push("fresh")
    forceFresh = false
    syncProc.command = argv
    syncProc.running = true
  }

  // The refresh button means "I don't trust what I see": skip every cache.
  function refreshNow() {
    forceFresh = true
    loadedKey = ""
    ensureRange()
  }

  // `fromCache` paints the last known result without claiming the range is
  // loaded, so the real sync that follows still runs.
  function applySync(payload, fromCache) {
    if (payload.error) { error = payload.error; return }
    var status = payload.status || {}
    // Never let a sync that started before an unsaved edit overwrite it.
    if (!configProc.running && !configDirty) {
      var incoming = status.config || {}
      if (calendarsLocal) incoming.calendars = cfg.calendars
      cfg = incoming
    }
    accounts = status.accounts || []
    calendars = payload.calendars || []
    events = Model.decorateAll(payload.events)

    // Per-calendar failures ride along inside the event list rather than
    // failing the whole refresh; one revoked account should not blank the
    // other three.
    var trouble = (payload.events || []).filter(function(e) { return e && e.error })
    error = trouble.length ? trouble[0].calendar + ": " + trouble[0].error : ""
    if (fromCache) return
    everSynced = true
    loadedKey = pendingKey         // a failed fetch leaves the month retryable

    // Routing: no account means there is nothing else to show. Once one
    // exists, hand back to the calendar unless settings were asked for.
    if (!connected) view = "settings"
    else if (view === "settings" && !settingsPinned) view = cfg.defaultView || "week"
  }

  function mutate(command, payload, onDone) {
    mutateProc.pending = onDone || null
    mutateProc.command = [root.backend, command, Qt.btoa(JSON.stringify(payload))]
    mutateProc.running = true
  }

  // ---- Config writes.
  //
  // The panel is the owner of this config while it is open, so every write
  // sends the whole document and the last one wins. A control must never wait
  // on a subprocess to show the state the user just chose, so `cfg` moves
  // first and the disk catches up.
  property bool configDirty: false
  property bool refreshAfterConfig: false
  // Once the user has touched a toggle, the panel is the authority on the
  // calendar map for the rest of the session. A sync that was already in
  // flight when they clicked would otherwise hand back the old value and
  // bounce the switch — which is exactly what "I have to click it twice"
  // looks like.
  property bool calendarsLocal: false

  function setConfig(key, value) {
    var next = {}
    for (var k in cfg) next[k] = cfg[k]
    next[key] = value
    cfg = next
    persistConfig()
  }

  function persistConfig() {
    if (configProc.running) { configDirty = true; return }
    configDirty = false
    configProc.command = [root.backend, "setall", Qt.btoa(JSON.stringify(cfg))]
    configProc.running = true
  }

  function calendarKey(cal) { return cal.account + "\t" + cal.id }

  // Read from the local config, not from the last sync: this is what makes a
  // toggle land on the first click instead of the third.
  function calendarEnabled(cal) {
    var value = (cfg.calendars || {})[calendarKey(cal)]
    return value !== false
  }

  function toggleCalendar(cal) {
    var map = {}
    for (var k in (cfg.calendars || {})) map[k] = cfg.calendars[k]
    map[calendarKey(cal)] = !calendarEnabled(cal)
    calendarsLocal = true
    refreshAfterConfig = true
    setConfig("calendars", map)
  }

  // Sign-in is GOA's window, showing Google's own consent screen. We only
  // open it, then watch for the account to appear.
  function login() {
    error = ""
    loginProc.running = true
    accountWatch.restart()
  }

  // ------------------------------------------------------------- editing
  function compose(start, allDay) {
    var writable = calendars.filter(function(c) { return c.writable && c.enabled })
    if (!writable.length) { error = "No writable calendar is enabled."; return }

    // Default to the account's own calendar. Alphabetical order lands on
    // whatever shared calendar sorts first, which is never where someone
    // means to put a new event.
    var target = writable[0]
    for (var i = 0; i < writable.length; i++) {
      if (writable[i].primary) { target = writable[i]; break }
    }
    var begin = start || new Date(now.getFullYear(), now.getMonth(), now.getDate(), now.getHours() + 1, 0)
    editing = {
      id: "",
      account: target.account,
      calendarId: target.id,
      title: "",
      allDay: allDay === true,
      startAt: begin,
      endAt: new Date(begin.getTime() + 3600000),
      location: "",
      description: "",
      colorId: "",
      color: target.color,
      writable: true
    }
  }

  function composeNow() {
    open()
    compose(null, false)
  }

  function edit(ev) {
    if (!ev.writable) { error = "That calendar is read-only."; return }
    var copy = {}
    for (var k in ev) copy[k] = ev[k]
    editing = copy
  }

  function saveEvent(ev) {
    var payload = {
      id: ev.id,
      account: ev.account,
      calendarId: ev.calendarId,
      title: ev.title || "(no title)",
      allDay: ev.allDay,
      location: ev.location,
      description: ev.description,
      colorId: ev.colorId,
      start: ev.allDay ? Model.dayKey(ev.startAt) : Model.rfc3339(ev.startAt),
      // The editor works in inclusive days; Google wants the exclusive one.
      end: ev.allDay ? Model.exclusiveEndDate(ev.endAt) : Model.rfc3339(ev.endAt)
    }
    editing = null
    busy = true
    mutate("save", payload, function() { loadedKey = ""; ensureRange() })
  }

  function deleteEvent(ev) {
    editing = null
    busy = true
    mutate("delete", { account: ev.account, calendarId: ev.calendarId, id: ev.id },
           function() { loadedKey = ""; ensureRange() })
  }

  // ------------------------------------------------------- notifications
  //
  // ponytail: fired ids live in memory, so restarting the shell inside an
  // event's lead window can repeat one notification. Persist the set if that
  // ever becomes more than a curiosity.
  property var fired: ({})

  function checkNotifications() {
    var due = Model.dueNotifications(events, now, notifyMinutes, fired)
    for (var i = 0; i < due.length; i++) {
      var ev = due[i]
      fired[ev.id] = true
      Quickshell.execDetached(["/usr/bin/notify-send", "-a", "Calendar", "-u", "normal",
        "-t", "12000", "-i", "office-calendar",
        ev.title,
        Model.relative(ev.startAt, now) + " · " + Model.rangeLabel(ev, hours12)
          + (ev.location ? "\n" + ev.location : "")])
    }
  }

  // ---------------------------------------------------------- lifecycle
  function open() {
    root.controller.show()
    now = new Date()
    if (!everSynced || !onToday) goToday()
    else ensureRange()
  }

  function close() {
    editing = null
    root.controller.hide()
  }

  function toggle() { opened ? close() : open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Component.onCompleted: {
    statusProc.running = true        // config before first paint, so the
    checkDeps()                      // panel opens on the user's default view
  }

  // Last sync, on disk. Painted before any process is spawned, so a shell
  // restart shows last week's state instantly rather than an empty grid — and
  // the bar has a next event to name from the first frame.
  FileView {
    path: String(Quickshell.env("HOME")) + "/.local/state/omagoocal/last-sync.json"
    printErrors: false
    onLoaded: {
      if (root.everSynced) return
      try {
        var snap = JSON.parse(String(text() || "{}"))
        // Only if the saved window still covers the one we are about to ask
        // for; otherwise the fetch alone is the honest picture.
        if (Model.parseStamp(snap.timeMin) <= root.rangeStart()
            && Model.parseStamp(snap.timeMax) >= root.rangeEnd())
          root.applySync(snap.payload, true)
      } catch (e) { /* no snapshot yet, or a stale shape: the sync covers it */ }
    }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      root.now = date
      root.checkNotifications()
    }
  }

  Timer {
    // Polling, not push: Google's watch channels need a public callback URL,
    // which a laptop on someone's desk does not have.
    interval: root.refreshMinutes * 60000
    running: root.connected
    repeat: true
    onTriggered: { root.loadedKey = ""; root.ensureRange() }
  }

  Process {
    id: syncProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        try { root.applySync(JSON.parse(String(text || "{}"))) }
        catch (e) { root.error = "Backend returned junk: " + String(text).substring(0, 120) }
        root.checkNotifications()
        if (root.syncQueued) { root.syncQueued = false; Qt.callLater(root.sync) }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") console.warn("omagoocal/sync", text)
    }
    onExited: function(code) { if (code !== 0) root.busy = false }
  }

  Process {
    id: statusProc
    command: [root.backend, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var status = JSON.parse(String(text || "{}"))
          root.cfg = status.config || {}
          root.accounts = status.accounts || []
          root.view = root.connected ? (root.cfg.defaultView || "week") : "settings"
          // Until now the first fetch waited for a click or the 5-minute
          // timer, so the bar named no event for minutes after a restart.
          if (root.connected) root.ensureRange()
        } catch (e) { /* first run, nothing stored yet */ }
      }
    }
  }

  Process {
    id: mutateProc
    property var pending: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        var result = {}
        try { result = JSON.parse(String(text || "{}")) } catch (e) {}
        if (result.error) root.error = result.error
        else if (mutateProc.pending) mutateProc.pending()
        mutateProc.pending = null
      }
    }
    onExited: function(code) { if (code !== 0) root.busy = false }
  }

  Process {
    id: configProc
    onExited: {
      if (root.configDirty) { root.persistConfig(); return }
      if (!root.refreshAfterConfig) return
      root.refreshAfterConfig = false
      root.loadedKey = ""
      root.ensureRange()
    }
  }

  Process {
    id: depsProc
    onExited: function(code) {
      root.depsChecking = false
      root.depsInstalled = code === 0
      if (code !== 0) return
      root.installing = false
      installPoll.stop()
      installTimeout.stop()
      root.loadedKey = ""
      root.ensureRange()
    }
  }

  Process { id: installProc }

  Timer {
    id: installPoll
    interval: 2000
    repeat: true
    running: root.installing && !root.depsInstalled
    onTriggered: root.checkDeps()
  }

  Timer {
    id: installTimeout
    interval: 300000
    onTriggered: {
      if (!root.installing) return
      root.installing = false
      installPoll.stop()
      root.installError = "Still waiting on the installer. Check the Omarchy terminal."
    }
  }

  // After the GOA window opens, the account shows up asynchronously. Poll
  // briefly rather than making the user press refresh.
  Timer {
    id: accountWatch
    interval: 3000
    repeat: true
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks++
      root.loadedKey = ""
      root.ensureRange()
      if (root.connected || ticks > 60) stop()
    }
  }

  Process {
    id: loginProc
    command: [root.backend, "login"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = {}
        try { result = JSON.parse(String(text || "{}")) } catch (e) {}
        if (result.error) root.error = result.error
      }
    }
  }


  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(1400))
    contentHeight: panel.fittedContentHeight(Style.space(760))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      blocked: root.editing !== null
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.step(dx)
        if (dy !== 0) root.step(dy)
      }
      onActivateRequested: root.goToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "d") root.setView("day")
        else if (key === "w") root.setView("week")
        else if (key === "m") root.setView("month")
        else if (key === ",") root.setView("settings")
        else if (key === "t") root.goToday()
        else if (key === "n") root.compose(null, false)
        else if (key === "r") root.refreshNow()
        else if (key === "[") root.step(-1)
        else if (key === "]") root.step(1)
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(10)

        Header {
          id: header
          width: parent.width
          panel: root
        }

        Rectangle {
          width: parent.width
          height: 1
          color: root.hair
        }

        // ---- Body. One Loader, cross-faded on every view change, so the
        //      whole surface reads as one object being turned rather than
        //      four panes being swapped.
        Item {
          width: parent.width
          height: parent.height - header.height - Style.space(10) * 2 - 1

          Loader {
            id: body
            anchors.fill: parent
            sourceComponent: root.view === "settings" ? settingsView
                           : root.view === "month" ? monthView
                           : timeGrid

            // The fade is driven from onLoaded alone. Resetting opacity from
            // an onViewChanged handler races the reload the same view change
            // triggers, and loses often enough to show a blank panel.
            opacity: 0
            onLoaded: fade.restart()

            NumberAnimation {
              id: fade
              target: body
              property: "opacity"
              from: 0
              to: 1
              duration: 160
              easing.type: Easing.OutCubic
            }
          }

          // A first fetch across a dozen calendars takes a moment, and an
          // empty grid is indistinguishable from a broken one. Say which.
          Column {
            anchors.centerIn: parent
            spacing: Style.space(6)
            visible: root.view !== "settings" && root.events.length === 0
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.busy || !root.everSynced ? "󰃭" : "󰃰"
              color: root.faint
              font.family: root.mono
              font.pixelSize: Style.font.display
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.busy || !root.everSynced
                ? "Loading your calendars…"
                : "Nothing scheduled"
              color: root.dim
              font.family: root.mono
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }

      Component { id: monthView; MonthView { panel: root } }
      Component { id: timeGrid; TimeGrid { panel: root } }
      Component { id: settingsView; SettingsView { panel: root } }

      // ---- Editor. A scrim over the calendar rather than a second window:
      //      the event you are editing stays in the context it came from.
      Loader {
        anchors.fill: parent
        active: root.editing !== null
        sourceComponent: EventEditor { panel: root }
        z: 40
      }
    }
  }
}
