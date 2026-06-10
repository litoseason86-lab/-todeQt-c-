import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "Phase3ExportUi"
    when: windowShown
    width: 720
    height: 560

    QtObject {
        id: fakeExportService

        signal exportProgress(int current, int total)
        signal exportCompleted(bool success, string message)

        function generateFileName(type, startDate, endDate) {
            return type + "_test.csv"
        }

        function exportTasks(startDate, endDate, filePath) { return true }
        function exportFocusSessions(startDate, endDate, filePath) { return true }
        function exportAll(startDate, endDate, dirPath) { return true }
    }

    ExportDialog {
        id: exportDialog
        exportServiceRef: fakeExportService
    }

    function test_quickDateRangeButtonsWriteIsoDates() {
        exportDialog.open()
        wait(100)

        exportDialog.setDateRangeAll()
        var startDateInput = findChild(exportDialog, "startDateInput")
        var endDateInput = findChild(exportDialog, "endDateInput")

        verify(startDateInput !== null)
        verify(endDateInput !== null)
        compare(startDateInput.text, "2020-01-01")
        verify(endDateInput.text.length === 10)
        exportDialog.close()
    }

    function test_validateRejectsInvertedRange() {
        exportDialog.open()
        wait(100)

        var startDateInput = findChild(exportDialog, "startDateInput")
        var endDateInput = findChild(exportDialog, "endDateInput")
        startDateInput.text = "2026-06-10"
        endDateInput.text = "2026-06-01"

        verify(!exportDialog.validateRange())
        compare(exportDialog.statusText, "开始日期不能晚于结束日期")
        exportDialog.close()
    }

    function test_progressSignalUpdatesProgressState() {
        exportDialog.open()
        wait(100)

        fakeExportService.exportProgress(2, 5)

        compare(exportDialog.exportCurrent, 2)
        compare(exportDialog.exportTotal, 5)
        exportDialog.close()
    }

    function test_completedSignalKeepsSpecificErrorMessage() {
        exportDialog.open()
        wait(100)

        fakeExportService.exportCompleted(false, "无法创建文件: Permission denied")

        compare(exportDialog.statusText, "错误：无法创建文件: Permission denied")
        exportDialog.close()
    }
}
