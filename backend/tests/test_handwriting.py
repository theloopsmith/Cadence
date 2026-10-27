from app.services.handwriting import analyze_handwriting_opencv


def test_method_invariant_handwriting_opencv_score():
    # 35% shrinkage (-35.0%) -> score = 52.0 regardless of sam_3_1_decay_pct
    r_with_sam = analyze_handwriting_opencv(
        image_bytes=None,
        simulated_letter_heights_px=[100.0, 100.0, 100.0, 65.0, 65.0, 65.0],
        simulated_sam_decay_pct=-42.0,
    )
    r_without_sam = analyze_handwriting_opencv(
        image_bytes=None,
        simulated_letter_heights_px=[100.0, 100.0, 100.0, 65.0, 65.0, 65.0],
        simulated_sam_decay_pct=None,
    )
    assert r_with_sam["opencv_cc_decay_pct"] == -35.0
    assert r_with_sam["handwriting_score"] == 52.0
    assert r_without_sam["handwriting_score"] == 52.0
    assert r_with_sam["micrographia_detected"] is True
