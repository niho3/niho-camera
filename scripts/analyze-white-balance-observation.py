#!/usr/bin/env python3
"""Validate and measure a development-only RAW white-balance observation run."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any
import uuid


SCHEMA_VERSION = 1
REPORT_SCHEMA_VERSION = 1
ADOPTION_STATUS = "exploratory-observation-only"
PRODUCTION_ADOPTION_ALLOWED = False
EXPECTED_SCENE_COUNT = 2
EXPECTED_HOLDOUT_COUNT = 0
TEMPERATURE_MIRED_OFFSETS = [-100, -60, -30, 0, 30, 60, 100]
TINT_OFFSETS = [-60, -30, -15, 0, 15, 30, 60]
CORNERS = [
    {"temperatureMiredOffset": -30, "tintOffset": -15},
    {"temperatureMiredOffset": -30, "tintOffset": 15},
    {"temperatureMiredOffset": 30, "tintOffset": -15},
    {"temperatureMiredOffset": 30, "tintOffset": 15},
]
BASE_REQUIRED_SOURCE_FILES = [
    "Package.swift",
    "Sources/PhotoCore/PhotoCoreProcessingFingerprint.swift",
    "Sources/PhotoCore/Spatial/SpatialToneOps.swift",
    "Sources/PhotoCore/CoreImageDecoder.swift",
    "Sources/PhotoCore/RAWWhiteBalanceDecoder.swift",
    "Sources/PhotoCore/EditSettings.swift",
    "Sources/PhotoCore/OKLabColor.swift",
    "Sources/PhotoCore/AdobeProfile/ColorOps.swift",
    "Sources/PhotoCore/RenderEngine.swift",
    "Sources/PhotoCore/PhotoLibrary.swift",
    "Sources/PhotoCore/SRGBOutputTransform.swift",
    "Sources/PhotoCore/ToneCurveModel.swift",
    "Sources/PhotoCore/XMPPresetParser.swift",
    "Sources/PhotoCore/AdobeBaseRenderer.swift",
    "Sources/PhotoCore/LibRawDecoder.swift",
    "Sources/PhotoCore/PhotoDecoder.swift",
    "Sources/PhotoCore/AdobeProfile/AdobeBaseCalibration.swift",
    "Sources/PhotoCore/AdobeProfile/AdobeColorMath.swift",
    "Sources/PhotoCore/AdobeProfile/AdobeLookXMP.swift",
    "Sources/PhotoCore/AdobeProfile/AdobeProfileLocator.swift",
    "Sources/PhotoCore/AdobeProfile/ColorSpec.swift",
    "Sources/PhotoCore/AdobeProfile/DCPProfile.swift",
    "Sources/PhotoCore/AdobeProfile/HueSatMap.swift",
    "Sources/PhotoCore/AdobeProfile/RGBTone.swift",
    "Sources/PhotoCore/AdobeProfile/ToneOps.swift",
    "Sources/PhotoCore/Lens/LensDistortion.swift",
    "Sources/PhotoCore/Lens/PanasonicRW2Metadata.swift",
    "Sources/PhotoCore/Spatial/SpatialToneMetalSource.swift",
    "Sources/PhotoCore/Spatial/SpatialToneProcessor.swift",
    "Sources/PhotoCore/WorkingCopyRenderer.swift",
    "Sources/PhotoBenchCalibrationSupport/BenchmarkModels.swift",
    "Sources/PhotoBenchCalibrationSupport/CalibrationManifest.swift",
    "Sources/PhotoBenchCalibrationSupport/CalibrationRun.swift",
    "Sources/PhotoBenchCalibrationSupport/CalibrationStages.swift",
    "Sources/PhotoBenchCalibrationSupport/WhiteBalanceObservation.swift",
    "Sources/PhotoBenchApp/ContentView.swift",
    "Sources/PhotoBenchApp/EditorModel.swift",
    "Sources/PhotoBenchApp/PhotoBenchApp.swift",
    "Sources/PhotoBenchApp/RenderCoordinator.swift",
    "Sources/PhotoBenchAppSupport/FolderAccess.swift",
    "Sources/PhotoBenchCalibration/main.swift",
    "Sources/PhotoBenchBenchmark/main.swift",
    "scripts/analyze-calibration.py",
]
OBSERVATION_ONLY_SOURCE_FILES = [
    "Sources/PhotoBenchWhiteBalanceObservation/main.swift",
    "scripts/analyze-white-balance-observation.py",
]
REQUIRED_SOURCE_FILES = BASE_REQUIRED_SOURCE_FILES + OBSERVATION_ONLY_SOURCE_FILES
FORBIDDEN_OBSERVATION_LANGUAGE = (
    "best",
    "winner",
    "recommend",
    "recommended",
    "mapping",
)
OPAQUE_PROVENANCE_KEY_PATHS = frozenset({
    # Metal exposes this canonical runtime field name. It records a hardware
    # memory limit and is not an observation candidate recommendation.
    "report.run.runtime.metalDevice.recommendedMaxWorkingSetSize",
})


class ObservationValidationError(RuntimeError):
    """The observation evidence is incomplete, stale, unsafe, or malformed."""


def _reject_json_constant(value: str) -> None:
    raise ObservationValidationError(f"JSONに非finite値があります: {value}")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ObservationValidationError(f"JSON keyが重複しています: {key}")
        result[key] = value
    return result


def load_json_snapshot(path: Path) -> tuple[dict[str, Any], str]:
    try:
        data = path.read_bytes()
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_json_constant,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ObservationValidationError(
            f"JSONを読み込めません: {path}: {error}"
        ) from error
    if not isinstance(value, dict):
        raise ObservationValidationError(f"JSON rootはobjectでなければなりません: {path}")
    return value, hashlib.sha256(data).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    return load_json_snapshot(path)[0]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1_048_576):
            digest.update(chunk)
    return digest.hexdigest()


def _require_lower_sha256(value: Any, field: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or value != value.lower()
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ObservationValidationError(f"{field}はlowercase SHA-256ではありません")
    return value


def _require_exact(value: Any, expected: Any, field: str) -> None:
    if value != expected:
        raise ObservationValidationError(
            f"{field}が固定契約と一致しません: expected={expected!r} actual={value!r}"
        )


def _require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ObservationValidationError(f"{field}が空です")
    return value


def _require_safe_identifier(value: Any, field: str) -> str:
    text = _require_text(value, field)
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
    if any(character not in allowed for character in text):
        raise ObservationValidationError(f"{field}に未対応文字があります: {text}")
    return text


def _require_safe_relative_path(value: Any, field: str) -> str:
    text = _require_text(value, field)
    relative = Path(text)
    if relative.is_absolute() or "\x00" in text or ".." in relative.parts:
        raise ObservationValidationError(f"{field}が安全な相対pathではありません")
    return text


def _resolve_inside(root: Path, value: Any, field: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ObservationValidationError(f"{field}が安全な相対pathではありません")
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise ObservationValidationError(f"{field}がproject root外を指しています: {value}")
    candidate = (root / relative).resolve(strict=False)
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise ObservationValidationError(
            f"{field}がsymlink経由でproject root外を指しています: {value}"
        ) from error
    return candidate


def _load_calibration_module(root: Path) -> Any:
    path = root / "scripts" / "analyze-calibration.py"
    if not path.is_file():
        raise ObservationValidationError(f"比較metric実装がありません: {path}")
    spec = importlib.util.spec_from_file_location("photobench_calibration_metrics", path)
    if spec is None or spec.loader is None:
        raise ObservationValidationError(f"比較metric実装をloadできません: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _capture_analysis_runtime(metrics_module: Any) -> dict[str, str]:
    """Capture the concrete Python/image-metric runtime used by this report."""
    try:
        import PIL
        from PIL import features
    except ImportError as error:
        raise ObservationValidationError(
            "解析runtime provenanceに必要なPillowを読み込めません"
        ) from error

    executable = Path(sys.executable).resolve(strict=True)
    if not executable.is_file():
        raise ObservationValidationError("Python executableがregular fileではありません")
    numpy_module = getattr(metrics_module, "np", None)
    opencv_module = getattr(metrics_module, "cv2", None)
    if numpy_module is None or opencv_module is None:
        raise ObservationValidationError("metric moduleのNumPy/OpenCV provenanceがありません")
    little_cms_version = features.version("littlecms2")
    versions = {
        "pythonVersion": sys.version,
        "pythonExecutable": str(executable),
        "pythonExecutableSHA256": sha256_file(executable),
        "numpyVersion": getattr(numpy_module, "__version__", None),
        "opencvVersion": getattr(opencv_module, "__version__", None),
        "pillowVersion": getattr(PIL, "__version__", None),
        "littleCMSVersion": little_cms_version,
    }
    if not all(isinstance(value, str) and value for value in versions.values()):
        raise ObservationValidationError("解析runtime provenanceに空のversionがあります")
    _require_lower_sha256(
        versions["pythonExecutableSHA256"],
        "analysisRuntime.pythonExecutableSHA256",
    )
    return versions


def _signed_label(value: int) -> str:
    return f"minus-{abs(value):03d}" if value < 0 else f"plus-{value:03d}"


def expected_candidate_ids() -> list[str]:
    result = ["as-shot", "custom-center"]
    result.extend(
        f"temperature-mired-{_signed_label(value)}"
        for value in TEMPERATURE_MIRED_OFFSETS
        if value != 0
    )
    result.extend(
        f"tint-{_signed_label(value)}"
        for value in TINT_OFFSETS
        if value != 0
    )
    result.extend(
        "corner-mired-"
        f"{_signed_label(corner['temperatureMiredOffset'])}-tint-"
        f"{_signed_label(corner['tintOffset'])}"
        for corner in CORNERS
    )
    if len(result) != 18 or len(set(result)) != 18:
        raise AssertionError("internal candidate contract is not 18 unique IDs")
    return result


def expected_candidate_contracts() -> dict[str, dict[str, Any]]:
    contracts: list[dict[str, Any]] = [
        {
            "candidate_id": "as-shot",
            "candidate_kind": "as-shot",
            "temperature_mired_offset": 0,
            "tint_offset": 0,
        },
        {
            "candidate_id": "custom-center",
            "candidate_kind": "custom-center",
            "temperature_mired_offset": 0,
            "tint_offset": 0,
        },
    ]
    contracts.extend(
        {
            "candidate_id": f"temperature-mired-{_signed_label(value)}",
            "candidate_kind": "temperature-axis",
            "temperature_mired_offset": value,
            "tint_offset": 0,
        }
        for value in TEMPERATURE_MIRED_OFFSETS
        if value != 0
    )
    contracts.extend(
        {
            "candidate_id": f"tint-{_signed_label(value)}",
            "candidate_kind": "tint-axis",
            "temperature_mired_offset": 0,
            "tint_offset": value,
        }
        for value in TINT_OFFSETS
        if value != 0
    )
    contracts.extend(
        {
            "candidate_id": (
                "corner-mired-"
                f"{_signed_label(corner['temperatureMiredOffset'])}-tint-"
                f"{_signed_label(corner['tintOffset'])}"
            ),
            "candidate_kind": "corner",
            "temperature_mired_offset": corner["temperatureMiredOffset"],
            "tint_offset": corner["tintOffset"],
        }
        for corner in CORNERS
    )
    result = {contract["candidate_id"]: contract for contract in contracts}
    _require_exact(list(result), expected_candidate_ids(), "internal candidate order")
    return result


def _require_finite_number(value: Any, field: str) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(value)
    ):
        raise ObservationValidationError(f"{field}がfinite数値ではありません")
    return float(value)


def _require_neutral_values(value: Any, field: str) -> dict[str, float]:
    if not isinstance(value, dict):
        raise ObservationValidationError(f"{field}がneutral objectではありません")
    _require_exact(
        set(value),
        {"temperatureKelvin", "tint", "chromaticityX", "chromaticityY"},
        f"{field}.keys",
    )
    temperature = _require_finite_number(
        value.get("temperatureKelvin"), f"{field}.temperatureKelvin"
    )
    tint = _require_finite_number(value.get("tint"), f"{field}.tint")
    chromaticity_x = _require_finite_number(
        value.get("chromaticityX"), f"{field}.chromaticityX"
    )
    chromaticity_y = _require_finite_number(
        value.get("chromaticityY"), f"{field}.chromaticityY"
    )
    if not 2_000 <= temperature <= 50_000:
        raise ObservationValidationError(f"{field}.temperatureKelvinが範囲外です")
    if not -150 <= tint <= 150:
        raise ObservationValidationError(f"{field}.tintが範囲外です")
    if (
        not 0 < chromaticity_x <= 1
        or not 0 < chromaticity_y <= 1
        or chromaticity_x + chromaticity_y > 1
    ):
        raise ObservationValidationError(f"{field}.chromaticityが範囲外です")
    return {
        "temperatureKelvin": temperature,
        "tint": tint,
        "chromaticityX": chromaticity_x,
        "chromaticityY": chromaticity_y,
    }


def _require_custom_request(value: Any, field: str) -> dict[str, float]:
    if not isinstance(value, dict):
        raise ObservationValidationError(f"{field}がcustom request objectではありません")
    _require_exact(set(value), {"temperatureKelvin", "tint"}, f"{field}.keys")
    temperature = _require_finite_number(
        value.get("temperatureKelvin"), f"{field}.temperatureKelvin"
    )
    tint = _require_finite_number(value.get("tint"), f"{field}.tint")
    if not 2_000 <= temperature <= 50_000:
        raise ObservationValidationError(f"{field}.temperatureKelvinが範囲外です")
    if not -150 <= tint <= 150:
        raise ObservationValidationError(f"{field}.tintが範囲外です")
    return {"temperatureKelvin": temperature, "tint": tint}


def _require_close(actual: float, expected: float, field: str) -> None:
    if not math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-9):
        raise ObservationValidationError(
            f"{field}が固定候補値と一致しません: expected={expected!r} actual={actual!r}"
        )


def expected_custom_request(
    source: dict[str, float], contract: dict[str, Any]
) -> dict[str, float]:
    target_mired = (
        1_000_000 / source["temperatureKelvin"]
        + contract["temperature_mired_offset"]
    )
    if not math.isfinite(target_mired) or target_mired <= 0:
        raise ObservationValidationError("candidate mired値が正ではありません")
    return {
        "temperatureKelvin": 1_000_000 / target_mired,
        "tint": source["tint"] + contract["tint_offset"],
    }


def _validate_metadata_audit(audit: Any, context: str) -> None:
    if not isinstance(audit, dict):
        raise ObservationValidationError(f"{context}.metadataAuditがobjectではありません")
    _require_exact(
        set(audit),
        {
            "imageIOPropertyKeys",
            "exifToolTagKeys",
            "iccProfileDescription",
            "sourceMetadataAbsent",
        },
        f"{context}.metadataAudit.keys",
    )
    _require_exact(audit.get("sourceMetadataAbsent"), True, f"{context}.sourceMetadataAbsent")
    _require_exact(
        audit.get("iccProfileDescription"),
        "sRGB IEC61966-2.1",
        f"{context}.iccProfileDescription",
    )
    image_io_keys = audit.get("imageIOPropertyKeys")
    exiftool_keys = audit.get("exifToolTagKeys")
    for keys, field in (
        (image_io_keys, "imageIOPropertyKeys"),
        (exiftool_keys, "exifToolTagKeys"),
    ):
        if (
            not isinstance(keys, list)
            or not keys
            or not all(isinstance(key, str) and key for key in keys)
            or keys != sorted(keys)
            or len(keys) != len(set(keys))
        ):
            raise ObservationValidationError(f"{context}.{field}がsorted unique文字列ではありません")

    forbidden_components = {
        "exif", "gps", "iptc", "xmp", "makernote", "makernotes", "make", "model",
        "datetime", "artist", "copyright", "imagedescription", "usercomment",
    }
    for key in image_io_keys:
        components = (
            key.lower()
            .replace("{", ".")
            .replace("}", ".")
            .split(".")
        )
        if any(
            component in forbidden_components
            or component.startswith(("serial", "lens", "camera"))
            for component in components
        ):
            raise ObservationValidationError(f"{context}にsource ImageIO metadataがあります: {key}")

    allowed_ifd0 = {
        "ImageWidth", "ImageHeight", "BitsPerSample", "Compression",
        "PhotometricInterpretation", "FillOrder", "StripOffsets", "Orientation",
        "SamplesPerPixel", "RowsPerStrip", "StripByteCounts", "PlanarConfiguration",
        "ResolutionUnit", "XResolution", "YResolution", "ExtraSamples", "SampleFormat",
    }
    allowed_exif_ifd = {"ColorSpace", "ExifImageWidth", "ExifImageHeight"}
    allowed_composite = {"ImageSize", "Megapixels"}
    for key in exiftool_keys:
        if key == "SourceFile":
            continue
        if ":" not in key:
            raise ObservationValidationError(f"{context}にgroupなしExifTool tagがあります: {key}")
        group, name = key.split(":", 1)
        allowed = (
            group in {"ExifTool", "System", "File"}
            or group.startswith("ICC")
            or (group == "IFD0" and name in allowed_ifd0)
            or (group == "ExifIFD" and name in allowed_exif_ifd)
            or (group == "Composite" and name in allowed_composite)
        )
        if not allowed:
            raise ObservationValidationError(f"{context}にsource ExifTool metadataがあります: {key}")


def validate_manifest(manifest: dict[str, Any]) -> None:
    _require_exact(
        set(manifest),
        {
            "schemaVersion",
            "suiteID",
            "description",
            "adoptionStatus",
            "baseCalibrationManifest",
            "expectedEnvironment",
            "processing",
            "output",
            "setterOrder",
            "candidatePlan",
            "scenes",
        },
        "manifest.keys",
    )
    _require_exact(manifest.get("schemaVersion"), SCHEMA_VERSION, "manifest.schemaVersion")
    _require_exact(manifest.get("adoptionStatus"), ADOPTION_STATUS, "manifest.adoptionStatus")
    _require_text(manifest.get("suiteID"), "manifest.suiteID")
    _require_text(manifest.get("description"), "manifest.description")
    base = manifest.get("baseCalibrationManifest")
    if not isinstance(base, dict):
        raise ObservationValidationError("manifest.baseCalibrationManifestがobjectではありません")
    _require_exact(
        set(base),
        {"path", "sha256", "suiteID", "schemaVersion"},
        "manifest.baseCalibrationManifest.keys",
    )
    _require_safe_relative_path(
        base.get("path"), "manifest.baseCalibrationManifest.path"
    )
    _require_lower_sha256(
        base.get("sha256"), "manifest.baseCalibrationManifest.sha256"
    )
    _require_text(base.get("suiteID"), "manifest.baseCalibrationManifest.suiteID")
    _require_exact(
        base.get("schemaVersion"), 4, "manifest.baseCalibrationManifest.schemaVersion"
    )
    environment = manifest.get("expectedEnvironment")
    expected_environment_keys = {
        "macOSVersion",
        "macOSBuild",
        "architecture",
        "hardwareModel",
        "metalDevice",
        "rawDecoderBackend",
    }
    if not isinstance(environment, dict):
        raise ObservationValidationError("manifest.expectedEnvironmentがobjectではありません")
    _require_exact(
        set(environment), expected_environment_keys, "manifest.expectedEnvironment.keys"
    )
    for key in expected_environment_keys:
        if not isinstance(environment.get(key), str) or not environment[key]:
            raise ObservationValidationError(
                f"manifest.expectedEnvironment.{key}が空です"
            )
    _require_exact(
        environment.get("rawDecoderBackend"),
        "Core Image RAW 8",
        "manifest.expectedEnvironment.rawDecoderBackend",
    )
    processing = manifest.get("processing")
    if not isinstance(processing, dict):
        raise ObservationValidationError("manifest.processingがobjectではありません")
    _require_exact(
        set(processing),
        {"legacyAsShotDecoder", "customRAWDecoder", "renderPipeline", "sourceFiles"},
        "manifest.processing.keys",
    )
    _require_exact(
        processing.get("legacyAsShotDecoder"),
        "core-image-raw8-intent-v2",
        "manifest.processing.legacyAsShotDecoder",
    )
    _require_exact(
        processing.get("customRAWDecoder"),
        "core-image-raw8-custom-neutral-temperature-tint-v1",
        "manifest.processing.customRAWDecoder",
    )
    _require_exact(
        processing.get("renderPipeline"),
        "extended-linear-srgb-edits-resize-before-final-srgb-v1",
        "manifest.processing.renderPipeline",
    )
    _require_exact(
        processing.get("sourceFiles"),
        REQUIRED_SOURCE_FILES,
        "manifest.processing.sourceFiles",
    )
    plan = manifest.get("candidatePlan")
    if not isinstance(plan, dict):
        raise ObservationValidationError("manifest.candidatePlanがobjectではありません")
    _require_exact(
        set(plan),
        {
            "temperatureMiredOffsets",
            "tintOffsets",
            "corners",
            "includesAsShot",
            "includesCustomCenter",
            "expectedCandidateCountPerScene",
        },
        "manifest.candidatePlan.keys",
    )
    _require_exact(
        plan.get("temperatureMiredOffsets"),
        TEMPERATURE_MIRED_OFFSETS,
        "manifest.candidatePlan.temperatureMiredOffsets",
    )
    _require_exact(plan.get("tintOffsets"), TINT_OFFSETS, "manifest.candidatePlan.tintOffsets")
    _require_exact(plan.get("corners"), CORNERS, "manifest.candidatePlan.corners")
    _require_exact(plan.get("includesAsShot"), True, "manifest.candidatePlan.includesAsShot")
    _require_exact(
        plan.get("includesCustomCenter"),
        True,
        "manifest.candidatePlan.includesCustomCenter",
    )
    _require_exact(
        plan.get("expectedCandidateCountPerScene"),
        18,
        "manifest.candidatePlan.expectedCandidateCountPerScene",
    )
    setter = manifest.get("setterOrder")
    if not isinstance(setter, dict):
        raise ObservationValidationError("manifest.setterOrderがobjectではありません")
    _require_exact(
        set(setter),
        {"primary", "comparison", "exactByteEqualityRequired"},
        "manifest.setterOrder.keys",
    )
    _require_exact(setter.get("primary"), "temperature-then-tint", "setterOrder.primary")
    _require_exact(
        setter.get("comparison"),
        "tint-then-temperature",
        "setterOrder.comparison",
    )
    _require_exact(
        setter.get("exactByteEqualityRequired"),
        True,
        "setterOrder.exactByteEqualityRequired",
    )
    output = manifest.get("output")
    expected_output = {
        "maxDimension": 1500,
        "outputFormat": "RGBA16 sRGB TIFF",
        "outputColorSpace": "sRGB IEC61966-2.1",
        "bitsPerChannel": 16,
        "downsamplingFilter": "CILanczosScaleTransform",
        "outputTransformPlacement": "after-downsampling",
        "sourceMetadataPolicy": (
            "pixel-only; canonical sRGB ICC only; source EXIF/XMP/IPTC/GPS removed"
        ),
    }
    _require_exact(output, expected_output, "manifest.output")
    scenes = manifest.get("scenes")
    if not isinstance(scenes, list) or len(scenes) != EXPECTED_SCENE_COUNT:
        raise ObservationValidationError("manifestはdevelopment 2 scenes専用です")
    ids: list[str] = []
    for index, scene in enumerate(scenes):
        if not isinstance(scene, dict):
            raise ObservationValidationError(f"manifest.scenes[{index}]がobjectではありません")
        _require_exact(
            set(scene),
            {
                "id",
                "sceneGroup",
                "fold",
                "raw",
                "lightroomReference",
                "teacher",
            },
            f"manifest.scenes[{index}].keys",
        )
        scene_id = _require_safe_identifier(
            scene.get("id"), f"manifest.scenes[{index}].id"
        )
        ids.append(scene_id)
        _require_text(scene.get("sceneGroup"), f"scene {scene_id}.sceneGroup")
        _require_exact(scene.get("fold"), "development", f"scene {scene_id}.fold")
        for fixture_key in ("raw", "lightroomReference"):
            fixture = scene.get(fixture_key)
            if not isinstance(fixture, dict):
                raise ObservationValidationError(f"scene {scene_id}.{fixture_key}が不正です")
            _require_exact(
                set(fixture),
                {"path", "sha256"},
                f"scene {scene_id}.{fixture_key}.keys",
            )
            _require_safe_relative_path(
                fixture.get("path"), f"scene {scene_id}.{fixture_key}.path"
            )
            _require_lower_sha256(
                fixture.get("sha256"), f"scene {scene_id}.{fixture_key}.sha256"
            )
        teacher = scene.get("teacher")
        if not isinstance(teacher, dict):
            raise ObservationValidationError(f"scene {scene_id}.teacherが不正です")
        _require_exact(
            set(teacher),
            {
                "software",
                "processVersion",
                "cameraProfile",
                "whiteBalanceMode",
                "temperatureKelvin",
                "tint",
            },
            f"scene {scene_id}.teacher.keys",
        )
        _require_exact(
            teacher.get("software"),
            "Adobe Lightroom 9.3 (Macintosh)",
            f"scene {scene_id}.teacher.software",
        )
        _require_exact(
            teacher.get("processVersion"),
            "15.4",
            f"scene {scene_id}.teacher.processVersion",
        )
        _require_exact(
            teacher.get("cameraProfile"),
            "Adobe Standard",
            f"scene {scene_id}.teacher.cameraProfile",
        )
        _require_exact(
            teacher.get("whiteBalanceMode"),
            "As Shot",
            f"scene {scene_id}.teacher.whiteBalanceMode",
        )
        temperature = teacher.get("temperatureKelvin")
        tint = teacher.get("tint")
        if (
            not isinstance(temperature, int)
            or isinstance(temperature, bool)
            or not 2_000 <= temperature <= 50_000
        ):
            raise ObservationValidationError(
                f"scene {scene_id}.teacher.temperatureKelvinが範囲外です"
            )
        if (
            not isinstance(tint, int)
            or isinstance(tint, bool)
            or not -150 <= tint <= 150
        ):
            raise ObservationValidationError(
                f"scene {scene_id}.teacher.tintが範囲外です"
            )
    if len(set(ids)) != len(ids):
        raise ObservationValidationError("manifest scene IDが重複しています")


def _validate_manifest_and_base_hashes(
    root: Path,
    manifest_path: Path,
    manifest: dict[str, Any],
    run: dict[str, Any],
) -> dict[str, Any]:
    manifest_reference = run.get("manifest")
    if not isinstance(manifest_reference, dict):
        raise ObservationValidationError("run.manifestがありません")
    _require_exact(
        set(manifest_reference),
        {"path", "sha256", "suiteID"},
        "run.manifest.keys",
    )
    actual_manifest_hash = sha256_file(manifest_path)
    manifest_relative = manifest_path.relative_to(root).as_posix()
    _require_exact(
        manifest_reference.get("path"), manifest_relative, "run.manifest.path"
    )
    _require_exact(
        manifest_reference.get("sha256"), actual_manifest_hash, "run.manifest.sha256"
    )
    _require_exact(
        manifest_reference.get("suiteID"), manifest.get("suiteID"), "run.manifest.suiteID"
    )
    base = manifest.get("baseCalibrationManifest")
    run_base = run.get("baseCalibrationManifest")
    if not isinstance(base, dict) or not isinstance(run_base, dict):
        raise ObservationValidationError("base calibration参照がありません")
    _require_exact(
        set(run_base),
        {"path", "sha256", "suiteID"},
        "run.baseCalibrationManifest.keys",
    )
    base_path = _resolve_inside(root, base.get("path"), "baseCalibrationManifest.path")
    if not base_path.is_file():
        raise ObservationValidationError(f"base calibration manifestがありません: {base_path}")
    base_hash = sha256_file(base_path)
    _require_exact(run_base.get("path"), base.get("path"), "run.baseCalibrationManifest.path")
    _require_exact(base.get("sha256"), base_hash, "manifest.baseCalibrationManifest.sha256")
    _require_exact(run_base.get("sha256"), base_hash, "run.baseCalibrationManifest.sha256")
    _require_exact(run_base.get("suiteID"), base.get("suiteID"), "run.baseCalibrationManifest.suiteID")
    base_manifest = load_json(base_path)
    _require_exact(
        base_manifest.get("schemaVersion"),
        base.get("schemaVersion"),
        "baseCalibrationManifest.schemaVersion",
    )
    _require_exact(
        base_manifest.get("suiteID"),
        base.get("suiteID"),
        "baseCalibrationManifest.suiteID",
    )
    _require_exact(
        base_manifest.get("expectedEnvironment"),
        manifest.get("expectedEnvironment"),
        "baseCalibrationManifest.expectedEnvironment",
    )
    _validate_manifest_against_base(manifest, base_manifest)
    raw_profile = base_manifest.get("rawProfile")
    if not isinstance(raw_profile, dict):
        raise ObservationValidationError("base calibration rawProfileがありません")
    if not isinstance(raw_profile.get("id"), str) or not raw_profile["id"]:
        raise ObservationValidationError("base calibration rawProfile.idが不正です")
    _require_finite_number(raw_profile.get("boostAmount"), "rawProfile.boostAmount")
    _require_finite_number(
        raw_profile.get("extendedDynamicRangeAmount"),
        "rawProfile.extendedDynamicRangeAmount",
    )
    return base_manifest


def _validate_manifest_against_base(
    manifest: dict[str, Any],
    base_manifest: dict[str, Any],
) -> None:
    """Require the observation contract to be a literal extension of calibration v4."""
    base_processing = base_manifest.get("processing")
    if not isinstance(base_processing, dict):
        raise ObservationValidationError("base calibration processingがありません")
    base_source_files = base_processing.get("sourceFiles")
    _require_exact(
        base_source_files,
        BASE_REQUIRED_SOURCE_FILES,
        "baseCalibrationManifest.processing.sourceFiles",
    )
    observation_processing = manifest.get("processing")
    if not isinstance(observation_processing, dict):
        raise ObservationValidationError("manifest.processingがありません")
    _require_exact(
        observation_processing.get("sourceFiles"),
        base_source_files + OBSERVATION_ONLY_SOURCE_FILES,
        "manifest.processing.sourceFiles.baseExtension",
    )

    observation_scenes = manifest.get("scenes")
    base_scenes = base_manifest.get("scenes")
    if not isinstance(observation_scenes, list) or not isinstance(base_scenes, list):
        raise ObservationValidationError("observation/base scenesがありません")
    observation_ids = [
        scene.get("id") if isinstance(scene, dict) else None
        for scene in observation_scenes
    ]
    base_ids = [
        scene.get("id") if isinstance(scene, dict) else None
        for scene in base_scenes
    ]
    if len(base_ids) != len(set(base_ids)):
        raise ObservationValidationError("base calibration scene IDが重複しています")
    _require_exact(observation_ids, base_ids, "manifest.scenes.baseOrder")

    for index, (scene, base_scene) in enumerate(
        zip(observation_scenes, base_scenes, strict=True)
    ):
        if not isinstance(scene, dict) or not isinstance(base_scene, dict):
            raise ObservationValidationError(
                f"observation/base scenes[{index}]がobjectではありません"
            )
        scene_id = scene["id"]
        _require_exact(
            scene.get("sceneGroup"),
            base_scene.get("sceneGroup"),
            f"scene {scene_id}.sceneGroup.baseLink",
        )
        _require_exact(
            scene.get("fold"),
            base_scene.get("fold"),
            f"scene {scene_id}.fold.baseLink",
        )
        _require_exact(
            scene.get("raw"),
            base_scene.get("raw"),
            f"scene {scene_id}.raw.baseLink",
        )
        _require_exact(
            scene.get("lightroomReference"),
            base_scene.get("lightroomBefore"),
            f"scene {scene_id}.lightroomReference.baseLink",
        )
        capture = base_scene.get("capture")
        teacher = scene.get("teacher")
        if not isinstance(capture, dict) or not isinstance(teacher, dict):
            raise ObservationValidationError(
                f"scene {scene_id}のbase captureまたはteacherがありません"
            )
        _require_exact(
            teacher.get("temperatureKelvin"),
            capture.get("lightroomColorTemperature"),
            f"scene {scene_id}.teacher.temperatureKelvin.baseLink",
        )


def _require_positive_int(value: Any, field: str, *, allow_zero: bool = False) -> int:
    minimum = 0 if allow_zero else 1
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        qualifier = "nonnegative" if allow_zero else "positive"
        raise ObservationValidationError(f"{field}が{qualifier} integerではありません")
    return value


def _validate_runtime_and_tools(
    root: Path,
    manifest: dict[str, Any],
    run: dict[str, Any],
) -> dict[str, Any]:
    runtime = run.get("runtime")
    if not isinstance(runtime, dict):
        raise ObservationValidationError("run.runtimeがobjectではありません")
    _require_exact(
        set(runtime),
        {
            "macOSVersion",
            "macOSBuild",
            "architecture",
            "hardwareModel",
            "processorCount",
            "physicalMemoryBytes",
            "thermalState",
            "lowPowerModeEnabled",
            "buildConfiguration",
            "coreImageFrameworkVersion",
            "executableSHA256",
            "metalDevice",
        },
        "run.runtime.keys",
    )
    expected = manifest["expectedEnvironment"]
    for key in ("macOSVersion", "macOSBuild", "architecture", "hardwareModel"):
        _require_exact(runtime.get(key), expected[key], f"run.runtime.{key}")
    _require_exact(
        runtime.get("buildConfiguration"), "release", "run.runtime.buildConfiguration"
    )
    _require_exact(runtime.get("thermalState"), "nominal", "run.runtime.thermalState")
    _require_exact(
        runtime.get("lowPowerModeEnabled"), False, "run.runtime.lowPowerModeEnabled"
    )
    _require_positive_int(runtime.get("processorCount"), "run.runtime.processorCount")
    _require_positive_int(
        runtime.get("physicalMemoryBytes"), "run.runtime.physicalMemoryBytes"
    )
    framework_version = runtime.get("coreImageFrameworkVersion")
    if not isinstance(framework_version, str) or not framework_version:
        raise ObservationValidationError(
            "run.runtime.coreImageFrameworkVersionが空です"
        )
    executable_hash = _require_lower_sha256(
        runtime.get("executableSHA256"), "run.runtime.executableSHA256"
    )
    release_binary = _resolve_inside(
        root,
        ".build/release/PhotoBenchWhiteBalanceObservation",
        "release observation executable",
    )
    if not release_binary.is_file():
        raise ObservationValidationError(
            "release observation executableを再検証できません。"
            "先に `swift build -c release --product "
            "PhotoBenchWhiteBalanceObservation` を実行してください"
        )
    _require_exact(
        sha256_file(release_binary),
        executable_hash,
        "run.runtime.currentExecutableSHA256",
    )

    metal = runtime.get("metalDevice")
    if not isinstance(metal, dict):
        raise ObservationValidationError("run.runtime.metalDeviceがobjectではありません")
    _require_exact(
        set(metal),
        {
            "name",
            "registryID",
            "hasUnifiedMemory",
            "currentAllocatedSize",
            "recommendedMaxWorkingSetSize",
        },
        "run.runtime.metalDevice.keys",
    )
    _require_exact(metal.get("name"), expected["metalDevice"], "run.runtime.metalDevice.name")
    _require_positive_int(metal.get("registryID"), "run.runtime.metalDevice.registryID")
    if not isinstance(metal.get("hasUnifiedMemory"), bool):
        raise ObservationValidationError(
            "run.runtime.metalDevice.hasUnifiedMemoryがboolではありません"
        )
    _require_positive_int(
        metal.get("currentAllocatedSize"),
        "run.runtime.metalDevice.currentAllocatedSize",
        allow_zero=True,
    )
    _require_positive_int(
        metal.get("recommendedMaxWorkingSetSize"),
        "run.runtime.metalDevice.recommendedMaxWorkingSetSize",
    )

    exiftool = run.get("exifTool")
    if not isinstance(exiftool, dict):
        raise ObservationValidationError("run.exifToolがobjectではありません")
    _require_exact(
        set(exiftool), {"path", "version", "sha256"}, "run.exifTool.keys"
    )
    executable_value = exiftool.get("path")
    version = exiftool.get("version")
    recorded_hash = _require_lower_sha256(
        exiftool.get("sha256"), "run.exifTool.sha256"
    )
    if not isinstance(executable_value, str) or not executable_value:
        raise ObservationValidationError("run.exifTool.pathが空です")
    if (
        not isinstance(version, str)
        or not version
        or any(part == "" or not part.isdigit() for part in version.split("."))
    ):
        raise ObservationValidationError("run.exifTool.versionが不正です")
    exiftool_path = Path(executable_value)
    if not exiftool_path.is_absolute() or "\x00" in executable_value:
        raise ObservationValidationError("run.exifTool.pathがabsolute pathではありません")
    try:
        canonical_exiftool = exiftool_path.resolve(strict=True)
    except OSError as error:
        raise ObservationValidationError(
            f"recorded ExifToolを再検証できません: {error}"
        ) from error
    if canonical_exiftool != exiftool_path or not canonical_exiftool.is_file():
        raise ObservationValidationError("run.exifTool.pathがcanonical regular fileではありません")
    if not os.access(canonical_exiftool, os.X_OK):
        raise ObservationValidationError("recorded ExifToolが実行可能ではありません")
    _require_exact(
        sha256_file(canonical_exiftool),
        recorded_hash,
        "run.exifTool.currentSHA256.preflight",
    )
    try:
        completed = subprocess.run(
            [str(canonical_exiftool), "-ver"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ObservationValidationError(
            f"recorded ExifTool versionを再検証できません: {error}"
        ) from error
    _require_exact(completed.stdout.strip(), version, "run.exifTool.currentVersion")
    _require_exact(
        sha256_file(canonical_exiftool),
        recorded_hash,
        "run.exifTool.currentSHA256.postflight",
    )
    return runtime


def _validate_private_inputs_untracked(
    root: Path,
    manifest: dict[str, Any],
) -> None:
    private_paths = [
        fixture["path"]
        for scene in manifest["scenes"]
        for fixture in (scene["raw"], scene["lightroomReference"])
    ]
    try:
        top_level = subprocess.run(
            ["/usr/bin/git", "-C", str(root), "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        tracked = subprocess.run(
            ["/usr/bin/git", "-C", str(root), "ls-files", "--", *private_paths],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ObservationValidationError(
            f"private fixtureのGit追跡状態を検証できません: {error}"
        ) from error
    try:
        git_root = Path(top_level.stdout.strip()).resolve(strict=True)
    except OSError as error:
        raise ObservationValidationError(
            f"Git top-levelを解決できません: {error}"
        ) from error
    _require_exact(git_root, root, "private fixture git top-level")
    if tracked.stdout.strip():
        raise ObservationValidationError(
            "WB observationのprivate RAW/Lightroom fixtureがGit追跡されています"
        )


def _validate_source_files(
    root: Path,
    manifest: dict[str, Any],
    run: dict[str, Any],
) -> None:
    processing = manifest.get("processing")
    if not isinstance(processing, dict) or not isinstance(processing.get("sourceFiles"), list):
        raise ObservationValidationError("manifest.processing.sourceFilesがありません")
    expected_paths = sorted(processing["sourceFiles"])
    records = run.get("sourceFiles")
    if not isinstance(records, list) or len(records) != len(expected_paths):
        raise ObservationValidationError("run.sourceFiles件数が不正です")
    by_path: dict[str, dict[str, Any]] = {}
    for record in records:
        _validate_verified_file_record(record, "run.sourceFiles record")
        path = record["path"]
        if path in by_path:
            raise ObservationValidationError(f"source fileが重複しています: {path}")
        by_path[path] = record
    _require_exact(sorted(by_path), expected_paths, "run.sourceFiles paths")
    canonical: list[str] = []
    for relative in expected_paths:
        path = _resolve_inside(root, relative, f"sourceFiles[{relative}]")
        if not path.is_file():
            raise ObservationValidationError(f"source fileがありません: {relative}")
        actual = sha256_file(path)
        _require_exact(by_path[relative].get("sha256"), actual, f"source {relative}.sha256")
        _require_exact(by_path[relative].get("byteCount"), path.stat().st_size, f"source {relative}.byteCount")
        canonical.append(f"{relative}\0{actual}")
    fingerprint = hashlib.sha256("\n".join(canonical).encode("utf-8")).hexdigest()
    _require_exact(run.get("sourceFingerprintSHA256"), fingerprint, "sourceFingerprintSHA256")
    _require_exact(
        run.get("postflightSourceFingerprintSHA256"),
        fingerprint,
        "postflightSourceFingerprintSHA256",
    )


def _validate_inputs(root: Path, manifest: dict[str, Any], run: dict[str, Any]) -> None:
    expected: dict[str, tuple[str, str]] = {}
    for scene in manifest["scenes"]:
        for key, role_suffix in (
            ("raw", "raw"),
            ("lightroomReference", "lightroomReference"),
        ):
            fixture = scene[key]
            expected[f"{scene['id']}.{role_suffix}"] = (
                fixture["path"],
                fixture["sha256"],
            )
    before = run.get("verifiedInputs")
    after = run.get("postflightVerifiedInputs")
    if not isinstance(before, list) or not isinstance(after, list) or before != after:
        raise ObservationValidationError("input preflight/postflightが完全一致しません")
    if len(before) != len(expected):
        raise ObservationValidationError("verifiedInputs件数が不正です")
    records: dict[str, dict[str, Any]] = {}
    for index, record in enumerate(before):
        _validate_verified_file_record(record, f"verifiedInputs[{index}]")
        role = record["role"]
        if role in records:
            raise ObservationValidationError(f"verifiedInputs roleが重複しています: {role}")
        records[role] = record
    _require_exact(set(records), set(expected), "verifiedInputs roles")
    for role, (relative, expected_hash) in expected.items():
        path = _resolve_inside(root, relative, f"input {role}.path")
        if not path.is_file():
            raise ObservationValidationError(f"inputがありません: {relative}")
        _require_exact(records[role].get("path"), relative, f"input {role}.path")
        _require_exact(records[role].get("sha256"), expected_hash, f"input {role}.sha256")
        _require_exact(sha256_file(path), expected_hash, f"current input {role}.sha256")
        _require_exact(records[role].get("byteCount"), path.stat().st_size, f"input {role}.byteCount")


def _validate_verified_file_record(value: Any, field: str) -> None:
    if not isinstance(value, dict):
        raise ObservationValidationError(f"{field}がobjectではありません")
    _require_exact(
        set(value), {"role", "path", "sha256", "byteCount"}, f"{field}.keys"
    )
    _require_text(value.get("role"), f"{field}.role")
    _require_safe_relative_path(value.get("path"), f"{field}.path")
    _require_lower_sha256(value.get("sha256"), f"{field}.sha256")
    _require_positive_int(value.get("byteCount"), f"{field}.byteCount")


def _validate_run_header(root: Path, run_path: Path, run: dict[str, Any]) -> Path:
    _require_exact(
        set(run),
        {
            "schemaVersion",
            "status",
            "adoptionStatus",
            "productionAdoptionAllowed",
            "runID",
            "startedAtUTC",
            "completedAtUTC",
            "manifest",
            "baseCalibrationManifest",
            "runtime",
            "exifTool",
            "sourceFingerprintSHA256",
            "postflightSourceFingerprintSHA256",
            "sourceFiles",
            "verifiedInputs",
            "postflightVerifiedInputs",
            "sceneCount",
            "holdoutCount",
            "scenes",
            "artifacts",
            "setterOrderChecks",
        },
        "run.keys",
    )
    _require_exact(run.get("schemaVersion"), SCHEMA_VERSION, "run.schemaVersion")
    _require_exact(run.get("status"), "complete", "run.status")
    _require_exact(run.get("adoptionStatus"), ADOPTION_STATUS, "run.adoptionStatus")
    _require_exact(
        run.get("productionAdoptionAllowed"),
        PRODUCTION_ADOPTION_ALLOWED,
        "run.productionAdoptionAllowed",
    )
    _require_exact(run.get("sceneCount"), EXPECTED_SCENE_COUNT, "run.sceneCount")
    _require_exact(run.get("holdoutCount"), EXPECTED_HOLDOUT_COUNT, "run.holdoutCount")
    run_id = run.get("runID")
    try:
        parsed_run_id = uuid.UUID(run_id) if isinstance(run_id, str) else None
    except (ValueError, AttributeError) as error:
        raise ObservationValidationError("run IDがcanonical UUIDではありません") from error
    if (
        parsed_run_id is None
        or parsed_run_id.version != 4
        or str(parsed_run_id) != run_id
        or run_path.name != "run.json"
        or run_path.parent.name != run_id
    ):
        raise ObservationValidationError("run IDとdirectory名が一致しません")
    expected_output_root = (
        root / ".photobench" / "white-balance-observations"
    ).resolve(strict=True)
    if run_path.parent.parent != expected_output_root:
        raise ObservationValidationError("run directoryがWB output rootのdirect childではありません")
    if not run_path.is_file() or run_path.is_symlink():
        raise ObservationValidationError("canonical run.jsonが通常fileではありません")
    started = _require_utc_timestamp(run.get("startedAtUTC"), "run.startedAtUTC")
    completed = _require_utc_timestamp(run.get("completedAtUTC"), "run.completedAtUTC")
    if started > completed:
        raise ObservationValidationError("run timestampsの順序が逆です")
    sentinel = run_path.parent / ".incomplete.json"
    if sentinel.exists() or sentinel.is_symlink():
        raise ObservationValidationError("incomplete sentinelが残っています")
    return run_path.parent


def _require_utc_timestamp(value: Any, field: str) -> datetime:
    if not isinstance(value, str):
        raise ObservationValidationError(f"{field}がUTC timestampではありません")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise ObservationValidationError(
            f"{field}がcanonical UTC timestampではありません"
        ) from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise ObservationValidationError(f"{field}がcanonical UTC timestampではありません")
    return parsed


def _validate_decode_configuration(
    value: Any,
    base_manifest: dict[str, Any],
    context: str,
) -> None:
    if not isinstance(value, dict):
        raise ObservationValidationError(f"{context}.decodeConfigurationがありません")
    _require_exact(
        set(value),
        {
            "exposure",
            "shadowBias",
            "boostAmount",
            "boostShadowAmount",
            "extendedDynamicRangeAmount",
            "scaleFactor",
            "draftModeEnabled",
            "gamutMappingEnabled",
        },
        f"{context}.decodeConfiguration.keys",
    )
    raw_profile = base_manifest["rawProfile"]
    expected_numbers = {
        "exposure": 0.0,
        "shadowBias": 0.0,
        "boostAmount": float(raw_profile["boostAmount"]),
        "boostShadowAmount": 1.0,
        "extendedDynamicRangeAmount": float(
            raw_profile["extendedDynamicRangeAmount"]
        ),
        "scaleFactor": 1.0,
    }
    for key, expected in expected_numbers.items():
        actual = _require_finite_number(value.get(key), f"{context}.{key}")
        if not math.isclose(actual, expected, rel_tol=1e-6, abs_tol=1e-6):
            raise ObservationValidationError(
                f"{context}.decodeConfiguration.{key}がbase RAW profileと一致しません"
            )
    _require_exact(
        value.get("draftModeEnabled"),
        False,
        f"{context}.decodeConfiguration.draftModeEnabled",
    )
    _require_exact(
        value.get("gamutMappingEnabled"),
        True,
        f"{context}.decodeConfiguration.gamutMappingEnabled",
    )


def _validate_decode_provenance_common(
    provenance: dict[str, Any],
    artifact: dict[str, Any],
    manifest: dict[str, Any],
    base_manifest: dict[str, Any],
    base_capture: dict[str, Any],
    runtime: dict[str, Any],
    context: str,
) -> tuple[Any, ...]:
    common_keys = {
        "processingIdentifier",
        "requestMode",
        "neutralPropertiesObserved",
        "neutralLocationPolicy",
        "decoderVersion",
        "supportedDecoderVersions",
        "appRAWCalibrationProfileID",
        "intent",
        "nativeWidth",
        "nativeHeight",
        "outputWidth",
        "outputHeight",
        "cameraMake",
        "cameraModel",
        "macOSVersion",
        "macOSBuild",
        "architecture",
        "hardwareModel",
        "metalDevice",
        "coreImageFrameworkVersion",
        "supportedCameraModelsSHA256",
        "appleCameraProfileObservability",
        "colorSpacePolicy",
    }
    request_mode = provenance.get("requestMode")
    expected_keys = (
        common_keys
        if request_mode == "as-shot-untouched"
        else common_keys
        | {"requested", "sourceAsShot", "applied", "setterOrder", "decodeConfiguration"}
    )
    _require_exact(set(provenance), expected_keys, f"{context}.provenance.keys")
    _require_exact(provenance.get("intent"), "full-resolution", f"{context}.intent")
    _require_exact(provenance.get("decoderVersion"), "8", f"{context}.decoderVersion")
    _require_exact(
        provenance.get("neutralLocationPolicy"),
        "unused",
        f"{context}.neutralLocationPolicy",
    )
    _require_exact(
        provenance.get("appRAWCalibrationProfileID"),
        base_manifest["rawProfile"]["id"],
        f"{context}.appRAWCalibrationProfileID",
    )
    _require_exact(
        provenance.get("appleCameraProfileObservability"),
        "unavailable-in-public-api",
        f"{context}.appleCameraProfileObservability",
    )
    _require_exact(
        provenance.get("colorSpacePolicy"),
        (
            "CIRAWFilter gamut mapping enabled; downstream extended-linear-sRGB edits; "
            "terminal sRGB output"
        ),
        f"{context}.colorSpacePolicy",
    )
    for key in ("macOSVersion", "macOSBuild", "architecture", "hardwareModel"):
        _require_exact(
            provenance.get(key), runtime[key], f"{context}.environment.{key}"
        )
    _require_exact(
        provenance.get("metalDevice"),
        runtime["metalDevice"]["name"],
        f"{context}.environment.metalDevice",
    )
    _require_exact(
        provenance.get("coreImageFrameworkVersion"),
        runtime["coreImageFrameworkVersion"],
        f"{context}.environment.coreImageFrameworkVersion",
    )
    _require_lower_sha256(
        provenance.get("supportedCameraModelsSHA256"),
        f"{context}.supportedCameraModelsSHA256",
    )
    camera_make = provenance.get("cameraMake")
    camera_model = provenance.get("cameraModel")
    for value, field in ((camera_make, "cameraMake"), (camera_model, "cameraModel")):
        if not isinstance(value, str) or not value or any(ord(character) < 32 for character in value):
            raise ObservationValidationError(f"{context}.{field}が不正です")
    _require_exact(camera_make, base_capture.get("cameraMake"), f"{context}.cameraMake")
    _require_exact(camera_model, base_capture.get("cameraModel"), f"{context}.cameraModel")
    dimensions = []
    for key in ("nativeWidth", "nativeHeight", "outputWidth", "outputHeight"):
        dimensions.append(_require_positive_int(provenance.get(key), f"{context}.{key}"))
    native_width, native_height, output_width, output_height = dimensions
    _require_exact(native_width, base_capture.get("width"), f"{context}.nativeWidth")
    _require_exact(native_height, base_capture.get("height"), f"{context}.nativeHeight")
    _require_exact(output_width, native_width, f"{context}.outputWidth")
    _require_exact(output_height, native_height, f"{context}.outputHeight")
    artifact_width = artifact["width"]
    artifact_height = artifact["height"]
    scale = 1_500 / max(native_width, native_height)
    if (
        abs(artifact_width - round(native_width * scale)) > 1
        or abs(artifact_height - round(native_height * scale)) > 1
    ):
        raise ObservationValidationError(
            f"{context}.artifactDimensionsがfull-resolution decode比と一致しません"
        )
    return (
        native_width,
        native_height,
        camera_make,
        camera_model,
        provenance.get("appRAWCalibrationProfileID"),
        provenance.get("supportedCameraModelsSHA256"),
    )


def _validate_artifacts(
    root: Path,
    run_directory: Path,
    manifest: dict[str, Any],
    base_manifest: dict[str, Any],
    runtime: dict[str, Any],
    run: dict[str, Any],
) -> tuple[
    dict[str, dict[str, Any]],
    dict[str, dict[str, Any]],
    dict[str, dict[str, Any]],
]:
    artifacts = run.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != EXPECTED_SCENE_COUNT * 20:
        raise ObservationValidationError("artifactはsceneごとに20件必要です")
    scene_ids = [scene["id"] for scene in manifest["scenes"]]
    scene_records = run.get("scenes")
    if not isinstance(scene_records, list) or len(scene_records) != EXPECTED_SCENE_COUNT:
        raise ObservationValidationError("run.scenesが2件ではありません")
    _require_exact(
        [record.get("sceneID") if isinstance(record, dict) else None for record in scene_records],
        scene_ids,
        "run.scenes order",
    )
    candidate_ids = expected_candidate_ids()
    run_scenes: dict[str, dict[str, Any]] = {}
    manifest_scenes = {scene["id"]: scene for scene in manifest["scenes"]}
    base_scenes = {scene["id"]: scene for scene in base_manifest["scenes"]}
    for record in scene_records:
        if not isinstance(record, dict):
            raise ObservationValidationError("run scene recordが不正です")
        _require_exact(
            set(record),
            {"sceneID", "fold", "sourceNeutral", "teacher", "candidateIDs"},
            "run scene record keys",
        )
        scene_id = record["sceneID"]
        _require_exact(record.get("fold"), "development", f"run scene {scene_id}.fold")
        _require_exact(
            record.get("candidateIDs"), candidate_ids, f"run scene {scene_id}.candidateIDs"
        )
        _require_exact(
            record.get("teacher"),
            manifest_scenes[scene_id].get("teacher"),
            f"run scene {scene_id}.teacher",
        )
        source = _require_neutral_values(
            record.get("sourceNeutral"), f"run scene {scene_id}.sourceNeutral"
        )
        run_scenes[scene_id] = {**record, "sourceNeutral": source}

    try:
        run_relative = run_directory.relative_to(root).as_posix()
    except ValueError as error:
        raise ObservationValidationError("run directoryがproject root外です") from error
    paths: set[str] = set()
    casefold_paths: set[str] = set()
    references: dict[str, dict[str, Any]] = {}
    candidates: dict[str, dict[str, Any]] = {}
    setter_artifacts: dict[str, dict[str, Any]] = {}
    scene_decode_contracts: dict[str, tuple[Any, ...]] = {}
    supported_camera_hashes: set[str] = set()
    contracts = expected_candidate_contracts()
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise ObservationValidationError("artifact recordがobjectではありません")
        role = artifact.get("role")
        reference_keys = {
            "role", "sceneID", "requestMode", "path", "sha256", "byteCount",
            "width", "height", "renderAndEncodeMilliseconds", "metadataAudit",
        }
        candidate_keys = reference_keys | {
            "candidateID", "candidateKind", "temperatureMiredOffset", "tintOffset",
            "decodeProvenance",
        }
        if role == "normalized-lightroom-reference":
            expected_artifact_keys = reference_keys
        elif role == "observation-candidate":
            expected_artifact_keys = (
                candidate_keys
                if artifact.get("candidateID") == "as-shot"
                else candidate_keys | {"requested"}
            )
        elif role == "setter-order-comparison":
            expected_artifact_keys = candidate_keys | {"requested"}
        else:
            raise ObservationValidationError(f"未知のartifact roleです: {role}")
        _require_exact(
            set(artifact), expected_artifact_keys, f"artifact {role}.keys"
        )
        relative = artifact.get("path")
        path = _resolve_inside(root, relative, "artifact.path")
        try:
            path.relative_to(run_directory)
        except ValueError as error:
            raise ObservationValidationError(
                f"artifactが対象run directory外です: {relative}"
            ) from error
        if relative in paths or str(relative).casefold() in casefold_paths:
            raise ObservationValidationError(f"artifact pathが重複しています: {relative}")
        paths.add(relative)
        casefold_paths.add(str(relative).casefold())
        if not path.is_file() or path.is_symlink():
            raise ObservationValidationError(f"artifactがregular fileではありません: {relative}")
        _require_exact(artifact.get("sha256"), sha256_file(path), f"artifact {relative}.sha256")
        _require_exact(artifact.get("byteCount"), path.stat().st_size, f"artifact {relative}.byteCount")
        width, height = artifact.get("width"), artifact.get("height")
        if not isinstance(width, int) or not isinstance(height, int) or max(width, height) != 1500:
            raise ObservationValidationError(f"artifact寸法が不正です: {relative}")
        render_ms = _require_finite_number(
            artifact.get("renderAndEncodeMilliseconds"),
            f"artifact {relative}.renderAndEncodeMilliseconds",
        )
        if render_ms < 0:
            raise ObservationValidationError(f"artifact render時間が負です: {relative}")
        _validate_metadata_audit(artifact.get("metadataAudit"), f"artifact {relative}")
        scene_id = artifact.get("sceneID")
        if scene_id not in scene_ids:
            raise ObservationValidationError(f"未知のartifact sceneです: {scene_id}")
        if role == "normalized-lightroom-reference":
            if scene_id in references or artifact.get("candidateID") is not None:
                raise ObservationValidationError(f"reference artifactが重複/不正です: {scene_id}")
            expected_path = f"{run_relative}/scenes/{scene_id}/reference/lightroom-as-shot.tif"
            _require_exact(relative, expected_path, f"reference {scene_id}.path")
            _require_exact(artifact.get("candidateKind"), None, f"reference {scene_id}.candidateKind")
            _require_exact(artifact.get("temperatureMiredOffset"), None, f"reference {scene_id}.temperatureMiredOffset")
            _require_exact(artifact.get("tintOffset"), None, f"reference {scene_id}.tintOffset")
            _require_exact(artifact.get("requested"), None, f"reference {scene_id}.requested")
            _require_exact(artifact.get("decodeProvenance"), None, f"reference {scene_id}.decodeProvenance")
            _require_exact(artifact.get("requestMode"), "lightroom-teacher-as-shot", f"reference {scene_id}.requestMode")
            references[scene_id] = artifact
        elif role == "observation-candidate":
            candidate_id = artifact.get("candidateID")
            key = f"{scene_id}/{candidate_id}"
            if candidate_id not in candidate_ids or key in candidates:
                raise ObservationValidationError(f"candidate artifactが重複/不正です: {key}")
            contract = contracts[candidate_id]
            expected_path = f"{run_relative}/scenes/{scene_id}/candidates/{candidate_id}.tif"
            _require_exact(relative, expected_path, f"{key}.path")
            _require_exact(artifact.get("candidateKind"), contract["candidate_kind"], f"{key}.candidateKind")
            _require_exact(
                artifact.get("temperatureMiredOffset"),
                contract["temperature_mired_offset"],
                f"{key}.temperatureMiredOffset",
            )
            _require_exact(
                artifact.get("tintOffset"), contract["tint_offset"], f"{key}.tintOffset"
            )
            candidates[key] = artifact
            provenance = artifact.get("decodeProvenance")
            if not isinstance(provenance, dict):
                raise ObservationValidationError(f"decode provenanceがありません: {key}")
            decode_contract = _validate_decode_provenance_common(
                provenance,
                artifact,
                manifest,
                base_manifest,
                base_scenes[scene_id]["capture"],
                runtime,
                key,
            )
            supported_camera_hashes.add(decode_contract[-1])
            if scene_id in scene_decode_contracts:
                _require_exact(
                    decode_contract,
                    scene_decode_contracts[scene_id],
                    f"{key}.sceneDecodeContract",
                )
            else:
                scene_decode_contracts[scene_id] = decode_contract
            if candidate_id == "as-shot":
                _require_exact(artifact.get("requestMode"), "as-shot-untouched", f"{key}.artifactRequestMode")
                _require_exact(artifact.get("requested"), None, f"{key}.artifactRequested")
                _require_exact(provenance.get("processingIdentifier"), manifest["processing"]["legacyAsShotDecoder"], f"{key}.processingIdentifier")
                _require_exact(provenance.get("requestMode"), "as-shot-untouched", f"{key}.requestMode")
                _require_exact(provenance.get("neutralPropertiesObserved"), False, f"{key}.neutralPropertiesObserved")
                for field in ("requested", "sourceAsShot", "applied", "setterOrder"):
                    _require_exact(provenance.get(field), None, f"{key}.{field}")
                _require_exact(provenance.get("decoderVersion"), "8", f"{key}.decoderVersion")
                _require_exact(provenance.get("supportedDecoderVersions"), [], f"{key}.supportedDecoderVersions")
                _require_exact(provenance.get("decodeConfiguration"), None, f"{key}.decodeConfiguration")
            else:
                source = run_scenes[scene_id]["sourceNeutral"]
                expected_request = expected_custom_request(source, contract)
                request = _require_custom_request(artifact.get("requested"), f"{key}.requested")
                _require_close(
                    request["temperatureKelvin"],
                    expected_request["temperatureKelvin"],
                    f"{key}.requested.temperatureKelvin",
                )
                _require_close(request["tint"], expected_request["tint"], f"{key}.requested.tint")
                _require_exact(artifact.get("requestMode"), "custom-core-image-neutral", f"{key}.artifactRequestMode")
                _require_exact(provenance.get("processingIdentifier"), manifest["processing"]["customRAWDecoder"], f"{key}.processingIdentifier")
                _require_exact(provenance.get("requestMode"), "custom-core-image-neutral", f"{key}.requestMode")
                _require_exact(provenance.get("neutralPropertiesObserved"), True, f"{key}.neutralPropertiesObserved")
                _require_exact(provenance.get("setterOrder"), "temperature-then-tint", f"{key}.setterOrder")
                _require_exact(provenance.get("decoderVersion"), "8", f"{key}.decoderVersion")
                _require_exact(provenance.get("requested"), artifact.get("requested"), f"{key}.provenanceRequested")
                _require_exact(provenance.get("sourceAsShot"), run_scenes[scene_id]["sourceNeutral"], f"{key}.sourceAsShot")
                supported_versions = provenance.get("supportedDecoderVersions")
                if (
                    not isinstance(supported_versions, list)
                    or not all(isinstance(version, str) and version for version in supported_versions)
                    or supported_versions != sorted(set(supported_versions))
                    or "8" not in supported_versions
                ):
                    raise ObservationValidationError(f"{key}.supportedDecoderVersionsが不正です")
                _validate_decode_configuration(provenance.get("decodeConfiguration"), base_manifest, key)
                applied = _require_neutral_values(provenance.get("applied"), f"{key}.applied")
                if not math.isclose(
                    applied["temperatureKelvin"], request["temperatureKelvin"], rel_tol=2e-7, abs_tol=1e-5
                ):
                    raise ObservationValidationError(f"{key}.applied.temperatureKelvinがrequest readbackと一致しません")
                if not math.isclose(applied["tint"], request["tint"], rel_tol=2e-7, abs_tol=1e-5):
                    raise ObservationValidationError(f"{key}.applied.tintがrequest readbackと一致しません")
        elif role == "setter-order-comparison":
            if scene_id in setter_artifacts:
                raise ObservationValidationError(f"setter-order artifactが重複しています: {scene_id}")
            contract = contracts["custom-center"]
            expected_path = (
                f"{run_relative}/scenes/{scene_id}/setter-order/"
                "custom-center-tint-then-temperature.tif"
            )
            _require_exact(relative, expected_path, f"setter-order {scene_id}.path")
            _require_exact(artifact.get("candidateID"), "custom-center", f"setter-order {scene_id}.candidateID")
            _require_exact(artifact.get("candidateKind"), contract["candidate_kind"], f"setter-order {scene_id}.candidateKind")
            _require_exact(artifact.get("temperatureMiredOffset"), 0, f"setter-order {scene_id}.temperatureMiredOffset")
            _require_exact(artifact.get("tintOffset"), 0, f"setter-order {scene_id}.tintOffset")
            expected_request = expected_custom_request(
                run_scenes[scene_id]["sourceNeutral"], contract
            )
            request = _require_custom_request(
                artifact.get("requested"), f"setter-order {scene_id}.requested"
            )
            _require_close(request["temperatureKelvin"], expected_request["temperatureKelvin"], f"setter-order {scene_id}.requested.temperatureKelvin")
            _require_close(request["tint"], expected_request["tint"], f"setter-order {scene_id}.requested.tint")
            _require_exact(artifact.get("requestMode"), "custom-core-image-neutral", f"setter-order {scene_id}.artifactRequestMode")
            provenance = artifact.get("decodeProvenance")
            if not isinstance(provenance, dict):
                raise ObservationValidationError(f"setter-order provenanceがありません: {scene_id}")
            decode_contract = _validate_decode_provenance_common(
                provenance,
                artifact,
                manifest,
                base_manifest,
                base_scenes[scene_id]["capture"],
                runtime,
                f"setter-order {scene_id}",
            )
            supported_camera_hashes.add(decode_contract[-1])
            _require_exact(
                decode_contract,
                scene_decode_contracts.get(scene_id),
                f"setter-order {scene_id}.sceneDecodeContract",
            )
            _require_exact(provenance.get("processingIdentifier"), manifest["processing"]["customRAWDecoder"], f"setter-order {scene_id}.processingIdentifier")
            _require_exact(provenance.get("requestMode"), "custom-core-image-neutral", f"setter-order {scene_id}.requestMode")
            _require_exact(provenance.get("neutralPropertiesObserved"), True, f"setter-order {scene_id}.neutralPropertiesObserved")
            _require_exact(
                provenance.get("setterOrder"),
                "tint-then-temperature",
                f"setter-order {scene_id}",
            )
            _require_exact(provenance.get("decoderVersion"), "8", f"setter-order {scene_id}.decoderVersion")
            _require_exact(provenance.get("requested"), artifact.get("requested"), f"setter-order {scene_id}.provenanceRequested")
            _require_exact(provenance.get("sourceAsShot"), run_scenes[scene_id]["sourceNeutral"], f"setter-order {scene_id}.sourceAsShot")
            supported_versions = provenance.get("supportedDecoderVersions")
            if (
                not isinstance(supported_versions, list)
                or supported_versions != sorted(set(supported_versions))
                or "8" not in supported_versions
            ):
                raise ObservationValidationError(
                    f"setter-order {scene_id}.supportedDecoderVersionsが不正です"
                )
            _validate_decode_configuration(
                provenance.get("decodeConfiguration"),
                base_manifest,
                f"setter-order {scene_id}",
            )
            applied = _require_neutral_values(
                provenance.get("applied"), f"setter-order {scene_id}.applied"
            )
            if not math.isclose(
                applied["temperatureKelvin"],
                request["temperatureKelvin"],
                rel_tol=2e-7,
                abs_tol=1e-5,
            ) or not math.isclose(
                applied["tint"], request["tint"], rel_tol=2e-7, abs_tol=1e-5
            ):
                raise ObservationValidationError(
                    f"setter-order {scene_id}.appliedがrequest readbackと一致しません"
                )
            setter_artifacts[scene_id] = artifact
        else:
            raise ObservationValidationError(f"未知のartifact roleです: {role}")
    _require_exact(set(references), set(scene_ids), "reference scenes")
    expected_candidate_keys = {
        f"{scene_id}/{candidate_id}"
        for scene_id in scene_ids
        for candidate_id in candidate_ids
    }
    _require_exact(set(candidates), expected_candidate_keys, "candidate artifacts")
    _require_exact(set(setter_artifacts), set(scene_ids), "setter-order artifact scenes")
    if len(supported_camera_hashes) != 1:
        raise ObservationValidationError(
            "supportedCameraModelsSHA256が全scene/artifactで一致しません"
        )
    return references, candidates, setter_artifacts


def _validate_setter_order(
    run: dict[str, Any],
    candidates: dict[str, dict[str, Any]],
    setter_artifacts: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    checks = run.get("setterOrderChecks")
    if not isinstance(checks, list) or len(checks) != EXPECTED_SCENE_COUNT:
        raise ObservationValidationError("setter-order checkはsceneごとに1件必要です")
    output: list[dict[str, Any]] = []
    seen_scenes: set[str] = set()
    for check in checks:
        if not isinstance(check, dict):
            raise ObservationValidationError("setter-order checkがobjectではありません")
        _require_exact(
            set(check),
            {
                "sceneID", "candidateID", "primaryOrder", "comparisonOrder",
                "primarySHA256", "comparisonSHA256", "byteExact",
            },
            "setter-order check keys",
        )
        scene_id = check.get("sceneID")
        if (
            not isinstance(scene_id, str)
            or scene_id not in setter_artifacts
            or scene_id in seen_scenes
        ):
            raise ObservationValidationError(f"setter-order sceneが重複/不正です: {scene_id}")
        seen_scenes.add(scene_id)
        _require_exact(check.get("candidateID"), "custom-center", "setter-order candidateID")
        _require_exact(check.get("primaryOrder"), "temperature-then-tint", "setter-order primary")
        _require_exact(check.get("comparisonOrder"), "tint-then-temperature", "setter-order comparison")
        _require_exact(check.get("byteExact"), True, "setter-order byteExact")
        primary_hash = _require_lower_sha256(check.get("primarySHA256"), "primarySHA256")
        comparison_hash = _require_lower_sha256(
            check.get("comparisonSHA256"), "comparisonSHA256"
        )
        _require_exact(
            primary_hash,
            candidates[f"{scene_id}/custom-center"].get("sha256"),
            f"setter-order {scene_id}.primary artifact linkage",
        )
        _require_exact(
            comparison_hash,
            setter_artifacts[scene_id].get("sha256"),
            f"setter-order {scene_id}.comparison artifact linkage",
        )
        _require_exact(primary_hash, comparison_hash, "setter-order artifact hashes")
        output.append(
            {
                "scene_id": scene_id,
                "candidate_id": "custom-center",
                "primary_order": "temperature-then-tint",
                "comparison_order": "tint-then-temperature",
                "byte_exact": True,
                "sha256": primary_hash,
            }
        )
    _require_exact(seen_scenes, set(setter_artifacts), "setter-order check scenes")
    return output


def _finite_metrics(metrics: dict[str, Any], context: str) -> None:
    for key, value in metrics.items():
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            raise ObservationValidationError(f"{context}.{key}がfinite数値ではありません")


def build_report(
    root: Path,
    manifest_path: Path,
    run_path: Path,
) -> dict[str, Any]:
    manifest, manifest_sha256 = load_json_snapshot(manifest_path)
    run, run_sha256 = load_json_snapshot(run_path)
    validate_manifest(manifest)
    run_directory = _validate_run_header(root, run_path, run)
    base_manifest = _validate_manifest_and_base_hashes(
        root, manifest_path, manifest, run
    )
    runtime = _validate_runtime_and_tools(root, manifest, run)
    _validate_private_inputs_untracked(root, manifest)
    _validate_source_files(root, manifest, run)
    _validate_inputs(root, manifest, run)
    references, candidates, setter_artifacts = _validate_artifacts(
        root, run_directory, manifest, base_manifest, runtime, run
    )
    setter_order = _validate_setter_order(run, candidates, setter_artifacts)
    metrics_module = _load_calibration_module(root)
    analysis_runtime = _capture_analysis_runtime(metrics_module)
    scene_reports: list[dict[str, Any]] = []
    for scene in manifest["scenes"]:
        scene_id = scene["id"]
        reference_path = _resolve_inside(
            root, references[scene_id]["path"], f"reference {scene_id}"
        )
        reference = metrics_module.read_srgb(reference_path)
        as_shot_artifact = candidates[f"{scene_id}/as-shot"]
        custom_center_artifact = candidates[f"{scene_id}/custom-center"]
        as_shot_pixels = metrics_module.read_srgb(
            _resolve_inside(root, as_shot_artifact["path"], f"as-shot {scene_id}")
        )
        custom_center_pixels = metrics_module.read_srgb(
            _resolve_inside(
                root,
                custom_center_artifact["path"],
                f"custom-center {scene_id}",
            )
        )
        center_write_metrics = metrics_module.summarize(
            as_shot_pixels, custom_center_pixels
        )
        _finite_metrics(center_write_metrics, f"{scene_id}/custom-center-write")
        candidate_reports: list[dict[str, Any]] = []
        for candidate_id in expected_candidate_ids():
            artifact = candidates[f"{scene_id}/{candidate_id}"]
            candidate = metrics_module.read_srgb(
                _resolve_inside(root, artifact["path"], f"candidate {scene_id}/{candidate_id}")
            )
            metrics = metrics_module.summarize(reference, candidate)
            _finite_metrics(metrics, f"{scene_id}/{candidate_id}")
            candidate_reports.append(
                {
                    "candidate_id": candidate_id,
                    "candidate_kind": artifact.get("candidateKind"),
                    "temperature_mired_offset": artifact.get("temperatureMiredOffset"),
                    "tint_offset": artifact.get("tintOffset"),
                    "requested_core_image_neutral": artifact.get("requested"),
                    "metrics_against_fixed_lightroom_reference": metrics,
                }
            )
        scene_reports.append(
            {
                "scene_id": scene_id,
                "fold": "development",
                "teacher": scene["teacher"],
                "candidate_count": len(candidate_reports),
                "custom_center_write_observation": {
                    "as_shot_sha256": as_shot_artifact["sha256"],
                    "custom_center_sha256": custom_center_artifact["sha256"],
                    "byte_exact": (
                        as_shot_artifact["sha256"]
                        == custom_center_artifact["sha256"]
                    ),
                    "metrics_against_as_shot": center_write_metrics,
                    "interpretation": (
                        "This isolates the act of writing the fresh Core Image source "
                        "neutral back to a new RAW filter; it is descriptive, not a "
                        "cross-backend identity claim."
                    ),
                },
                "candidates_in_preregistered_order": candidate_reports,
            }
        )
    report: dict[str, Any] = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "report_kind": "white-balance-observation-only",
        "validation": {"status": "passed", "errors": []},
        "adoption": {
            "status": ADOPTION_STATUS,
            "production_adoption_allowed": PRODUCTION_ADOPTION_ALLOWED,
            "reason": (
                "This run contains descriptive development evidence only; it has no "
                "sealed holdout scenes and cannot change product white-balance behavior."
            ),
        },
        "dataset": {
            "scene_count": EXPECTED_SCENE_COUNT,
            "fold_counts": {"development": EXPECTED_SCENE_COUNT, "holdout": 0},
            "holdout_count": EXPECTED_HOLDOUT_COUNT,
            "limitations": [
                "Only two scenes from one camera model are present.",
                "Every scene was used during development.",
                "Lightroom is a fixed preference reference, not physical color truth.",
                "Adobe and Core Image Temperature/Tint numbers are backend-specific.",
                "No Lightroom Tint value is inferred from candidate ordering or distance.",
            ],
        },
        "methodology": {
            "candidate_order": "manifest-preregistered; no metric sorting",
            "comparison": (
                "Each 16-bit sRGB candidate is compared pixel-for-pixel with its fixed "
                "Lightroom 9.3 As Shot reference; analyzer-side resize and registration are forbidden."
            ),
            "metrics": (
                "CIEDE2000 after preregistered sigma 1.2 blur; RGB MAE, EV drift, clipping, "
                "and highlight plateau observations use the shared calibration implementation."
            ),
            "interpretation": "Measurements are descriptive and do not select a product transform.",
        },
        "manifest": {
            "path": str(manifest_path.relative_to(root)),
            "sha256": manifest_sha256,
            "suite_id": manifest["suiteID"],
        },
        "run": {
            "path": str(run_path.relative_to(root)),
            "sha256": run_sha256,
            "run_id": run["runID"],
            "source_fingerprint_sha256": run["sourceFingerprintSHA256"],
            "runtime": runtime,
            "exif_tool": run["exifTool"],
        },
        "analysis_runtime": analysis_runtime,
        "setter_order_observations": setter_order,
        "scenes": scene_reports,
    }
    # Revalidate every file-backed input after metrics have consumed the TIFFs.
    # This prevents a report from combining provenance for byte set A with
    # measurements from a file changed in-place to byte set B during analysis.
    postflight_base_manifest = _validate_manifest_and_base_hashes(
        root, manifest_path, manifest, run
    )
    _require_exact(
        postflight_base_manifest,
        base_manifest,
        "base calibration manifest postflight",
    )
    _require_exact(
        _validate_runtime_and_tools(root, manifest, run),
        runtime,
        "runtime/tool postflight",
    )
    _validate_private_inputs_untracked(root, manifest)
    _validate_source_files(root, manifest, run)
    _validate_inputs(root, manifest, run)
    postflight_references, postflight_candidates, postflight_setter_artifacts = (
        _validate_artifacts(
            root, run_directory, manifest, base_manifest, runtime, run
        )
    )
    _require_exact(postflight_references, references, "reference artifacts postflight")
    _require_exact(postflight_candidates, candidates, "candidate artifacts postflight")
    _require_exact(
        postflight_setter_artifacts,
        setter_artifacts,
        "setter-order artifacts postflight",
    )
    _require_exact(
        _validate_setter_order(
            run, postflight_candidates, postflight_setter_artifacts
        ),
        setter_order,
        "setter-order records postflight",
    )
    _require_exact(
        sha256_file(manifest_path),
        manifest_sha256,
        "observation manifest postflight SHA256",
    )
    _require_exact(sha256_file(run_path), run_sha256, "run.json postflight SHA256")
    _require_exact(
        _capture_analysis_runtime(metrics_module),
        analysis_runtime,
        "analysis runtime postflight",
    )
    assert_observation_language(report)
    return report


def assert_observation_language(value: Any, path: str = "report") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            lowered = str(key).lower()
            if child_path not in OPAQUE_PROVENANCE_KEY_PATHS:
                for token in FORBIDDEN_OBSERVATION_LANGUAGE:
                    if token in lowered:
                        raise ObservationValidationError(
                            f"observation report keyに採用語彙があります: {child_path}"
                        )
            assert_observation_language(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            assert_observation_language(child, f"{path}[{index}]")
    elif isinstance(value, str):
        lowered = value.lower()
        for token in FORBIDDEN_OBSERVATION_LANGUAGE:
            if token in lowered:
                raise ObservationValidationError(
                    f"observation report textに採用語彙があります: {path}"
                )


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        indent=2,
        allow_nan=False,
        sort_keys=False,
    ) + "\n"
    path.parent.mkdir(parents=False, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        # Publish without replacement: hard-link creation is atomic and fails
        # if another process or symlink claims the destination after preflight.
        try:
            os.link(temporary_name, path)
        except FileExistsError as error:
            raise ObservationValidationError(
                "analysis outputが競合したため上書きを拒否しました"
            ) from error
        os.unlink(temporary_name)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    root = args.root.resolve(strict=True)
    manifest_path = (
        args.manifest
        if args.manifest is not None
        else Path("calibration/white-balance-observation-v1.json")
    )
    manifest_path = _resolve_inside(root, str(manifest_path), "--manifest")
    run_path = _resolve_inside(root, str(args.run), "--run")
    if not manifest_path.is_file() or not run_path.is_file():
        raise ObservationValidationError("manifestまたはrun fileがありません")
    expected_parent = root / ".photobench" / "white-balance-observations"
    try:
        run_path.relative_to(expected_parent)
    except ValueError as error:
        raise ObservationValidationError("runがWB observation出力root外です") from error
    output_path = (
        _resolve_inside(root, str(args.output), "--output")
        if args.output is not None
        else run_path.parent / "analysis.json"
    )
    if output_path.parent != run_path.parent:
        raise ObservationValidationError("analysis outputは対象run directory内に限定されます")
    if output_path.exists() or output_path.is_symlink():
        raise ObservationValidationError("既存analysis outputは上書きできません")
    report = build_report(root, manifest_path, run_path)
    atomic_write_json(output_path, report)
    print(f"Observation analysis: {output_path}")
    print("Scenes: 2 development / 0 holdout")
    print("Production adoption allowed: false")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ObservationValidationError as error:
        print(f"STRUCTURAL VALIDATION FAILED: {error}", file=sys.stderr)
        raise SystemExit(2) from error
