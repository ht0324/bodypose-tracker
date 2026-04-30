#!/usr/bin/env python3
"""Realtime Apple Vision face/hand MVP for a MacBook camera.

The script keeps all frames local. It uses OpenCV only for camera/display and
Apple Vision, through PyObjC, for face rectangles and hand landmarks.
"""

from __future__ import annotations

import argparse
import math
import os
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import cv2
import numpy as np
import Quartz
import Vision
from Foundation import NSData

try:
    import AVFoundation
except Exception:  # pragma: no cover - optional camera permission helper
    AVFoundation = None

try:
    import AppKit
except Exception:  # pragma: no cover - optional audible alert
    AppKit = None


DEFAULT_ALERT_SOUND_PATH = str(Path(__file__).resolve().parent / "Resources" / "iMovie-Alarm.mp3")

BODY_LABELS = {
    Vision.VNHumanBodyPoseObservationJointNameNose: "nose",
    Vision.VNHumanBodyPoseObservationJointNameLeftEye: "left_eye",
    Vision.VNHumanBodyPoseObservationJointNameRightEye: "right_eye",
    Vision.VNHumanBodyPoseObservationJointNameLeftEar: "left_ear",
    Vision.VNHumanBodyPoseObservationJointNameRightEar: "right_ear",
    Vision.VNHumanBodyPoseObservationJointNameNeck: "neck",
    Vision.VNHumanBodyPoseObservationJointNameRoot: "root",
    Vision.VNHumanBodyPoseObservationJointNameLeftShoulder: "left_shoulder",
    Vision.VNHumanBodyPoseObservationJointNameRightShoulder: "right_shoulder",
    Vision.VNHumanBodyPoseObservationJointNameLeftElbow: "left_elbow",
    Vision.VNHumanBodyPoseObservationJointNameRightElbow: "right_elbow",
    Vision.VNHumanBodyPoseObservationJointNameLeftWrist: "left_wrist",
    Vision.VNHumanBodyPoseObservationJointNameRightWrist: "right_wrist",
    Vision.VNHumanBodyPoseObservationJointNameLeftHip: "left_hip",
    Vision.VNHumanBodyPoseObservationJointNameRightHip: "right_hip",
    Vision.VNHumanBodyPoseObservationJointNameLeftKnee: "left_knee",
    Vision.VNHumanBodyPoseObservationJointNameRightKnee: "right_knee",
    Vision.VNHumanBodyPoseObservationJointNameLeftAnkle: "left_ankle",
    Vision.VNHumanBodyPoseObservationJointNameRightAnkle: "right_ankle",
}

HAND_LABELS = {
    Vision.VNHumanHandPoseObservationJointNameWrist: "wrist",
    Vision.VNHumanHandPoseObservationJointNameThumbCMC: "thumb_cmc",
    Vision.VNHumanHandPoseObservationJointNameThumbMP: "thumb_mp",
    Vision.VNHumanHandPoseObservationJointNameThumbIP: "thumb_ip",
    Vision.VNHumanHandPoseObservationJointNameThumbTip: "thumb_tip",
    Vision.VNHumanHandPoseObservationJointNameIndexMCP: "index_mcp",
    Vision.VNHumanHandPoseObservationJointNameIndexPIP: "index_pip",
    Vision.VNHumanHandPoseObservationJointNameIndexDIP: "index_dip",
    Vision.VNHumanHandPoseObservationJointNameIndexTip: "index_tip",
    Vision.VNHumanHandPoseObservationJointNameMiddleMCP: "middle_mcp",
    Vision.VNHumanHandPoseObservationJointNameMiddlePIP: "middle_pip",
    Vision.VNHumanHandPoseObservationJointNameMiddleDIP: "middle_dip",
    Vision.VNHumanHandPoseObservationJointNameMiddleTip: "middle_tip",
    Vision.VNHumanHandPoseObservationJointNameRingMCP: "ring_mcp",
    Vision.VNHumanHandPoseObservationJointNameRingPIP: "ring_pip",
    Vision.VNHumanHandPoseObservationJointNameRingDIP: "ring_dip",
    Vision.VNHumanHandPoseObservationJointNameRingTip: "ring_tip",
    Vision.VNHumanHandPoseObservationJointNameLittleMCP: "little_mcp",
    Vision.VNHumanHandPoseObservationJointNameLittlePIP: "little_pip",
    Vision.VNHumanHandPoseObservationJointNameLittleDIP: "little_dip",
    Vision.VNHumanHandPoseObservationJointNameLittleTip: "little_tip",
}

BODY_EDGES = [
    ("neck", "root"),
    ("neck", "left_shoulder"),
    ("left_shoulder", "left_elbow"),
    ("left_elbow", "left_wrist"),
    ("neck", "right_shoulder"),
    ("right_shoulder", "right_elbow"),
    ("right_elbow", "right_wrist"),
    ("root", "left_hip"),
    ("left_hip", "left_knee"),
    ("left_knee", "left_ankle"),
    ("root", "right_hip"),
    ("right_hip", "right_knee"),
    ("right_knee", "right_ankle"),
    ("nose", "left_eye"),
    ("left_eye", "left_ear"),
    ("nose", "right_eye"),
    ("right_eye", "right_ear"),
]

HAND_EDGES = [
    ("wrist", "thumb_cmc"),
    ("thumb_cmc", "thumb_mp"),
    ("thumb_mp", "thumb_ip"),
    ("thumb_ip", "thumb_tip"),
    ("wrist", "index_mcp"),
    ("index_mcp", "index_pip"),
    ("index_pip", "index_dip"),
    ("index_dip", "index_tip"),
    ("wrist", "middle_mcp"),
    ("middle_mcp", "middle_pip"),
    ("middle_pip", "middle_dip"),
    ("middle_dip", "middle_tip"),
    ("wrist", "ring_mcp"),
    ("ring_mcp", "ring_pip"),
    ("ring_pip", "ring_dip"),
    ("ring_dip", "ring_tip"),
    ("wrist", "little_mcp"),
    ("little_mcp", "little_pip"),
    ("little_pip", "little_dip"),
    ("little_dip", "little_tip"),
]

HAND_ALERT_POINTS = {
    "wrist",
    "thumb_tip",
    "index_tip",
    "middle_tip",
    "ring_tip",
    "little_tip",
}


@dataclass(frozen=True)
class Landmark:
    x: float
    y: float
    confidence: float

    @property
    def xy(self) -> tuple[int, int]:
        return int(round(self.x)), int(round(self.y))


@dataclass(frozen=True)
class FaceBox:
    x: float
    y: float
    width: float
    height: float
    confidence: float

    @property
    def center(self) -> tuple[float, float]:
        return self.x + self.width / 2.0, self.y + self.height / 2.0

    @property
    def xyxy(self) -> tuple[int, int, int, int]:
        return (
            int(round(self.x)),
            int(round(self.y)),
            int(round(self.x + self.width)),
            int(round(self.y + self.height)),
        )


@dataclass(frozen=True)
class HeadZone:
    center: tuple[float, float]
    radius_x: float
    radius_y: float
    face_box: FaceBox
    stale: bool = False


@dataclass
class HairAlertState:
    active: bool = False
    streak: int = 0
    min_distance: float | None = None
    zone_score: float | None = None
    head_zone: HeadZone | None = None
    face_seen: bool = False


PROFILES = {
    "debug": {
        "width": 960,
        "height": 540,
        "camera_fps": 30.0,
        "max_dimension": 640,
        "max_hands": 2,
        "target_fps": 0.0,
        "trigger_frames": 5,
        "trigger_seconds": 0.3,
        "process_every": 1,
        "presence_gate": False,
        "preview": True,
        "debug_body": True,
    },
    "realtime": {
        "width": 960,
        "height": 540,
        "camera_fps": 30.0,
        "max_dimension": 640,
        "max_hands": 2,
        "target_fps": 0.0,
        "trigger_frames": 5,
        "trigger_seconds": 0.3,
        "process_every": 1,
        "presence_gate": False,
        "preview": True,
        "debug_body": False,
    },
    "balanced": {
        "width": 640,
        "height": 360,
        "camera_fps": 10.0,
        "max_dimension": 480,
        "max_hands": 2,
        "target_fps": 10.0,
        "trigger_frames": 5,
        "trigger_seconds": 0.3,
        "process_every": 1,
        "presence_gate": False,
        "preview": True,
        "debug_body": False,
    },
    "production": {
        "width": 640,
        "height": 360,
        "camera_fps": 10.0,
        "max_dimension": 480,
        "max_hands": 1,
        "target_fps": 10.0,
        "trigger_frames": 5,
        "trigger_seconds": 0.3,
        "process_every": 1,
        "presence_gate": True,
        "preview": False,
        "debug_body": False,
    },
}


def cgimage_from_bgr(frame: np.ndarray):
    rgba = np.ascontiguousarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGBA))
    height, width = rgba.shape[:2]
    data = NSData.dataWithBytes_length_(rgba.tobytes(), rgba.nbytes)
    provider = Quartz.CGDataProviderCreateWithCFData(data)
    color_space = Quartz.CGColorSpaceCreateDeviceRGB()
    return Quartz.CGImageCreate(
        width,
        height,
        8,
        32,
        width * 4,
        color_space,
        Quartz.kCGImageAlphaLast | Quartz.kCGBitmapByteOrder32Big,
        provider,
        None,
        False,
        Quartz.kCGRenderingIntentDefault,
    )


def unwrap_objc_result(value):
    if isinstance(value, tuple) and len(value) == 2:
        result, error = value
        if error is not None:
            raise RuntimeError(str(error))
        return result
    return value


class AppleVisionTracker:
    def __init__(self, max_hands: int, max_dimension: int, debug_body: bool):
        self.face_request = Vision.VNDetectFaceRectanglesRequest.alloc().init()
        self.hand_request = Vision.VNDetectHumanHandPoseRequest.alloc().init()
        self.hand_request.setMaximumHandCount_(max_hands)
        self.body_request = Vision.VNDetectHumanBodyPoseRequest.alloc().init() if debug_body else None

        requests = [self.face_request, self.hand_request]
        if self.body_request is not None:
            requests.append(self.body_request)

        for request in requests:
            if hasattr(request, "setMaximumProcessingDimensionOnTheLongSide_"):
                request.setMaximumProcessingDimensionOnTheLongSide_(max_dimension)

        self.requests = requests

    def detect(
        self, frame: np.ndarray, min_confidence: float, include_hands: bool
    ) -> tuple[FaceBox | None, list[dict[str, Landmark]], dict[str, Landmark]]:
        height, width = frame.shape[:2]
        cg_image = cgimage_from_bgr(frame)
        requests = [self.face_request]
        if include_hands:
            requests.append(self.hand_request)
        if self.body_request is not None:
            requests.append(self.body_request)
        handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_orientation_options_(
            cg_image,
            Quartz.kCGImagePropertyOrientationUp,
            {},
        )
        ok, error = handler.performRequests_error_(requests, None)
        if not ok:
            raise RuntimeError(f"Vision request failed: {error}")

        face = best_face_box(self.face_request.results() or [], width, height)

        hands = []
        if include_hands:
            hands = [
                recognized_landmarks(
                    observation,
                    Vision.VNHumanHandPoseObservationJointsGroupNameAll,
                    HAND_LABELS,
                    width,
                    height,
                    min_confidence,
                )
                for observation in list(self.hand_request.results() or [])
            ]

        body = {}
        body_results = list(self.body_request.results() or []) if self.body_request is not None else []
        if body_results:
            body = recognized_landmarks(
                body_results[0],
                Vision.VNHumanBodyPoseObservationJointsGroupNameAll,
                BODY_LABELS,
                width,
                height,
                min_confidence,
            )

        return face, hands, body


def best_face_box(observations, width: int, height: int) -> FaceBox | None:
    faces = [face_box_from_observation(obs, width, height) for obs in list(observations)]
    faces = [face for face in faces if face.width > 1 and face.height > 1]
    if not faces:
        return None
    return max(faces, key=lambda face: face.width * face.height * max(face.confidence, 0.01))


def face_box_from_observation(observation, width: int, height: int) -> FaceBox:
    box = observation.boundingBox()
    return FaceBox(
        x=float(box.origin.x) * width,
        y=(1.0 - float(box.origin.y) - float(box.size.height)) * height,
        width=float(box.size.width) * width,
        height=float(box.size.height) * height,
        confidence=float(observation.confidence()),
    )


def recognized_landmarks(
    observation,
    group_name,
    labels: dict[object, str],
    width: int,
    height: int,
    min_confidence: float,
) -> dict[str, Landmark]:
    points = unwrap_objc_result(
        observation.recognizedPointsForJointsGroupName_error_(group_name, None)
    )
    landmarks = {}
    for joint_key, point in dict(points).items():
        confidence = float(point.confidence())
        if confidence < min_confidence:
            continue
        label = labels.get(joint_key, str(joint_key))
        landmarks[label] = Landmark(
            x=float(point.x()) * width,
            y=(1.0 - float(point.y())) * height,
            confidence=confidence,
        )
    return landmarks


def estimate_head_zone(face: FaceBox, head_scale: float, stale: bool = False) -> HeadZone:
    cx = face.x + face.width * 0.5
    cy = face.y + face.height * 0.38
    radius_x = max(48.0, face.width * 0.78 * head_scale)
    radius_y = max(58.0, face.height * 0.82 * head_scale)
    return HeadZone(center=(cx, cy), radius_x=radius_x, radius_y=radius_y, face_box=face, stale=stale)


def estimate_hand_roi(face: FaceBox, frame_width: int, frame_height: int, scale: float = 5.0) -> tuple[int, int, int, int]:
    side = min(float(max(frame_width, frame_height)), max(face.width, face.height) * scale)
    cx, cy = face.center
    x1 = max(0.0, min(float(frame_width) - side, cx - side * 0.5))
    y1 = max(0.0, min(float(frame_height) - side, cy - side * 0.5))
    return (
        int(round(x1)),
        int(round(y1)),
        int(round(x1 + side)),
        int(round(y1 + side)),
    )


def distance_between(a: Landmark | None, b: Landmark | None) -> float:
    if a is None or b is None:
        return 0.0
    return math.hypot(a.x - b.x, a.y - b.y)


class HairPickingDetector:
    def __init__(
        self,
        trigger_frames: int,
        trigger_seconds: float,
        head_scale: float,
        face_hold_seconds: float,
        beep: bool,
        beep_cooldown: float,
        alert_sound: str | None,
    ):
        self.trigger_frames = trigger_frames
        self.trigger_seconds = max(0.0, trigger_seconds)
        self.head_scale = head_scale
        self.face_hold_seconds = face_hold_seconds
        self.beep = beep
        self.beep_cooldown = beep_cooldown
        self.alert_sound = None
        if alert_sound and AppKit is not None and os.path.exists(alert_sound):
            self.alert_sound = AppKit.NSSound.alloc().initWithContentsOfFile_byReference_(alert_sound, True)
        self.streak = 0
        self.close_started_at: float | None = None
        self.alert_active = False
        self.last_beep_at = 0.0
        self.last_face: FaceBox | None = None
        self.last_face_at = 0.0

    def update(
        self,
        face: FaceBox | None,
        hands: list[dict[str, Landmark]],
        now: float,
    ) -> HairAlertState:
        face_seen = face is not None
        if face is not None:
            self.last_face = face
            self.last_face_at = now
            stale = False
        elif self.last_face is not None and now - self.last_face_at <= self.face_hold_seconds:
            face = self.last_face
            stale = True
        else:
            self.reset_close_tracking()
            return HairAlertState(False, self.streak, None, None, None, False)

        head_zone = estimate_head_zone(face, self.head_scale, stale)
        hand_points = list(iter_hand_alert_points(hands))
        min_distance = None
        zone_score = None
        close = False
        if hand_points:
            hx, hy = head_zone.center
            distances = [math.hypot(point.x - hx, point.y - hy) for point in hand_points]
            scores = [
                math.hypot(
                    (point.x - hx) / head_zone.radius_x,
                    (point.y - hy) / head_zone.radius_y,
                )
                for point in hand_points
                if point.y <= head_zone.face_box.y + head_zone.face_box.height * 1.10
            ]
            min_distance = min(distances)
            if scores:
                zone_score = min(scores)
                close = zone_score <= 1.0

        if close:
            if self.close_started_at is None:
                self.close_started_at = now
            self.streak += 1
        else:
            self.reset_close_tracking()

        active = self.close_started_at is not None and now - self.close_started_at >= self.trigger_seconds - 1e-9
        if active:
            self.alert_active = True
            if self.beep and AppKit is not None and now - self.last_beep_at >= self.beep_cooldown:
                played = False
                if self.alert_sound is not None:
                    self.alert_sound.stop()
                    played = bool(self.alert_sound.play())
                if not played:
                    AppKit.NSBeep()
                self.last_beep_at = now
        elif self.alert_active:
            self.alert_active = False
            if self.alert_sound is not None:
                self.alert_sound.stop()

        return HairAlertState(active, self.streak, min_distance, zone_score, head_zone, face_seen)

    def reset_close_tracking(self) -> None:
        self.streak = 0
        self.close_started_at = None

    def has_recent_face(self, now: float) -> bool:
        return self.last_face is not None and now - self.last_face_at <= self.face_hold_seconds


def iter_hand_alert_points(hands: list[dict[str, Landmark]]) -> Iterable[Landmark]:
    for hand in hands:
        for name in HAND_ALERT_POINTS:
            if name in hand:
                yield hand[name]


def draw_landmarks(
    frame: np.ndarray,
    landmarks: dict[str, Landmark],
    edges: list[tuple[str, str]],
    point_color: tuple[int, int, int],
    line_color: tuple[int, int, int],
) -> None:
    for a, b in edges:
        if a in landmarks and b in landmarks:
            cv2.line(frame, landmarks[a].xy, landmarks[b].xy, line_color, 2, cv2.LINE_AA)
    for point in landmarks.values():
        cv2.circle(frame, point.xy, 4, point_color, -1, cv2.LINE_AA)


def draw_overlay(
    frame: np.ndarray,
    face: FaceBox | None,
    body: dict[str, Landmark],
    hands: list[dict[str, Landmark]],
    alert: HairAlertState,
    fps: float,
    show_body: bool,
) -> None:
    if show_body:
        draw_landmarks(frame, body, BODY_EDGES, (80, 255, 120), (60, 190, 90))
    for hand in hands:
        draw_landmarks(frame, hand, HAND_EDGES, (255, 220, 90), (230, 170, 40))

    if face is not None:
        x1, y1, x2, y2 = face.xyxy
        cv2.rectangle(frame, (x1, y1), (x2, y2), (80, 255, 120), 1, cv2.LINE_AA)
        rx1, ry1, rx2, ry2 = estimate_hand_roi(face, frame.shape[1], frame.shape[0], scale=5.0)
        cv2.rectangle(frame, (rx1, ry1), (rx2, ry2), (80, 200, 255), 1, cv2.LINE_AA)

    if alert.head_zone is not None:
        center = tuple(int(round(v)) for v in alert.head_zone.center)
        axes = (
            int(round(alert.head_zone.radius_x)),
            int(round(alert.head_zone.radius_y)),
        )
        if alert.active:
            color = (0, 0, 255)
        elif alert.head_zone.stale:
            color = (180, 180, 180)
        else:
            color = (255, 180, 80)
        cv2.ellipse(frame, center, axes, 0, 0, 360, color, 2, cv2.LINE_AA)

    if alert.active:
        cv2.rectangle(frame, (0, 0), (frame.shape[1], 58), (0, 0, 190), -1)
        cv2.putText(
            frame,
            "HAND NEAR HEAD",
            (18, 38),
            cv2.FONT_HERSHEY_SIMPLEX,
            1.0,
            (255, 255, 255),
            2,
            cv2.LINE_AA,
        )

    face_status = "face"
    if alert.head_zone is not None and alert.head_zone.stale:
        face_status = "face cached"
    elif face is None:
        face_status = "face none"
    status = f"FPS {fps:4.1f} | {face_status} | hands {len(hands)} | streak {alert.streak}"
    if show_body:
        status += f" | body {len(body):02d} pts"
    if alert.zone_score is not None:
        status += f" | zone {alert.zone_score:.2f}x"
    cv2.rectangle(frame, (0, frame.shape[0] - 28), (frame.shape[1], frame.shape[0]), (20, 20, 20), -1)
    cv2.putText(
        frame,
        status,
        (12, frame.shape[0] - 8),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.55,
        (235, 235, 235),
        1,
        cv2.LINE_AA,
    )


def throttle_loop(start_time: float, target_fps: float) -> None:
    if target_fps <= 0:
        return
    elapsed = time.perf_counter() - start_time
    delay = max(0.0, (1.0 / target_fps) - elapsed)
    if delay > 0:
        time.sleep(delay)


def open_camera(camera_index: int, width: int, height: int, fps: float):
    cap = cv2.VideoCapture(camera_index, cv2.CAP_AVFOUNDATION)
    if not cap.isOpened():
        return None
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    if fps > 0:
        cap.set(cv2.CAP_PROP_FPS, fps)
    return cap


def ensure_camera_permission(wait_seconds: float = 90.0) -> bool:
    if AVFoundation is None:
        return True

    media_type = AVFoundation.AVMediaTypeVideo
    status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(media_type)
    if status == 3:
        return True
    if status in (1, 2):
        return False
    if status != 0:
        return True

    done = threading.Event()
    result = {"granted": False}

    def callback(granted):
        result["granted"] = bool(granted)
        done.set()

    AVFoundation.AVCaptureDevice.requestAccessForMediaType_completionHandler_(media_type, callback)
    done.wait(wait_seconds)
    return result["granted"] or AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(media_type) == 3


def run_self_test() -> int:
    frame = np.zeros((240, 320, 3), dtype=np.uint8)
    tracker = AppleVisionTracker(max_hands=2, max_dimension=640, debug_body=True)
    face, hands, body = tracker.detect(frame, min_confidence=0.2, include_hands=True)
    print(
        "Vision self-test ok: "
        f"face={'yes' if face else 'none'} hands={len(hands)} body_points={len(body)}"
    )
    return 0


def run(args: argparse.Namespace) -> int:
    if args.self_test:
        return run_self_test()

    apply_profile(args)

    if os.environ.get("BODYPOSE_SKIP_PERMISSION") != "1" and not ensure_camera_permission():
        print(
            "Camera permission was not granted. If no prompt appeared, launch "
            "the app wrapper in dist/BodyPoseTracker.app so macOS can attach "
            "the request to a real app identity.",
            file=sys.stderr,
        )

    cap = open_camera(args.camera, args.width, args.height, args.camera_fps)
    if cap is None:
        print(
            "Could not open the camera. macOS probably has not granted Camera "
            "permission to this Terminal/Python process yet.",
            file=sys.stderr,
        )
        print(
            "Open System Settings > Privacy & Security > Camera, allow your "
            "terminal app, then rerun this command.",
            file=sys.stderr,
        )
        return 2

    tracker = AppleVisionTracker(args.max_hands, args.max_dimension, args.debug_body)
    detector = HairPickingDetector(
        trigger_frames=args.trigger_frames,
        trigger_seconds=args.trigger_seconds,
        head_scale=args.head_scale,
        face_hold_seconds=args.face_hold_seconds,
        beep=args.beep,
        beep_cooldown=args.beep_cooldown,
        alert_sound=args.alert_sound,
    )

    window_name = "BodyPoseTracker Face+Hand - q/esc to quit"
    face: FaceBox | None = None
    body: dict[str, Landmark] = {}
    hands: list[dict[str, Landmark]] = []
    alert = HairAlertState()
    frame_index = 0
    last_tick = time.perf_counter()
    fps = 0.0

    try:
        while True:
            loop_started = time.perf_counter()
            ok, frame = cap.read()
            if not ok or frame is None:
                print("Camera frame read failed.", file=sys.stderr)
                return 3

            if args.mirror:
                frame = cv2.flip(frame, 1)

            if frame_index % args.process_every == 0:
                now_mono = time.monotonic()
                include_hands = not args.presence_gate or detector.has_recent_face(now_mono)
                face, hands, body = tracker.detect(frame, args.confidence, include_hands)
                alert = detector.update(face, hands, now_mono)

            now = time.perf_counter()
            dt = now - last_tick
            if dt > 0:
                fps = 0.9 * fps + 0.1 * (1.0 / dt) if fps else 1.0 / dt
            last_tick = now

            if args.preview:
                draw_overlay(frame, face, body, hands, alert, fps, args.debug_body)
                cv2.imshow(window_name, frame)
                key = cv2.waitKey(1) & 0xFF
                if key in (27, ord("q")):
                    return 0
            elif frame_index % max(1, int(args.target_fps or 6) * 30) == 0:
                print(
                    f"running fps={fps:.1f} face={alert.face_seen} "
                    f"hands={len(hands)} streak={alert.streak}",
                    flush=True,
                )
            frame_index += 1
            throttle_loop(loop_started, args.target_fps)
    finally:
        cap.release()
        cv2.destroyAllWindows()


def apply_profile(args: argparse.Namespace) -> None:
    if args.profile is None:
        return
    profile = PROFILES[args.profile]
    for key, value in profile.items():
        setattr(args, key, value)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--profile",
        choices=sorted(PROFILES),
        help="Apply a preset: debug, realtime, balanced, or production.",
    )
    parser.add_argument("--camera", type=int, default=0, help="OpenCV camera index.")
    parser.add_argument("--width", type=int, default=960, help="Requested camera width.")
    parser.add_argument("--height", type=int, default=540, help="Requested camera height.")
    parser.add_argument("--camera-fps", type=float, default=30.0, help="Requested camera capture FPS.")
    parser.add_argument("--confidence", type=float, default=0.28, help="Minimum Vision landmark confidence.")
    parser.add_argument("--max-hands", type=int, default=2, help="Maximum hands to detect.")
    parser.add_argument("--max-dimension", type=int, default=640, help="Vision long-side processing cap.")
    parser.add_argument("--process-every", type=int, default=1, help="Run Vision every N frames.")
    parser.add_argument("--trigger-frames", type=int, default=5, help="Consecutive close frames before warning.")
    parser.add_argument("--trigger-seconds", type=float, default=0.3, help="Continuous close duration before warning.")
    parser.add_argument("--head-scale", type=float, default=1.4, help="Face-derived head ellipse multiplier.")
    parser.add_argument("--face-hold-seconds", type=float, default=1.0, help="Reuse the last face box during brief hand occlusion.")
    parser.add_argument("--target-fps", type=float, default=0.0, help="Limit processing/display FPS. 0 means uncapped.")
    parser.set_defaults(presence_gate=False)
    gate_group = parser.add_mutually_exclusive_group()
    gate_group.add_argument("--presence-gate", dest="presence_gate", action="store_true", help="Skip hand inference until a recent face exists.")
    gate_group.add_argument("--no-presence-gate", dest="presence_gate", action="store_false", help="Always run hand inference.")
    parser.set_defaults(preview=True)
    preview_group = parser.add_mutually_exclusive_group()
    preview_group.add_argument("--preview", dest="preview", action="store_true", help="Show the camera preview window.")
    preview_group.add_argument("--no-preview", dest="preview", action="store_false", help="Run without a preview window.")
    parser.add_argument("--debug-body", action="store_true", help="Also run and draw body pose landmarks.")
    parser.add_argument("--beep", action="store_true", help="Beep when the warning activates.")
    parser.add_argument("--beep-cooldown", type=float, default=2.0, help="Seconds between beeps.")
    parser.add_argument("--alert-sound", default=DEFAULT_ALERT_SOUND_PATH, help="Sound file to play for warnings.")
    parser.add_argument("--self-test", action="store_true", help="Run a no-camera Vision bridge test.")
    parser.set_defaults(mirror=True)
    mirror_group = parser.add_mutually_exclusive_group()
    mirror_group.add_argument("--mirror", dest="mirror", action="store_true", help="Mirror the camera preview.")
    mirror_group.add_argument("--no-mirror", dest="mirror", action="store_false", help="Do not mirror the camera preview.")
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(run(parse_args()))
