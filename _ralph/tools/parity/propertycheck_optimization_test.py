"""Regression tests for propertycheck's evidence-safe acceleration paths."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import numpy as np

import propertycheck


def close_memmaps(*values: object) -> None:
    for value in values:
        if isinstance(value, dict):
            close_memmaps(*value.values())
        elif isinstance(value, np.memmap):
            value._mmap.close()  # type: ignore[union-attr]


def stamps() -> tuple[propertycheck.ProbeStamp, propertycheck.ProbeStamp]:
    calibration = {
        (0, 0): (0.0, 0.0), (1, 0): (1000.0, 0.0),
        (0, 1): (500.0, 866.0), (1, 1): (1500.0, 866.0),
        (0, 2): (0.0, 1732.0), (1, 2): (1000.0, 1732.0),
    }
    vanilla_maps = {
        env: {"gw": "15", "gh": "18", "height_gw": "150", "height_gh": "150",
              "tile": "100", "pass_border": "2000"}
        for env in ("surface", "underground")
    }
    expanded_maps = {
        env: {"gw": "20", "gh": "24", "height_gw": "200", "height_gh": "200",
              "tile": "100", "pass_border": "0"}
        for env in ("surface", "underground")
    }
    calibrations = {env: dict(calibration) for env in ("surface", "underground")}
    return (
        propertycheck.ProbeStamp(vanilla_maps, calibrations, {}, []),
        propertycheck.ProbeStamp(expanded_maps, calibrations, {}, []),
    )


class PropertycheckOptimizationTests(unittest.TestCase):
    def test_property_raster_is_read_only_memmap_and_validated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "property.raw"
            np.arange(4, dtype=np.uint8).tofile(path)
            loaded = propertycheck.load_property(path, 2, 2)
            self.assertIsInstance(loaded, np.memmap)
            self.assertFalse(loaded.flags.writeable)
            self.assertEqual(loaded.tolist(), [[0, 1], [2, 3]])
            close_memmaps(loaded)
            del loaded
            np.asarray([0, 1, 2, 4], dtype=np.uint8).tofile(path)
            with self.assertRaises(SystemExit):
                propertycheck.load_property(path, 2, 2)

    def test_mapping_cache_is_exact_and_geometry_keyed(self) -> None:
        vanilla, expanded = stamps()
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            cold = propertycheck.map_sites(vanilla, expanded, "surface", cache)
            warm = propertycheck.map_sites(vanilla, expanded, "surface", cache)
            for name in propertycheck.MAPPING_ARRAY_KEYS:
                self.assertTrue(np.array_equal(cold[name], warm[name]), name)
                self.assertIsInstance(warm[name], np.memmap)
            self.assertEqual(cold["cache_key"], warm["cache_key"])
            altered = stamps()[1]
            altered.calibration["surface"][(1, 0)] = (1000.25, 0.0)
            self.assertNotEqual(
                propertycheck.mapping_cache_key(vanilla, expanded, "surface"),
                propertycheck.mapping_cache_key(vanilla, altered, "surface"),
            )
            close_memmaps(cold, warm)
            del cold, warm

    def test_normalised_mask_cache_is_chunked_exact_and_content_keyed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pre_path, post_path = root / "pre.raw", root / "post.raw"
            stamp_path, cache = root / "zones.txt", root / "cache"
            pre = np.zeros((8, 8), dtype="<u2")
            pre[2:4, 2:4] = np.asarray([[12, 13], [14, 15]], dtype="<u2")
            post = np.clip(pre.astype(np.int64) * 4 // 3, 0, propertycheck.CAP).astype("<u2")
            post[2, 2] += 1
            pre.tofile(pre_path)
            post.tofile(post_path)
            stamp_path.write_text(
                "map,surface,zmul=4,zdiv=3,zadd=0\n"
                "massif,surface,1,x0=2,y0=2,x1=4,y1=4,base=10,base_img=13,"
                "peak=15,peak_img=20,peak_x=3,peak_y=3,cells=4,band_h=5,band_t=5,"
                "k=1.0,monotone=true,escaped=false\n",
                encoding="utf-8",
            )
            cold_mask, cold_report = propertycheck.exact_normalised_nodes(
                pre_path, post_path, stamp_path, cache)
            warm_mask, warm_report = propertycheck.exact_normalised_nodes(
                pre_path, post_path, stamp_path, cache)
            self.assertEqual(int(cold_mask.sum()), 1)
            self.assertTrue(cold_report["ok"])
            self.assertEqual(cold_report, warm_report)
            self.assertTrue(np.array_equal(cold_mask, warm_mask))
            self.assertIsInstance(warm_mask, np.memmap)
            close_memmaps(warm_mask)
            del warm_mask

            post[0, 0] = 1
            post.tofile(post_path)
            changed_mask, changed_report = propertycheck.exact_normalised_nodes(
                pre_path, post_path, stamp_path, cache)
            self.assertNotEqual(cold_report["cache_key"], changed_report["cache_key"])
            self.assertEqual(int(changed_mask.sum()), 1)
            self.assertEqual(changed_report["outside_component_post_vs_affine"], 1)
            self.assertFalse(changed_report["ok"])
            close_memmaps(cold_mask, changed_mask)
            del cold_mask, changed_mask


if __name__ == "__main__":
    unittest.main()
