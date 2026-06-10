import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "SidebarUiOptimization"
    when: windowShown
    width: 260
    height: 520

    Sidebar {
        id: sidebar

        width: 208
        height: 520
        currentView: "today"
    }

    function collectChildren(item, result) {
        if (!item || !item.children) {
            return result;
        }

        for (var i = 0; i < item.children.length; ++i) {
            var child = item.children[i];
            result.push(child);
            collectChildren(child, result);
        }

        return result;
    }

    function findText(value) {
        var children = collectChildren(sidebar, []);
        for (var i = 0; i < children.length; ++i) {
            if (children[i].text === value && children[i].font !== undefined) {
                return children[i];
            }
        }
        return null;
    }

    function findDivider() {
        var children = collectChildren(sidebar, []);
        for (var i = 0; i < children.length; ++i) {
            if (children[i].height === 1 && Qt.colorEqual(children[i].color, "#e8dfc8")) {
                return children[i];
            }
        }
        return null;
    }

    function sidebarItemForMarker(marker) {
        var markerText = findText(marker);
        verify(markerText !== null);
        return markerText.parent.parent.parent;
    }

    function markerContainerFor(marker) {
        var markerText = findText(marker);
        verify(markerText !== null);
        return markerText.parent;
    }

    function test_titleAndGroupFontWeightsUseFontWeight() {
        var title = findText("番茄Todo");
        var groupTitle = findText("时间视图");

        verify(title !== null);
        verify(groupTitle !== null);
        compare(title.font.pixelSize, 20);
        compare(title.font.weight, Font.Bold);
        verify(Qt.colorEqual(title.color, "#5d4e37"));
        compare(groupTitle.font.pixelSize, 12);
        compare(groupTitle.font.weight, Font.Bold);
        verify(Qt.colorEqual(groupTitle.color, "#8b7355"));
    }

    function test_activeSidebarItemHasVisualFeedback() {
        var activeItem = sidebarItemForMarker("今");
        var markerContainer = markerContainerFor("今");
        var markerText = findText("今");
        var mainText = findText("今日任务");

        verify(Qt.colorEqual(activeItem.color, "#f0e6d2"));
        verify(Qt.colorEqual(activeItem.border.color, "#d4a574"));
        compare(activeItem.border.width, 1);
        compare(activeItem.radius, 6);
        compare(activeItem.height, 44);
        compare(activeItem.opacity, 1.0);

        compare(markerContainer.width, 22);
        compare(markerContainer.height, 22);
        compare(markerContainer.radius, 4);
        verify(Qt.colorEqual(markerContainer.color, "#d4a574"));
        compare(markerText.font.pixelSize, 12);
        compare(markerText.font.weight, Font.Bold);
        verify(Qt.colorEqual(markerText.color, "#fffef9"));

        compare(mainText.font.pixelSize, 14);
        compare(mainText.font.weight, Font.Medium);
        verify(Qt.colorEqual(mainText.color, "#5d4e37"));
        compare(mainText.elide, Text.ElideRight);
    }

    function test_inactiveSidebarItemUsesNeutralMarkerAndText() {
        var inactiveItem = sidebarItemForMarker("专");
        var markerContainer = markerContainerFor("专");
        var markerText = findText("专");
        var mainText = findText("专注计时");

        verify(Qt.colorEqual(inactiveItem.color, "transparent"));
        verify(Qt.colorEqual(inactiveItem.border.color, "transparent"));
        compare(inactiveItem.border.width, 0);
        verify(Qt.colorEqual(markerContainer.color, "#e8dfc8"));
        compare(markerText.font.weight, Font.Bold);
        verify(Qt.colorEqual(markerText.color, "#8b7355"));
        compare(mainText.font.weight, Font.Normal);
        verify(Qt.colorEqual(mainText.color, "#8b7355"));
    }

    function test_dividerAndVersionStyles() {
        var divider = findDivider();
        var version = findText("三阶段");

        verify(divider !== null);
        compare(divider.height, 1);
        verify(Qt.colorEqual(divider.color, "#e8dfc8"));
        compare(divider.opacity, 0.8);

        verify(version !== null);
        compare(version.font.pixelSize, 12);
        compare(version.font.weight, Font.Normal);
        verify(Qt.colorEqual(version.color, "#a0896b"));
        compare(version.opacity, 0.7);
    }
}
