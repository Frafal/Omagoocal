import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Create, edit and delete, in a card over the calendar rather than a second
// window — the event stays in the context you opened it from.
//
// Times are typed, not spun. "9", "930", "9:30" and "9pm" all land, and the
// Save button stays dead until both ends parse, so a typo can never reach
// Google as a silently wrong timestamp.
Item {
  id: root
  property var panel: null

  readonly property var draft: panel.editing
  readonly property bool isNew: !draft || !draft.id

  // Text lives in the fields themselves. Binding a field's `text` to a
  // property the field also writes back to is the classic QML two-way trap;
  // reading the ids instead keeps one copy of every string.
  property bool allDay: draft ? draft.allDay === true : false
  property string colorId: draft ? String(draft.colorId || "") : ""
  property string calendarKey: draft ? draft.account + "\t" + draft.calendarId : ""

  readonly property var writableCalendars: panel.calendars.filter(function(c) {
    return c.writable && c.enabled
  })

  readonly property var parsedStart: {
    var day = Model.parseDayInput(startDayField.text)
    if (!day) return null
    if (allDay) return day
    var time = Model.parseTimeInput(startTimeField.text)
    return time ? Model.combine(day, time) : null
  }

  readonly property var parsedEnd: {
    var day = Model.parseDayInput(endDayField.text)
    if (!day) return null
    if (allDay) return day
    var time = Model.parseTimeInput(endTimeField.text)
    return time ? Model.combine(day, time) : null
  }

  readonly property string problem: {
    if (!Model.parseDayInput(startDayField.text)) return "Start date must look like 2026-09-10."
    if (!allDay && !Model.parseTimeInput(startTimeField.text)) return "Start time must look like 9:30, 930 or 9pm."
    if (!Model.parseDayInput(endDayField.text)) return "End date must look like 2026-09-10."
    if (!allDay && !Model.parseTimeInput(endTimeField.text)) return "End time must look like 9:30, 930 or 9pm."
    if (parsedEnd < parsedStart) return "The event ends before it starts."
    if (!calendarKey) return "Pick a calendar."
    return ""
  }

  function commit() {
    if (problem !== "") return
    var parts = calendarKey.split("\t")
    panel.saveEvent({
      id: draft.id,
      account: parts[0],
      calendarId: parts[1],
      title: titleField.text.trim(),
      allDay: allDay,
      startAt: parsedStart,
      endAt: parsedEnd,
      location: locationField.text.trim(),
      description: notesField.text,
      colorId: colorId
    })
  }

  // Nudging the end along with the start is what everyone means: moving a
  // meeting an hour later does not make it an hour longer.
  function shiftEnd(previousStart) {
    if (!previousStart || !parsedStart || !parsedEnd) return
    if (previousStart.getTime() === parsedStart.getTime()) return
    var span = parsedEnd.getTime() - previousStart.getTime()
    if (span <= 0) return
    setEnd(new Date(parsedStart.getTime() + span))
  }

  function setDuration(minutes) {
    if (!parsedStart) return
    setEnd(new Date(parsedStart.getTime() + minutes * 60000))
  }

  function setEnd(moment) {
    endDayField.text = Model.dayKey(moment)
    endTimeField.text = Model.clockLabel(moment, false)
  }

  // ---- Scrim. Clicking outside is a cancel; the card swallows its own
  //      clicks so a stray press inside never dismisses a half-typed event.
  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.popups.background, 0.82)

    MouseArea {
      anchors.fill: parent
      onClicked: root.panel.editing = null
    }
  }

  Rectangle {
    id: card
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(80), Style.space(460))
    height: Math.min(parent.height - Style.space(40), form.implicitHeight + Style.space(44))
    color: Color.popups.background
    radius: Style.cornerRadius
    border.width: 1
    border.color: Util.alpha(root.panel.ink, 0.22)

    // The card arrives from slightly below and slightly small. Anything more
    // theatrical gets tiring by the tenth event of the week.
    scale: 0.97
    opacity: 0
    Component.onCompleted: { scale = 1; opacity = 1 }
    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 160 } }

    MouseArea { anchors.fill: parent }

    // The chosen colour bleeds along the top edge of the card, so the swatch
    // you picked is visible while you keep typing.
    Rectangle {
      width: parent.width
      height: Style.space(3)
      radius: parent.radius
      color: {
        for (var i = 0; i < Model.EVENT_COLORS.length; i++)
          if (Model.EVENT_COLORS[i].id === root.colorId && Model.EVENT_COLORS[i].hex)
            return Model.EVENT_COLORS[i].hex
        return root.draft ? root.draft.color : Color.accent
      }
      Behavior on color { ColorAnimation { duration: 180 } }
    }

    Flickable {
      anchors.fill: parent
      anchors.margins: Style.space(22)
      contentHeight: form.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      Column {
        id: form
        width: parent.width
        spacing: Style.space(12)

        Text {
          text: root.isNew ? "NEW EVENT" : "EDIT EVENT"
          color: root.panel.faint
          font.family: root.panel.mono
          font.pixelSize: Style.font.caption
          font.letterSpacing: 2.0
        }

        TextField {
          id: titleField
          width: parent.width
          text: root.draft ? root.draft.title : ""
          placeholderText: "Title"
          foreground: root.panel.ink
          font.pixelSize: Style.font.title
          Component.onCompleted: { forceActiveFocus(); selectAll() }
          Keys.onEscapePressed: root.panel.editing = null
        }

        Toggle {
          width: parent.width
          label: "All day"
          checked: root.allDay
          foreground: root.panel.ink
          fontFamily: root.panel.mono
          onClicked: root.allDay = !root.allDay
        }

        // ---- When.
        Grid {
          width: parent.width
          columns: 2
          columnSpacing: Style.space(8)
          rowSpacing: Style.space(6)

          Column {
            width: (form.width - Style.space(8)) / 2
            spacing: Style.space(3)

            Text {
              text: "STARTS"
              color: root.panel.faint
              font.family: root.panel.mono
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.4
            }

            Row {
              spacing: Style.space(5)

              TextField {
                id: startDayField
                width: root.allDay ? (form.width - Style.space(8)) / 2 : Style.space(112)
                text: root.draft ? Model.dayKey(root.draft.startAt) : ""
                foreground: root.panel.ink
                // Snapshot on focus, not as a binding: a binding tracks the
                // value being edited, so it would always agree with the new
                // start and the end would never follow it.
                property var previous: null
                onActiveFocusChanged: if (activeFocus) previous = root.parsedStart
                onEditingFinished: { root.shiftEnd(previous); previous = null }
              }

              TextField {
                id: startTimeField
                visible: !root.allDay
                width: Style.space(62)
                text: root.draft ? Model.clockLabel(root.draft.startAt, false) : ""
                foreground: root.panel.ink
                property var previous: null
                onActiveFocusChanged: if (activeFocus) previous = root.parsedStart
                onEditingFinished: { root.shiftEnd(previous); previous = null }
              }
            }
          }

          Column {
            width: (form.width - Style.space(8)) / 2
            spacing: Style.space(3)

            Text {
              text: "ENDS"
              color: root.panel.faint
              font.family: root.panel.mono
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.4
            }

            Row {
              spacing: Style.space(5)

              TextField {
                id: endDayField
                width: root.allDay ? (form.width - Style.space(8)) / 2 : Style.space(112)
                // Inclusive: what Google calls the 17th, a person calls the
                // 16th. Saving converts back.
                text: root.draft ? Model.dayKey(Model.inclusiveEndDay(root.draft)) : ""
                foreground: root.panel.ink
              }

              TextField {
                id: endTimeField
                visible: !root.allDay
                width: Style.space(62)
                text: root.draft ? Model.clockLabel(root.draft.endAt, false) : ""
                foreground: root.panel.ink
              }
            }
          }
        }

        // Most events are one of four lengths. Typing an end time is the
        // exception, so the exception is what gets the keyboard.
        Row {
          visible: !root.allDay
          spacing: Style.space(4)

          Repeater {
            model: [{ label: "15m", m: 15 }, { label: "30m", m: 30 },
                    { label: "1h", m: 60 }, { label: "2h", m: 120 }]

            Button {
              required property var modelData
              text: modelData.label
              foreground: root.panel.dim
              accent: Color.accent
              fontFamily: root.panel.mono
              fontSize: Style.font.caption
              bordered: true
              onClicked: root.setDuration(modelData.m)
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.panel.ink }

        // ---- Which calendar. Multi-account lives here: the list is every
        //      writable calendar across every connected account, labelled by
        //      account when there is more than one.
        Column {
          width: parent.width
          spacing: Style.space(3)

          Text {
            text: "CALENDAR"
            color: root.panel.faint
            font.family: root.panel.mono
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.4
          }

          Dropdown {
            width: parent.width
            showLabel: false
            fontFamily: root.panel.mono
            value: root.calendarKey
            options: root.writableCalendars.map(function(c) {
              return {
                value: c.account + "\t" + c.id,
                label: c.name + (root.panel.accounts.length > 1 ? "  ·  " + c.account : "")
              }
            })
            onChanged: function(v) { root.calendarKey = v }
          }
        }

        // ---- Colour, straight from Google's own event palette.
        Column {
          width: parent.width
          spacing: Style.space(5)

          Text {
            text: "COLOUR"
            color: root.panel.faint
            font.family: root.panel.mono
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.4
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: Model.EVENT_COLORS

              Rectangle {
                required property var modelData
                readonly property bool picked: root.colorId === modelData.id

                width: Style.space(20)
                height: Style.space(20)
                radius: Style.cornerRadius > 0 ? width / 2 : 0
                color: modelData.hex !== "" ? modelData.hex : "transparent"
                border.width: modelData.hex === "" ? 1 : 0
                border.color: Util.alpha(root.panel.ink, 0.4)
                scale: picked ? 1.0 : (swatch.containsMouse ? 1.08 : 0.82)

                Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutBack } }

                // The selected swatch is the full-size one; a ring around it
                // as well would be two marks saying the same thing.
                Text {
                  anchors.centerIn: parent
                  visible: modelData.hex === ""
                  text: "󰃉"
                  color: Util.alpha(root.panel.ink, 0.55)
                  font.family: root.panel.mono
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: swatch
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.colorId = modelData.id

                  PanelToolTip {
                    visible: swatch.containsMouse
                    text: modelData.name
                  }
                }
              }
            }
          }
        }

        TextField {
          id: locationField
          width: parent.width
          text: root.draft ? root.draft.location : ""
          placeholderText: "Location"
          foreground: root.panel.ink
        }

        TextField {
          id: notesField
          width: parent.width
          text: root.draft ? root.draft.description : ""
          placeholderText: "Notes"
          foreground: root.panel.ink
        }

        Text {
          width: parent.width
          visible: root.problem !== "" && titleField.text !== ""
          text: root.problem
          color: Color.urgent
          wrapMode: Text.Wrap
          font.family: root.panel.mono
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { width: parent.width; foreground: root.panel.ink }

        Item {
          width: parent.width
          height: actions.implicitHeight

          Button {
            anchors.left: parent.left
            visible: !root.isNew
            text: "DELETE"
            foreground: Color.urgent
            accent: Color.urgent
            fontFamily: root.panel.mono
            fontSize: Style.font.caption
            bordered: true
            onClicked: confirmDelete.opened = true
          }

          Row {
            id: actions
            anchors.right: parent.right
            spacing: Style.space(6)

            Button {
              text: "CANCEL"
              foreground: root.panel.dim
              fontFamily: root.panel.mono
              fontSize: Style.font.caption
              onClicked: root.panel.editing = null
            }

            Button {
              text: root.isNew ? "CREATE" : "SAVE"
              enabled: root.problem === ""
              opacity: enabled ? 1 : 0.4
              foreground: Color.accent
              accent: Color.accent
              fontFamily: root.panel.mono
              fontSize: Style.font.caption
              bordered: true
              onClicked: root.commit()
            }
          }
        }

        Item { width: 1; height: Style.space(2) }
      }
    }
  }

  ConfirmDialog {
    id: confirmDelete
    anchors.fill: parent
    z: 10
    message: root.draft && String(root.draft.title).trim() !== ""
      ? "Delete \"" + root.draft.title + "\"?"
      : "Delete this event?"
    confirmText: "Delete"
    cancelText: "Keep"
    fontFamily: root.panel.mono
    foreground: root.panel.ink
    onConfirmed: {
      confirmDelete.opened = false
      root.panel.deleteEvent(root.draft)
    }
    onCanceled: confirmDelete.opened = false
  }

  // Esc anywhere in the card cancels; Ctrl+Enter saves from any field.
  Keys.onEscapePressed: {
    if (confirmDelete.opened) confirmDelete.opened = false
    else root.panel.editing = null
  }
  focus: true

  Shortcut {
    sequences: ["Ctrl+Return", "Ctrl+Enter"]
    onActivated: root.commit()
  }
}
