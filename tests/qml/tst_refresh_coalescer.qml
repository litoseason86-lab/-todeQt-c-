import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "RefreshCoalescer"
    when: windowShown

    Component {
        id: coalescerComponent

        RefreshCoalescer {
        }
    }

    Component {
        id: signalSpyComponent

        SignalSpy {
        }
    }

    function createCoalescer() {
        const coalescer = createTemporaryObject(coalescerComponent, testCase)
        verify(coalescer)
        return coalescer
    }

    function createTriggeredSpy(coalescer) {
        const spy = createTemporaryObject(signalSpyComponent, testCase, {
            target: coalescer,
            signalName: "triggered"
        })
        verify(spy)
        return spy
    }

    function test_synchronous_requests_are_coalesced() {
        const coalescer = createCoalescer()
        const spy = createTriggeredSpy(coalescer)

        coalescer.request()
        coalescer.request()
        coalescer.request()

        compare(coalescer.scheduled, true)
        tryCompare(spy, "count", 1, 3000)
        compare(coalescer.scheduled, false)
    }

    function test_next_event_loop_request_is_not_swallowed() {
        const coalescer = createCoalescer()
        const spy = createTriggeredSpy(coalescer)

        coalescer.request()
        tryCompare(spy, "count", 1, 3000)

        coalescer.request()
        tryCompare(spy, "count", 2, 3000)
    }

    function test_inactive_coalescer_suppresses_trigger() {
        const coalescer = createCoalescer()
        const spy = createTriggeredSpy(coalescer)

        coalescer.request()
        coalescer.active = false
        tryCompare(coalescer, "scheduled", false, 3000)
        compare(spy.count, 0)

        coalescer.active = true
        coalescer.request()
        tryCompare(spy, "count", 1, 3000)
    }

    function test_cancel_invalidates_queued_callback_without_dropping_new_request() {
        const coalescer = createCoalescer()
        const spy = createTriggeredSpy(coalescer)

        coalescer.request()
        coalescer.cancel()
        coalescer.request()

        tryCompare(spy, "count", 1, 3000)
        compare(coalescer.scheduled, false)
    }
}
