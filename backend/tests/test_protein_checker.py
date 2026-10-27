from app.services.protein_checker import check_dose_protein_conflict, estimate_meal_protein


def test_plate_ratio_and_no_plate_fallback():
    # With plate: chicken covering 0.64 of plate (2.0x r_ref=0.32) -> 26.0 * 2.0 = 52.0g
    res_plate = estimate_meal_protein(
        [
            {"label": "plate", "area_px": 100000, "confidence": 0.95},
            {"label": "chicken", "area_px": 64000, "confidence": 0.90},
        ]
    )
    assert res_plate["plate_detected"] is True
    assert res_plate["estimated_protein_grams"] == 52.0

    # Without plate: falls back to scale = 1.0 -> 26.0g
    res_no_plate = estimate_meal_protein(
        [{"label": "chicken", "area_px": 15000, "confidence": 0.90}]
    )
    assert res_no_plate["plate_detected"] is False
    assert res_no_plate["estimated_protein_grams"] == 26.0

    # Outside [-45m, +60m] window -> False
    assert (
        check_dose_protein_conflict(
            "2026-10-26T15:00:00+00:00", 26.0, "2026-10-26T13:00:00+00:00"
        )
        is False
    )
