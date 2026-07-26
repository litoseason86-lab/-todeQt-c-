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
    readonly property bool shaderFailed: d.shaderFailed
    readonly property string shaderError: d.shaderError

    signal sampleRefreshRequested()

    readonly property bool effectRequested: root.effectEnabled
                                            && Theme.glassBlurAllowed
                                            && root.sourceItem !== null
    readonly property bool effectActive: root.effectRequested
                                         && !d.shaderFailed
                                         && d.shaderReady
                                         && effectLoader.status === Loader.Ready
    readonly property bool fallbackActive: !root.effectActive

    QtObject {
        id: d

        property bool shaderReady: false
        property bool shaderFailed: false
        property string shaderError: ""
    }

    function resetShaderState() {
        d.shaderReady = false
        d.shaderFailed = false
        d.shaderError = ""
    }

    function updateShaderStatus(statusValue, errorLog) {
        if (statusValue === ShaderEffect.Compiled) {
            d.shaderReady = true
            d.shaderFailed = false
            d.shaderError = ""
        } else if (statusValue === ShaderEffect.Error) {
            // Loader.Ready 只表示 QML 对象创建成功，不代表 Shader 可用。
            // 编译失败后卸载效果层，立即显示可读的纯色降级背景。
            d.shaderReady = false
            d.shaderFailed = true
            d.shaderError = errorLog || "Shader 编译失败"
        } else {
            d.shaderReady = false
        }
    }

    function refreshSample() {
        if (effectLoader.status === Loader.Ready)
            root.sampleRefreshRequested()
    }

    onSourceItemChanged: root.refreshSample()
    onSourceRectChanged: root.refreshSample()
    onWidthChanged: root.refreshSample()
    onHeightChanged: root.refreshSample()
    onRefractionShaderChanged: root.resetShaderState()
    onEffectRequestedChanged: {
        if (!root.effectRequested)
            root.resetShaderState()
    }

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
        visible: root.fallbackActive
        radius: root.cornerRadius
        color: root.fallbackColor
    }

    Loader {
        id: effectLoader
        objectName: "liquidGlassEffectLoader"

        anchors.fill: parent
        active: root.effectRequested && !d.shaderFailed
        asynchronous: false
        sourceComponent: effectComponent
        onLoaded: root.sampleRefreshRequested()
        onStatusChanged: {
            if (status === Loader.Error) {
                d.shaderReady = false
                d.shaderFailed = true
                d.shaderError = "玻璃效果层加载失败"
            } else if (status === Loader.Null) {
                d.shaderReady = false
            }
        }
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

            Timer {
                interval: 750
                running: root.effectRequested && !d.shaderReady && !d.shaderFailed
                repeat: false

                onTriggered: {
                    if (refractionEffect.status === ShaderEffect.Uncompiled) {
                        // 软件渲染后端不会把 ShaderEffect 标记为 Error，
                        // 而是永久停在 Uncompiled，因此需要有限时的失败判定。
                        d.shaderReady = false
                        d.shaderFailed = true
                        d.shaderError = "当前图形后端未能初始化 Shader"
                    }
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

                onStatusChanged: root.updateShaderStatus(status, log)
                Component.onCompleted: root.updateShaderStatus(status, log)
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
