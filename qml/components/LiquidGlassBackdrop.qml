pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import ".."

// 单个重要控制区域的光学背景：静态壁纸采样 → 边缘折射 → 一次模糊。
// 普通内容卡不得复用此组件，避免每张卡各占一个实时 GPU pass。
Item {
    id: root

    property var sourceItem: null
    property rect sourceRect: Qt.rect(0, 0, 1, 1)
    property real cornerRadius: Theme.radiusLg
    property real bezelWidth: 7
    property real refractionStrength: 5
    property bool effectEnabled: true
    property color fallbackColor: Theme.glassSolidCard
    property url refractionShader: "qrc:/shaders/liquid_glass.frag.qsb"

    signal sampleRefreshRequested()

    readonly property bool effectActive: root.effectEnabled
                                         && Theme.glassBlurAllowed
                                         && root.sourceItem !== null

    function refreshSample() {
        if (effectLoader.status === Loader.Ready)
            root.sampleRefreshRequested()
    }

    onSourceItemChanged: root.refreshSample()
    onSourceRectChanged: root.refreshSample()
    onWidthChanged: root.refreshSample()
    onHeightChanged: root.refreshSample()

    Connections {
        target: root.sourceItem
        ignoreUnknownSignals: true

        function onThemeIdChanged() {
            root.refreshSample()
        }
    }

    Rectangle {
        objectName: "liquidGlassFallback"
        anchors.fill: parent
        visible: !root.effectActive
        radius: root.cornerRadius
        color: root.fallbackColor
    }

    Loader {
        id: effectLoader
        objectName: "liquidGlassEffectLoader"

        anchors.fill: parent
        active: root.effectActive
        asynchronous: false
        sourceComponent: effectComponent
        onLoaded: root.sampleRefreshRequested()
    }

    Component {
        id: effectComponent

        Item {
            id: effectHost

            Connections {
                target: root

                function onSampleRefreshRequested() {
                    backdropSource.scheduleUpdate()
                }
            }

            ShaderEffectSource {
                id: backdropSource

                visible: false
                sourceItem: root.sourceItem
                sourceRect: root.sourceRect
                live: false
                recursive: false
                smooth: true
                textureSize: Qt.size(Math.max(1, effectHost.width), Math.max(1, effectHost.height))
            }

            ShaderEffect {
                id: refractionEffect
                objectName: "liquidGlassRefraction"

                anchors.fill: parent
                visible: false
                layer.enabled: true
                layer.smooth: true
                blending: false
                property variant source: backdropSource
                property vector2d itemSize: Qt.vector2d(Math.max(1, width), Math.max(1, height))
                property real cornerRadius: root.cornerRadius
                property real bezelWidth: root.bezelWidth
                property real refractionStrength: root.refractionStrength
                fragmentShader: root.refractionShader
            }

            Rectangle {
                id: effectMask

                anchors.fill: parent
                radius: root.cornerRadius
                visible: false
            }

            MultiEffect {
                objectName: "liquidGlassBlur"

                anchors.fill: parent
                source: refractionEffect
                blurEnabled: true
                blur: 0.78
                blurMax: 32
                maskEnabled: true
                maskSource: effectMask
            }
        }
    }
}
