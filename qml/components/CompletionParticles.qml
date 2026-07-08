import QtQuick
import ".."

// 任务完成庆祝粒子：从给定原点向 6 个方向迸发的小圆点，各自飞出并淡出后自毁。
// 从 TaskItem 抽出，零外部状态依赖；TaskItem 只负责计算复选框中心这个业务原点。
Item {
    id: root

    objectName: "completionParticleContainer"
    enabled: false
    z: 20

    readonly property int particleCount: children.length

    // 配置随组件走：颜色、方向和生命周期都属于通用庆祝效果，不属于任务项业务状态。
    readonly property var particleColors: [Theme.accent, Theme.border, Theme.borderSubtle]
    readonly property var particleDirections: [[-1, -1], [-1, 0], [-1, 1], [1, -1], [1, 0], [1, 1]]

    function burst(originX, originY) {
        // 已在迸发中就不重复创建，保持原 TaskItem 的防重入边界。
        if (root.particleCount > 0) {
            return;
        }

        var travelDistance = 38;
        for (var i = 0; i < root.particleDirections.length; ++i) {
            var direction = root.particleDirections[i];
            var particle = particleComponent.createObject(root, {
                    "x": originX,
                    "y": originY,
                    "startX": originX,
                    "startY": originY,
                    "targetX": originX + direction[0] * travelDistance,
                    "targetY": originY + direction[1] * travelDistance,
                    "directionX": direction[0],
                    "directionY": direction[1],
                    "color": root.particleColors[i % root.particleColors.length]
                });

            if (particle === null) {
                console.warn("创建任务完成粒子失败");
            }
        }
    }

    Component {
        id: particleComponent

        Rectangle {
            id: particle

            objectName: "completionParticle"
            width: 5
            height: 5
            radius: width / 2
            opacity: 1
            property real startX: 0
            property real startY: 0
            property real targetX: 0
            property real targetY: 0
            property int directionX: 0
            property int directionY: 0

            SequentialAnimation {
                running: true

                ParallelAnimation {
                    NumberAnimation {
                        target: particle
                        property: "x"
                        to: particle.targetX
                        duration: 800
                        easing.type: Easing.OutQuad
                    }

                    NumberAnimation {
                        target: particle
                        property: "y"
                        to: particle.targetY
                        duration: 800
                        easing.type: Easing.OutQuad
                    }

                    OpacityAnimator {
                        target: particle
                        from: 1
                        to: 0
                        duration: 800
                        easing.type: Easing.OutQuad
                    }
                }

                onStopped: particle.destroy()
            }
        }
    }
}
