/****************************************************************************
** Types-only excerpt of the ZWO ASI Camera SDK header (V1.41).
** Function symbols are resolved at runtime; they are intentionally omitted
** here so this module creates no link-time dependency.
**
** The vendor header defines these type names as `int` macros when compiled as
** C, which would erase them in Swift. They are written as real C enums here so
** Swift imports each one as a distinct type. Every enumerator value, field
** order, and field type matches the vendor header. `long` is deliberate: it is
** 32-bit with MSVC and 64-bit with clang on macOS, which is what each vendor
** binary was built with.
** Copyright (C) Suzhou ZWO Co., Ltd.
****************************************************************************/

#ifndef ASICAMERA2_H
#define ASICAMERA2_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ASI_BAYER_PATTERN {
    ASI_BAYER_RG = 0,
    ASI_BAYER_BG,
    ASI_BAYER_GR,
    ASI_BAYER_GB
} ASI_BAYER_PATTERN;

typedef enum ASI_IMG_TYPE {
    ASI_IMG_RAW8 = 0,
    ASI_IMG_RGB24,
    ASI_IMG_RAW16,
    ASI_IMG_Y8,
    ASI_IMG_END = -1
} ASI_IMG_TYPE;

typedef enum ASI_GUIDE_DIRECTION {
    ASI_GUIDE_NORTH = 0,
    ASI_GUIDE_SOUTH,
    ASI_GUIDE_EAST,
    ASI_GUIDE_WEST
} ASI_GUIDE_DIRECTION;

typedef enum ASI_FLIP_STATUS {
    ASI_FLIP_NONE = 0,
    ASI_FLIP_HORIZ,
    ASI_FLIP_VERT,
    ASI_FLIP_BOTH
} ASI_FLIP_STATUS;

typedef enum ASI_CAMERA_MODE {
    ASI_MODE_NORMAL = 0,
    ASI_MODE_TRIG_SOFT_EDGE,
    ASI_MODE_TRIG_RISE_EDGE,
    ASI_MODE_TRIG_FALL_EDGE,
    ASI_MODE_TRIG_SOFT_LEVEL,
    ASI_MODE_TRIG_HIGH_LEVEL,
    ASI_MODE_TRIG_LOW_LEVEL,
    ASI_MODE_END = -1
} ASI_CAMERA_MODE;

typedef enum ASI_ERROR_CODE {
    ASI_SUCCESS = 0,
    ASI_ERROR_INVALID_INDEX,        /* no camera connected or index out of range */
    ASI_ERROR_INVALID_ID,
    ASI_ERROR_INVALID_CONTROL_TYPE,
    ASI_ERROR_CAMERA_CLOSED,        /* camera did not open */
    ASI_ERROR_CAMERA_REMOVED,       /* device removed */
    ASI_ERROR_INVALID_PATH,
    ASI_ERROR_INVALID_FILEFORMAT,
    ASI_ERROR_INVALID_SIZE,
    ASI_ERROR_INVALID_IMGTYPE,
    ASI_ERROR_OUTOF_BOUNDARY,
    ASI_ERROR_TIMEOUT,
    ASI_ERROR_INVALID_SEQUENCE,
    ASI_ERROR_BUFFER_TOO_SMALL,
    ASI_ERROR_VIDEO_MODE_ACTIVE,
    ASI_ERROR_EXPOSURE_IN_PROGRESS,
    ASI_ERROR_GENERAL_ERROR,
    ASI_ERROR_INVALID_MODE,
    ASI_ERROR_GPS_NOT_SUPPORTED,
    ASI_ERROR_GPS_VER_ERR,
    ASI_ERROR_GPS_FPGA_ERR,
    ASI_ERROR_GPS_PARAM_OUT_OF_RANGE,
    ASI_ERROR_GPS_DATA_INVALID,
    ASI_ERROR_END
} ASI_ERROR_CODE;

typedef enum ASI_BOOL {
    ASI_FALSE = 0,
    ASI_TRUE
} ASI_BOOL;

typedef enum ASI_CONTROL_TYPE {
    ASI_GAIN = 0,
    ASI_EXPOSURE,
    ASI_GAMMA,
    ASI_WB_R,
    ASI_WB_B,
    ASI_OFFSET,
    ASI_BANDWIDTHOVERLOAD,
    ASI_OVERCLOCK,
    ASI_TEMPERATURE,                /* value is temperature * 10 */
    ASI_FLIP,
    ASI_AUTO_MAX_GAIN,
    ASI_AUTO_MAX_EXP,               /* milliseconds */
    ASI_AUTO_TARGET_BRIGHTNESS,
    ASI_HARDWARE_BIN,
    ASI_HIGH_SPEED_MODE,
    ASI_COOLER_POWER_PERC,
    ASI_TARGET_TEMP,
    ASI_COOLER_ON,
    ASI_MONO_BIN,
    ASI_FAN_ON,
    ASI_PATTERN_ADJUST,
    ASI_ANTI_DEW_HEATER,
    ASI_FAN_ADJUST,
    ASI_PWRLED_BRIGNT,
    ASI_USBHUB_RESET,
    ASI_GPS_SUPPORT,
    ASI_GPS_START_LINE,
    ASI_GPS_END_LINE,
    ASI_ROLLING_INTERVAL             /* microseconds */
} ASI_CONTROL_TYPE;

typedef struct _ASI_CAMERA_INFO
{
    char Name[64];
    int CameraID;
    long MaxHeight;
    long MaxWidth;

    ASI_BOOL IsColorCam;
    ASI_BAYER_PATTERN BayerPattern;

    int SupportedBins[16];           /* terminated by 0 */
    ASI_IMG_TYPE SupportedVideoFormat[8]; /* terminated by ASI_IMG_END */

    double PixelSize;                /* microns */
    ASI_BOOL MechanicalShutter;
    ASI_BOOL ST4Port;
    ASI_BOOL IsCoolerCam;
    ASI_BOOL IsUSB3Host;
    ASI_BOOL IsUSB3Camera;
    float ElecPerADU;
    int BitDepth;
    ASI_BOOL IsTriggerCam;

    char Unused[16];
} ASI_CAMERA_INFO;

typedef struct _ASI_CONTROL_CAPS
{
    char Name[64];
    char Description[128];
    long MaxValue;
    long MinValue;
    long DefaultValue;
    ASI_BOOL IsAutoSupported;
    ASI_BOOL IsWritable;
    ASI_CONTROL_TYPE ControlType;
    char Unused[32];
} ASI_CONTROL_CAPS;

typedef struct _ASI_ID
{
    unsigned char id[8];
} ASI_ID;

typedef struct _ASI_SUPPORTED_MODE
{
    ASI_CAMERA_MODE SupportedCameraMode[16]; /* terminated by ASI_MODE_END */
} ASI_SUPPORTED_MODE;

#ifdef __cplusplus
}
#endif

#endif /* ASICAMERA2_H */
