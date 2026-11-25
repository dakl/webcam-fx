from gestures import PinchState, pinch_progress


def test_gap_under_threshold_for_two_frames_triggers_once():
    state = PinchState()

    assert [state.update(2.0), state.update(2.0), state.update(2.0)] == [False, True, False]


def test_single_noisy_frame_under_threshold_does_not_trigger():
    state = PinchState()

    assert [state.update(2.0), state.update(8.0), state.update(2.0)] == [False, False, False]


def test_hovering_between_on_and_off_after_pinch_does_not_retrigger():
    state = PinchState()
    state.update(2.0)
    state.update(2.0)

    assert [state.update(4.5), state.update(3.0), state.update(3.0)] == [False, False, False]


def test_opening_past_off_threshold_allows_next_pinch():
    state = PinchState()
    state.update(2.0)
    state.update(2.0)
    state.update(7.0)

    assert [state.update(2.0), state.update(2.0)] == [False, True]


def test_pinch_held_while_hand_out_of_view_does_not_retrigger_on_return():
    state = PinchState()
    state.update(2.0)
    state.update(2.0)
    state.hand_lost()

    assert [state.update(2.0), state.update(2.0)] == [False, False]


def test_progress_is_zero_far_apart_and_one_at_pinch_distance():
    assert (pinch_progress(12.0), pinch_progress(3.5), pinch_progress(1.0)) == (0.0, 1.0, 1.0)
