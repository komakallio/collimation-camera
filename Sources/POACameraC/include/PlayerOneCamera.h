/****************************************************************************
** Types-only excerpt of the Player One Camera SDK header (V3.10).
** Function symbols are resolved at runtime via dlopen; they are intentionally
** omitted here so this module does not create link-time dependencies.
** Copyright (C) Player One Astronomy Co., Ltd.
****************************************************************************/

#ifndef PLAYERONECAMERA_H
#define PLAYERONECAMERA_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum _POABool {
    POA_FALSE = 0,
    POA_TRUE
} POABool;

typedef enum _POABayerPattern {
    POA_BAYER_RG = 0,
    POA_BAYER_BG,
    POA_BAYER_GR,
    POA_BAYER_GB,
    POA_BAYER_MONO = -1
} POABayerPattern;

typedef enum _POAImgFormat {
    POA_RAW8 = 0,
    POA_RAW16,
    POA_RGB24,
    POA_MONO8,
    POA_END = -1
} POAImgFormat;

typedef enum _POAErrors {
    POA_OK = 0,
    POA_ERROR_INVALID_INDEX,
    POA_ERROR_INVALID_ID,
    POA_ERROR_INVALID_CONFIG,
    POA_ERROR_INVALID_ARGU,
    POA_ERROR_NOT_OPENED,
    POA_ERROR_DEVICE_NOT_FOUND,
    POA_ERROR_OUT_OF_LIMIT,
    POA_ERROR_EXPOSURE_FAILED,
    POA_ERROR_TIMEOUT,
    POA_ERROR_SIZE_LESS,
    POA_ERROR_EXPOSING,
    POA_ERROR_POINTER,
    POA_ERROR_CONF_CANNOT_WRITE,
    POA_ERROR_CONF_CANNOT_READ,
    POA_ERROR_ACCESS_DENIED,
    POA_ERROR_OPERATION_FAILED,
    POA_ERROR_MEMORY_FAILED
} POAErrors;

typedef enum _POACameraState {
    STATE_CLOSED = 0,
    STATE_OPENED,
    STATE_EXPOSING
} POACameraState;

typedef enum _POAValueType {
    VAL_INT = 0,
    VAL_FLOAT,
    VAL_BOOL
} POAValueType;

typedef enum _POAConfig {
    POA_EXPOSURE = 0,
    POA_GAIN,
    POA_HARDWARE_BIN,
    POA_TEMPERATURE,
    POA_WB_R,
    POA_WB_G,
    POA_WB_B,
    POA_OFFSET,
    POA_AUTOEXPO_MAX_GAIN,
    POA_AUTOEXPO_MAX_EXPOSURE,
    POA_AUTOEXPO_BRIGHTNESS,
    POA_GUIDE_NORTH,
    POA_GUIDE_SOUTH,
    POA_GUIDE_EAST,
    POA_GUIDE_WEST,
    POA_EGAIN,
    POA_COOLER_POWER,
    POA_TARGET_TEMP,
    POA_COOLER,
    POA_HEATER,
    POA_HEATER_POWER,
    POA_FAN_POWER,
    POA_FLIP_NONE,
    POA_FLIP_HORI,
    POA_FLIP_VERT,
    POA_FLIP_BOTH,
    POA_FRAME_LIMIT,
    POA_HQI,
    POA_USB_BANDWIDTH_LIMIT,
    POA_PIXEL_BIN_SUM,
    POA_MONO_BIN,
    POA_EXP
} POAConfig;

typedef struct _POACameraProperties {
    char cameraModelName[256];
    char userCustomID[16];
    int cameraID;
    int maxWidth;
    int maxHeight;
    int bitDepth;
    POABool isColorCamera;
    POABool isHasST4Port;
    POABool isHasCooler;
    POABool isUSB3Speed;
    POABayerPattern bayerPattern;
    double pixelSize;
    char SN[64];
    char sensorModelName[32];
    char localPath[256];
    int bins[8];
    POAImgFormat imgFormats[8];
    POABool isSupportHardBin;
    int pID;
    char reserved[248];
} POACameraProperties;

typedef union _POAConfigValue {
    long intValue;
    double floatValue;
    POABool boolValue;
} POAConfigValue;

typedef struct _POAConfigAttributes {
    POABool isSupportAuto;
    POABool isWritable;
    POABool isReadable;
    POAConfig configID;
    POAValueType valueType;
    POAConfigValue maxValue;
    POAConfigValue minValue;
    POAConfigValue defaultValue;
    char szConfName[64];
    char szDescription[128];
    char reserved[64];
} POAConfigAttributes;

typedef struct _POASensorModeInfo {
    char name[64];
    char desc[128];
} POASensorModeInfo;

#ifdef __cplusplus
}
#endif

#endif
