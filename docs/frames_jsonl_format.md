# frames.jsonl Format

Each line is a self-contained JSON object representing one captured frame. All sensor data is synchronized to the ARKit frame timestamp.

## Example

```json
{
  "frame_index": 42,
  "timestamp": 12345.678901,

  "camera_transform": [
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.1, 0.5, -1.2, 1.0
  ],

  "camera_intrinsics": [
    1440.0, 0.0, 0.0,
    0.0, 1440.0, 0.0,
    960.0, 720.0, 1.0
  ],

  "camera_resolution": [1920, 1440],
  "camera_euler_angles": [0.12, -0.05, 0.03],
  "tracking_state": "normal",
  "exposure_duration": 0.0333,
  "exposure_offset": 0.0,
  "has_depth": false,

  "feature_point_count": 312,
  "ambient_intensity": 1002.5,
  "ambient_color_temperature": 6500.0,

  "imu_timestamp": 12345.671234,
  "user_acceleration": [0.01, -0.02, 0.003],
  "rotation_rate": [0.001, -0.003, 0.0005],
  "gravity": [0.0, -0.98, -0.18],
  "attitude_euler": [0.12, -0.05, 1.57],
  "attitude_quaternion": [0.06, -0.02, 0.71, 0.70],
  "magnetic_field": [23.1, -45.2, -12.8]
}
```

## Field Reference

### Timing

| Field | Type | Description |
|-------|------|-------------|
| `frame_index` | int | Sequential frame counter starting at 0 |
| `timestamp` | float | ARKit frame capture time (Mach absolute time, seconds since device boot) |
| `imu_timestamp` | float | IMU sample time, same clock as `timestamp` — subtract to get offset |

### Camera Extrinsics

| Field | Type | Description |
|-------|------|-------------|
| `camera_transform` | float[16] | 4×4 column-major camera-to-world matrix. Translation is at indices [12], [13], [14] |
| `camera_euler_angles` | float[3] | Pitch, yaw, roll in radians |

**Unpacking the transform in Python:**
```python
import numpy as np
T = np.array(frame["camera_transform"]).reshape(4, 4, order='F')  # column-major
position = T[:3, 3]      # camera world position
rotation = T[:3, :3]     # camera world orientation
```

### Camera Intrinsics

| Field | Type | Description |
|-------|------|-------------|
| `camera_intrinsics` | float[9] | 3×3 column-major intrinsics matrix |
| `camera_resolution` | int[2] | [width, height] in pixels |

**Unpacking in Python:**
```python
K = np.array(frame["camera_intrinsics"]).reshape(3, 3, order='F')
fx, fy = K[0, 0], K[1, 1]
cx, cy = K[0, 2], K[1, 2]
```

### Tracking

| Field | Type | Description |
|-------|------|-------------|
| `tracking_state` | string | `normal`, `initializing`, `limited_motion`, `limited_features`, `relocalizing`, `not_available` |

### Exposure

| Field | Type | Description |
|-------|------|-------------|
| `exposure_duration` | float | Shutter duration in seconds |
| `exposure_offset` | float | Exposure compensation in EV |

### Depth (LiDAR devices only)

| Field | Type | Description |
|-------|------|-------------|
| `has_depth` | bool | Whether depth data was captured for this frame |
| `depth_resolution` | int[2] | [width, height] of depth map (typically 256×192) |

Depth maps are stored as raw `Float32` binary files at `depth/NNNNNN.bin`.  
Confidence maps are stored as raw `UInt8` binary files at `confidence/NNNNNN.bin` (values: 0=low, 1=medium, 2=high).

**Loading in Python:**
```python
import numpy as np
depth = np.fromfile("depth/000042.bin", dtype=np.float32).reshape(192, 256)
conf  = np.fromfile("confidence/000042.bin", dtype=np.uint8).reshape(192, 256)
```

### IMU (synchronized per-frame)

| Field | Type | Description |
|-------|------|-------------|
| `user_acceleration` | float[3] | Linear acceleration minus gravity, in g (x, y, z) |
| `rotation_rate` | float[3] | Gyroscope angular velocity in rad/s (x, y, z) |
| `gravity` | float[3] | Gravity vector in device frame, in g (x, y, z) |
| `attitude_euler` | float[3] | Roll, pitch, yaw in radians |
| `attitude_quaternion` | float[4] | Orientation quaternion (x, y, z, w) |
| `magnetic_field` | float[3] | Calibrated magnetic field in microtesla (x, y, z) |

### Scene (optional, present when ARKit provides them)

| Field | Type | Description |
|-------|------|-------------|
| `feature_point_count` | int | Number of ARKit sparse feature points tracked this frame |
| `ambient_intensity` | float | Estimated scene luminosity (lumen) |
| `ambient_color_temperature` | float | Estimated color temperature in Kelvin |

## Session Directory Structure

```
session_YYYYMMDD_HHmmss/
├── frames.jsonl          # one JSON object per line (this file)
├── metadata.json         # session summary (device, resolution, frame count)
├── rgb/
│   ├── 000000.jpg        # JPEG frames (quality 0.9)
│   ├── 000001.jpg
│   └── ...
├── depth/
│   ├── 000000.bin        # Float32 depth maps (LiDAR only)
│   └── ...
└── confidence/
    ├── 000000.bin        # UInt8 confidence maps (LiDAR only)
    └── ...
```
