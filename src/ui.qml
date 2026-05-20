import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    visible: true
    width: 650
    height: 800
    title: "Mofakir AI"
    color: "#0b0f19"

    property int activeAiIndex: -1

    Connections {
        target: backend
        function onStatusChanged(text, colorHex) {
            statusLabel.text = text;
            statusLabel.color = colorHex;
        }
        function onMessageAdded(role, msgText) {
            chatModel.append({
                "role": role,
                "msgText": msgText
            });

            if (role === "ai") {
                activeAiIndex = chatModel.count - 1;
            }

            chatListView.positionViewAtEnd();
        }
        function onMessageAppended(newText) {
            if (activeAiIndex >= 0 && activeAiIndex < chatModel.count) {
                var item = chatModel.get(activeAiIndex);
                chatModel.setProperty(activeAiIndex, "msgText", item.msgText + newText);
                chatListView.positionViewAtEnd();
            }
        }
        function onInputStateChanged(enabled) {
            inputBox.enabled = enabled;
        }
        function onStopButtonStateChanged(visible) {
            stopButton.visible = visible;
        }

        function onRequireApproval(command) {
            chatModel.append({
                "role": "approval",
                "msgText": command
            });
            chatListView.positionViewAtEnd();
        }
        function onClearApproval() {
            if (chatModel.count > 0 && chatModel.get(chatModel.count - 1).role === "approval") {
                chatModel.remove(chatModel.count - 1);
            }
        }
    }

    ListModel {
        id: chatModel
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 15

        Label {
            id: statusLabel
            text: "Idle"
            color: "#6c7086"
            font.pixelSize: 13
            font.bold: true
            Layout.alignment: Qt.AlignHCenter
        }

        ListView {
            id: chatListView
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: chatModel
            spacing: 15
            clip: true
            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                contentItem: Rectangle {
                    color: "#45475a"
                    radius: 4
                }
            }

            delegate: Item {
                id: delegateRoot
                width: chatListView.width
                height: bubble.height + 10

                Text {
                    id: textMetric
                    text: role === "approval" ? "⚠️ **Action Required**\n\nThe AI wants to execute an unverified command:\n\n`" + msgText + "`" : msgText
                    textFormat: Text.MarkdownText
                    font.pixelSize: 14
                    visible: false
                }

                Rectangle {
                    id: bubble
                    y: 5

                    anchors.right: role === "user" ? parent.right : undefined
                    anchors.left: (role === "ai" || role === "approval") ? parent.left : undefined
                    anchors.horizontalCenter: role === "sys" ? parent.horizontalCenter : undefined

                    width: contentCol.width + 28
                    height: contentCol.height + 20

                    color: {
                        if (role === "user")
                            return "#89b4fa";
                        if (role === "ai" || role === "approval")
                            return "#313244";
                        if (role === "sys")
                            return msgText.indexOf("Error") !== -1 || msgText.indexOf("⚠️") !== -1 ? "#f38ba8" : "#1e1e2e";
                        return "#313244";
                    }
                    radius: role === "sys" ? 10 : 16

                    Rectangle {
                        width: 16
                        height: 16
                        color: parent.color
                        visible: role === "user" || role === "ai"
                        anchors.bottom: parent.bottom
                        anchors.right: role === "user" ? parent.right : undefined
                        anchors.left: role === "ai" ? parent.left : undefined
                    }

                    Column {
                        id: contentCol
                        anchors.centerIn: parent
                        spacing: 10

                        property real maxWidth: delegateRoot.width * 0.85 - 28

                        TextEdit {
                            id: msgTextItem
                            width: Math.min(textMetric.implicitWidth, contentCol.maxWidth)

                            text: textMetric.text
                            color: role === "user" ? "#11111b" : (role === "ai" || role === "approval" ? "#cdd6f4" : (msgText.indexOf("Error") !== -1 || msgText.indexOf("⚠️") !== -1 ? "#11111b" : "#a6e3a1"))
                            wrapMode: TextEdit.Wrap
                            textFormat: TextEdit.MarkdownText
                            readOnly: true
                            selectByMouse: true
                            font.pixelSize: 14
                            selectedTextColor: "#ffffff"
                            selectionColor: "#585b70"
                            onLinkActivated: link => Qt.openUrlExternally(link)
                        }

                        Row {
                            visible: role === "approval"
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 10
                            Button {
                                text: "Approve"
                                onClicked: backend.resolveCommandApproval(true)
                                background: Rectangle {
                                    color: "#a6e3a1"
                                    radius: 6
                                    implicitWidth: 80
                                    implicitHeight: 30
                                }
                                contentItem: Text {
                                    text: parent.text
                                    color: "#11111b"
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                            Button {
                                text: "Deny"
                                onClicked: backend.resolveCommandApproval(false)
                                background: Rectangle {
                                    color: "#f38ba8"
                                    radius: 6
                                    implicitWidth: 80
                                    implicitHeight: 30
                                }
                                contentItem: Text {
                                    text: parent.text
                                    color: "#11111b"
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: 60
                background: Rectangle {
                    color: "#1e1e2e"
                    radius: 16
                    border.color: inputBox.activeFocus ? "#89b4fa" : "#313244"
                    border.width: 2
                }

                TextArea {
                    id: inputBox
                    placeholderText: "Type a message, or press 'v' to use voice..."
                    color: "#cdd6f4"
                    font.pixelSize: 14
                    wrapMode: TextArea.Wrap
                    padding: 12

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return && !event.modifiers) {
                            var txt = text.trim();
                            if (txt !== "") {
                                if (txt.toLowerCase() === "v")
                                    backend.startVoiceRecording();
                                else
                                    backend.processInput(txt);
                                text = "";
                            }
                            event.accepted = true;
                        }
                    }
                }
            }

            Button {
                id: stopButton
                text: "⏹️"
                visible: false
                Layout.preferredWidth: 60
                Layout.preferredHeight: 60
                background: Rectangle {
                    color: parent.down ? "#f38ba8" : (parent.hovered ? "#45475a" : "#313244")
                    radius: 16
                }
                contentItem: Text {
                    text: parent.text
                    color: parent.down ? "#11111b" : "#f38ba8"
                    font.pixelSize: 24
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: backend.stopAIOperation()
            }
        }
    }
}
