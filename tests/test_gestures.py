from gestures import PinchMenu, PinchState, pinch_progress


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


def test_quick_pinch_moves_to_next_item_on_release():
    menu = PinchMenu(count=5)
    menu.update(True, 0.5, 0.0)

    assert (menu.update(False, 0.5, 0.2), menu.selected, menu.is_open) == ("next", 1, False)


def test_quick_pinch_on_last_item_wraps_to_first():
    menu = PinchMenu(count=3, selected=2)
    menu.update(True, 0.5, 0.0)

    assert (menu.update(False, 0.5, 0.1), menu.selected) == ("next", 0)


def test_held_pinch_opens_list_without_changing_selection():
    menu = PinchMenu(count=5, selected=1)
    menu.update(True, 0.5, 0.0)
    menu.update(True, 0.5, 0.5)

    assert (menu.is_open, menu.selected) == (True, 1)


def test_moving_held_pinch_down_two_steps_selects_two_items_later():
    menu = PinchMenu(count=5, selected=1)
    menu.update(True, 0.5, 0.0)
    menu.update(True, 0.5, 0.5)
    menu.update(True, 0.62, 0.6)

    assert menu.selected == 3


def test_moving_far_past_the_end_stops_at_last_item():
    menu = PinchMenu(count=5, selected=1)
    menu.update(True, 0.5, 0.0)
    menu.update(True, 0.5, 0.5)
    menu.update(True, 1.0, 0.6)

    assert menu.selected == 4


def test_releasing_open_list_keeps_selection_and_reports_chosen():
    menu = PinchMenu(count=5)
    menu.update(True, 0.5, 0.0)
    menu.update(True, 0.56, 0.5)

    assert (menu.update(False, 0.56, 0.7), menu.selected, menu.is_open) == ("chosen", 1, False)
